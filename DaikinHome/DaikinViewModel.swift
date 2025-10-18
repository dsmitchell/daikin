//
//  DaikinViewModel.swift
//  daikin
//
//  Created by David Mitchell on 10/18/25.
//


import Foundation
import HomeKit
import SwiftUI


class DaikinViewModel: ObservableObject {
    @AppStorage("email") var email: String = ""
    @AppStorage("apiKey") var apiKey: String = ""
    @AppStorage("integratorToken") var integratorToken: String = ""
    @AppStorage("associations") private var associationsData: Data = Data()
    
    @Published var thermostats: [Device] = []
    @Published var isMonitoring = false
    @Published var statuses: [String: DeviceInfo] = [:]
    @Published var originalLightStates: [UUID: (hue: Float, saturation: Float, brightness: Float)] = [:]
    
    let homeManager = HMHomeManager()
    
    private var timer: Timer?
    private var client = DaikinClient(baseURL: "https://integrator-api.daikinskyport.com", apiKey: "")
    private var accessToken: String?
    private var associations: [String: UUID] = [:] // Thermostat ID to Light UUID
	let pollIntervalSeconds: TimeInterval = 180
	
    var isConfigured: Bool {
        !email.isEmpty && !apiKey.isEmpty && !integratorToken.isEmpty
    }
    
    init() {
        loadAssociations()
        client = DaikinClient(baseURL: "https://integrator-api.daikinskyport.com", apiKey: apiKey)
    }
    
    func loadThermostats() {
        guard isConfigured else { return }
        
        Task {
            do {
                accessToken = try await getAccessToken()
                thermostats = try await getDevices()
            } catch {
                print("Error loading thermostats: \(error)")
            }
        }
    }
    
    func toggleMonitoring() {
        if isMonitoring {
            timer?.invalidate()
            timer = nil
            restoreLights()
            isMonitoring = false
        } else {
            saveOriginalLightStates()
            timer = Timer.scheduledTimer(withTimeInterval: pollIntervalSeconds, repeats: true) { _ in
                Task {
                    await self.updateStatuses()
                    await self.updateLights()
                }
            }
            timer?.fire()
            isMonitoring = true
        }
    }
    
    private func getAccessToken() async throws -> String {
        try await client.getAccessToken(email: email, integratorToken: integratorToken).0
    }
    
    private func getDevices() async throws -> [Device] {
        try await client.getDevices(accessToken: accessToken ?? "").flatMap { $0.devices }
    }
    
    func updateStatuses() async {
        guard let accessToken = accessToken else { return }
        for thermostat in thermostats {
            do {
                let info = try await client.getThermostatInfo(accessToken: accessToken, deviceId: thermostat.id)
                statuses[thermostat.id] = info
            } catch {
                print("Error updating status for \(thermostat.id): \(error)")
            }
        }
    }
    
    func getTemperature(for id: String) -> String {
		guard let temp = statuses[id]?.tempIndoor else {
			return "N/A"
		}
		return String(format: "%.1f", temp)
	}
    
    func getMode(for id: String) -> String {
		guard let temp = statuses[id]?.mode else {
			return "N/A"
		}
		return modeDescription(temp)
    }
    
    func getActiveStatus(for id: String) -> String {
        statuses[id]?.equipmentStatus.map { equipmentStatusDescription($0) } ?? "N/A"
    }
    
    func getFanCirculate(for id: String) -> String {
        statuses[id]?.fanCirculate.map { fanCirculateDescription($0) } ?? "N/A"
    }
    
    func getFan(for id: String) -> String {
        statuses[id]?.fan.map { fanDescription($0) } ?? "N/A"
    }
    
    func getAssociatedLight(for id: String) -> HMAccessory? {
        guard let lightUUID = associations[id] else { return nil }
        for home in homeManager.homes {
            for accessory in home.accessories {
                if accessory.uniqueIdentifier == lightUUID {
                    return accessory
                }
            }
        }
        return nil
    }
    
    func saveAssociation(for thermostatId: String, light: HMAccessory) {
        associations[thermostatId] = light.uniqueIdentifier
        saveAssociations()
    }
    
	private func saveOriginalLightStates() {
		  Task {
			  for (thermostatId, lightUUID) in associations {
				  if let light = getAssociatedLight(for: thermostatId) {
					  guard let hueChar = light.colorService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeHue }),
							let saturationChar = light.colorService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeSaturation }),
							let brightnessChar = light.colorService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeBrightness }) else { continue }
					  
					  do {
						  try await hueChar.readValue()
						  let hue = hueChar.value as? Float ?? 0
						  try await saturationChar.readValue()
						  let saturation = saturationChar.value as? Float ?? 0
						  try await brightnessChar.readValue()
						  let brightness = brightnessChar.value as? Float ?? 0
						  
						  DispatchQueue.main.async {
							  self.originalLightStates[lightUUID] = (hue, saturation, brightness)
						  }
					  } catch {
						  print("Error reading light state for \(thermostatId): \(error)")
					  }
				  }
			  }
		  }
	  }
	
	private func restoreLights() {
		Task {
			for (lightUUID, state) in originalLightStates {
				for home in homeManager.homes {
					for accessory in home.accessories {
						if accessory.uniqueIdentifier == lightUUID {
							guard let hueChar = accessory.colorService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeHue }),
								  let saturationChar = accessory.colorService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeSaturation }),
								  let brightnessChar = accessory.colorService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeBrightness }) else { continue }
							
							do {
								try await hueChar.writeValue(state.hue)
								try await saturationChar.writeValue(state.saturation)
								try await brightnessChar.writeValue(state.brightness)
							} catch {
								print("Error restoring light state for \(lightUUID): \(error)")
							}
						}
					}
				}
			}
			DispatchQueue.main.async {
				self.originalLightStates = [:]
			}
		}
	}
	
	private func updateLights() async {
		for thermostat in thermostats {
			guard let info = statuses[thermostat.id], let light = getAssociatedLight(for: thermostat.id),
				  let hueChar = light.colorService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeHue }),
				  let saturationChar = light.colorService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeSaturation }),
				  let brightnessChar = light.colorService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeBrightness }) else { continue }
			
			let equipmentStatus = info.equipmentStatus ?? 0
			let hue: Float
			let saturation: Float = 100
			let brightness: Float = 100
			
			if equipmentStatus == 1 || equipmentStatus == 3 || equipmentStatus == 5 {
				hue = 0 // Red for heating
			} else if equipmentStatus == 2 {
				hue = 240 // Blue for cooling
			} else {
				continue
			}
			
			do {
				try await hueChar.writeValue(hue)
				try await saturationChar.writeValue(saturation)
				try await brightnessChar.writeValue(brightness)
			} catch {
				print("Error updating light for \(thermostat.id): \(error)")
			}
		}
	}
    private func loadAssociations() {
        if let dict = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSString.self], from: associationsData) as? [String: UUID] {
            associations = dict
        }
    }
    
    private func saveAssociations() {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: associations, requiringSecureCoding: false) {
            associationsData = data
        }
    }
}

extension HMAccessory {
    var isColorLight: Bool {
        services.contains { $0.serviceType == HMServiceTypeLightbulb && $0.characteristics.contains { $0.characteristicType == HMCharacteristicTypeHue } }
    }
    
    var colorService: HMService? {
        services.first { $0.serviceType == HMServiceTypeLightbulb }
    }
}

extension HMCharacteristic {
    var hueCharacteristic: HMCharacteristic? {
        self.characteristicType == HMCharacteristicTypeHue ? self : nil
    }
    
    var saturationCharacteristic: HMCharacteristic? {
        self.characteristicType == HMCharacteristicTypeSaturation ? self : nil
    }
    
    var brightnessCharacteristic: HMCharacteristic? {
        self.characteristicType == HMCharacteristicTypeBrightness ? self : nil
    }
}

extension HMHomeManager {
    func requestAccess(completion: @escaping (Bool) -> Void) {
        // HomeKit permission is requested on first access; handle in onAppear if needed
        completion(true) // Placeholder; actual permission is system-prompted
    }
}

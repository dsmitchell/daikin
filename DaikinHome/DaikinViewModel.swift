//
//  DaikinViewModel.swift
//  daikin
//
//  Created by David Mitchell on 10/18/25.
//

import SwiftUI
import Foundation
import HomeKit
import Combine

@MainActor
class DaikinViewModel: ObservableObject, Sendable {
	@AppStorage("email") var email: String = ""
	@AppStorage("apiKey") var apiKey: String = ""
	@AppStorage("integratorToken") var integratorToken: String = ""
	@AppStorage("associations") private var associationsData: Data = Data()
	
	@Published var thermostats: [Device] = []
	@Published var isMonitoring = false
	@Published var statuses: [String: DeviceInfo] = [:]
	@Published var originalLightStates: [UUID: (hue: Float, saturation: Float, brightness: Float)] = [:]
	@Published var homes: [HMHome] = []
	
	private let homeKitManager = HomeKitManager()
	private let pollIntervalSeconds: TimeInterval = 180
	private var timer: Timer?
	private var client = DaikinClient(baseURL: "https://integrator-api.daikinskyport.com", apiKey: "")
	private var accessToken: String?
	private var associations: [String: (homeUUID: String, roomUUID: String, lightUUID: String)] = [:] // Thermostat ID to (Home UUID, Room UUID, Light UUID)
	private var cancellables = Set<AnyCancellable>()
	
	var isConfigured: Bool {
		!email.isEmpty && !apiKey.isEmpty && !integratorToken.isEmpty
	}
	
	init() {
		loadAssociations()
		client = DaikinClient(baseURL: "https://integrator-api.daikinskyport.com", apiKey: apiKey)
		homeKitManager.$homes
			.receive(on: RunLoop.main)
			.assign(to: \.homes, on: self)
			.store(in: &cancellables)
	}
	
	// In DaikinViewModel.swift, add a test method
	func testSetModeOff(deviceId: String) async {
		guard let accessToken = accessToken else { return }
		do {
			let response = try await client.setModeOff(accessToken: accessToken, deviceId: deviceId)
			print("testSetModeOff: \(response.message)")
		} catch {
			print("Test setModeOff failed: \(error)")
		}
	}

	func testSetFanCirculate(deviceId: String, circulate: Bool) async {
		guard let accessToken = accessToken else { return }
		do {
			let response = try await client.setFanCirculate(accessToken: accessToken, deviceId: deviceId, circulate: circulate)
			print("testSetFanCirculate: \(response.message)")
		} catch {
			print("Test setFanCirculate failed: \(error)")
		}
	}
	
	func loadThermostats() async {
		guard isConfigured else { return }
		
		do {
			accessToken = try await getAccessToken()
			let devices = try await getDevices()
			thermostats = devices
		} catch {
			print("Error loading thermostats: \(error)")
		}
	}
	
	func refreshHomes() async {
		print("DaikinViewModel: refreshHomes called")
		await homeKitManager.refreshHomes()
	}
	
	func toggleMonitoring() {
		if isMonitoring {
			timer?.invalidate()
			timer = nil
			Task { await restoreLights() }
			isMonitoring = false
		} else {
			Task { await saveOriginalLightStates() }
			timer = Timer.scheduledTimer(withTimeInterval: pollIntervalSeconds, repeats: true) { [weak self] _ in
				Task { await self?.updateStatuses() }
				Task { await self?.updateLights() }
			}
			timer?.fire()
			isMonitoring = true
		}
	}
	
	private func getAccessToken() async throws -> String {
		try await client.getAccessToken(email: email, integratorToken: integratorToken).accessToken
	}
	
	private func getDevices() async throws -> [Device] {
		try await client.getDevices(accessToken: accessToken ?? "").flatMap { $0.devices }
	}
	
	func updateStatuses() async {
		guard let accessToken = accessToken else { return }
		for thermostat in thermostats {
			do {
				let info = try await client.getThermostatInfo(accessToken: accessToken, deviceId: thermostat.id)
				await MainActor.run {
					self.statuses[thermostat.id] = info
				}
			} catch {
				print("Error updating status for \(thermostat.id): \(error)")
			}
		}
	}
	
	func getTemperature(for id: String) -> String {
		guard let info = statuses[id] else { return "N/A" }
		return String(format: "%.1f", info.tempIndoor)
	}
	
	func getMode(for id: String) -> String {
		guard let info = statuses[id] else { return "N/A" }
		return modeDescription(info.mode)
	}
	
	func getActiveStatus(for id: String) -> String {
		guard let info = statuses[id] else { return "N/A" }
		return equipmentStatusDescription(info.equipmentStatus)
	}
	
	func getFanCirculate(for id: String) -> String {
		guard let info = statuses[id] else { return "N/A" }
		return fanCirculateDescription(info.fanCirculate)
	}
	
	func getFan(for id: String) -> String {
		guard let info = statuses[id] else { return "N/A" }
		return fanDescription(info.fan)
	}
	
	func getAssociatedLight(for id: String) -> HMAccessory? {
		guard let (homeUUID, roomUUID, lightUUID) = associations[id],
			  let homeUUID = UUID(uuidString: homeUUID),
			  let roomUUID = UUID(uuidString: roomUUID),
			  let lightUUID = UUID(uuidString: lightUUID) else { return nil }
		
		for home in homes {
			if home.uniqueIdentifier == homeUUID {
				for room in home.rooms {
					if room.uniqueIdentifier == roomUUID {
						for accessory in room.accessories {
							if accessory.uniqueIdentifier == lightUUID {
								return accessory
							}
						}
					}
				}
			}
		}
		return nil
	}
	
	func getAssociatedUUIDs(for id: String) -> (homeUUID: String, roomUUID: String, lightUUID: String)? {
		associations[id]
	}
	
	func saveAssociation(for thermostatId: String, home: HMHome?, room: HMRoom?, light: HMAccessory?) {
		guard let home = home, let room = room, let light = light else { return }
		associations[thermostatId] = (home.uniqueIdentifier.uuidString, room.uniqueIdentifier.uuidString, light.uniqueIdentifier.uuidString)
		saveAssociations()
	}
	
	private func saveOriginalLightStates() async {
		for (thermostatId, lightUUID) in associations.mapValues({ $0.lightUUID }) {
			if let light = getAssociatedLight(for: thermostatId) {
				guard let hueChar = light.colorService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeHue }),
					  let saturationChar = light.colorService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeSaturation }),
					  let brightnessChar = light.colorService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeBrightness }) else { continue }
				
				do {
					try await hueChar.readValue()
					try await saturationChar.readValue()
					try await brightnessChar.readValue()
					
					let hue = hueChar.value as? Float ?? 0
					let saturation = saturationChar.value as? Float ?? 0
					let brightness = brightnessChar.value as? Float ?? 0
					
					await MainActor.run {
						self.originalLightStates[UUID(uuidString: lightUUID)!] = (hue, saturation, brightness)
					}
				} catch {
					print("Error reading light state for \(thermostatId): \(error)")
				}
			}
		}
	}
	
	private func restoreLights() async {
		for (lightUUID, state) in originalLightStates {
			for home in homes {
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
		await MainActor.run {
			self.originalLightStates = [:]
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
		if let dict = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSString.self], from: associationsData) as? [String: (homeUUID: String, roomUUID: String, lightUUID: String)] {
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
		services.contains { service in
			service.serviceType == HMServiceTypeLightbulb &&
			service.characteristics.contains { $0.characteristicType == HMCharacteristicTypeHue }
		}
	}
	
	var colorService: HMService? {
		services.first { $0.serviceType == HMServiceTypeLightbulb }
	}
}

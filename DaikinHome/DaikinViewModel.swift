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
	
	@Published var locations: [Location] = []
	@Published var isMonitoring = false
	@Published var statuses: [String: DeviceInfo] = [:]
	@Published var originalLightStates: [UUID: (power: Bool, hue: Float, saturation: Float, brightness: Float)] = [:]
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
	func testSetMode(deviceId: String, mode: Int) async {
		guard let accessToken = accessToken else { return }
		do {
			let response = try await client.setMode(mode: mode, accessToken: accessToken, deviceId: deviceId)
			print("testSetMode: \(response.message)")
		} catch {
			print("Test setMode failed: \(error)")
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
			locations = try await getLocations()
			await updateStatuses()
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
	
	private func getLocations() async throws -> [Location] {
		try await client.getLocations(accessToken: accessToken ?? "")
	}
	
	func updateStatus(deviceId: String) async throws {
		guard let accessToken = accessToken else { return }
		print("Updating status for \(deviceId)...")
		let info = try await client.getThermostatInfo(accessToken: accessToken, deviceId: deviceId)
		await MainActor.run {
			print("Completed status update for \(deviceId)")
			self.statuses[deviceId] = info
		}
	}
	
	func updateStatuses() async {
		for location in locations {
			for thermostat in location.devices {
				do {
					try await updateStatus(deviceId: thermostat.id)
				} catch {
					print("Error updating status for \(thermostat.id): \(error)")
				}
			}
		}
	}
	
	func getTemperature(for id: String) -> String {
		guard let info = statuses[id] else { return "N/A" }
		let heat = info.heatSetpoint != nil ? String(format: "%.1f", info.heatSetpoint!) : "not set"
		let cool = info.coolSetpoint != nil ? String(format: "%.1f", info.coolSetpoint!) : "not set"
		return "\(info.tempIndoor)°C (heat: \(heat), cool: \(cool))"
	}

	func getMode(for id: String) -> Int? {
		guard let info = statuses[id] else { return nil }
		return info.mode
	}

	func getModeDescription(for id: String) -> String {
		guard let mode = getMode(for: id) else { return "N/A" }
		return "\(modeDescription(mode)) (\(mode))"
	}
	
	func getActiveStatus(for id: String) -> String {
		guard let info = statuses[id] else { return "N/A" }
		return "\(equipmentStatusDescription(info.equipmentStatus)) (\(info.equipmentStatus ?? -1))"
	}
	
	func getFanCirculate(for id: String) -> Int? {
		guard let info = statuses[id] else { return nil }
		return info.fanCirculate
	}

	func getFanCirculateDescription(for id: String) -> String {
		guard let fanCirculate = getFanCirculate(for: id) else { return "N/A" }
		return "\(fanCirculateDescription(fanCirculate)) (\(fanCirculate))"
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
				guard let powerChar = light.colorBulbService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypePowerState}),
					  let hueChar = light.colorBulbService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeHue }),
					  let saturationChar = light.colorBulbService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeSaturation }),
					  let brightnessChar = light.colorBulbService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeBrightness }) else { continue }
				
				do {
					try await powerChar.readValue()
					try await hueChar.readValue()
					try await saturationChar.readValue()
					try await brightnessChar.readValue()
					
					let power = powerChar.value as? Bool ?? false
					let hue = hueChar.value as? Float ?? 0
					let saturation = saturationChar.value as? Float ?? 0
					let brightness = brightnessChar.value as? Float ?? 0
					
					await MainActor.run {
						self.originalLightStates[UUID(uuidString: lightUUID)!] = (power, hue, saturation, brightness)
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
						guard let powerChar = accessory.colorBulbService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypePowerState}),
							  let hueChar = accessory.colorBulbService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeHue }),
							  let saturationChar = accessory.colorBulbService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeSaturation }),
							  let brightnessChar = accessory.colorBulbService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeBrightness }) else { continue }
						
						do {
							try await powerChar.writeValue(state.power)
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
		for thermostat in locations.flatMap( \.devices ) {
			guard let info = statuses[thermostat.id], let light = getAssociatedLight(for: thermostat.id),
				  let powerChar = light.colorBulbService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypePowerState }),
				  let hueChar = light.colorBulbService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeHue }),
				  let saturationChar = light.colorBulbService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeSaturation }),
				  let brightnessChar = light.colorBulbService?.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeBrightness }) else {
				print("No light association for \(thermostat.id)")
				continue
			}
			
			let equipmentStatus = info.equipmentStatus ?? 0
			let power: Bool
			let hue: Float
			let saturation: Float
			let brightness: Float
			
			if equipmentStatus == 0 || equipmentStatus > 5 {
				if originalLightStates[light.uniqueIdentifier] == nil {
					await saveOriginalLightStates()
				}
				power = true
				hue = 300 // Magenta to notice unseen states to help identify their meaning
				saturation = 100
				brightness = 50
			} else if equipmentStatus == 3 {
				if originalLightStates[light.uniqueIdentifier] == nil {
					await saveOriginalLightStates()
				}
				power = true
				hue = 0 // Red for heating
				saturation = 100
				brightness = 50
			} else if equipmentStatus == 1 || equipmentStatus == 2 {
				if originalLightStates[light.uniqueIdentifier] == nil {
					await saveOriginalLightStates()
				}
				power = true
				hue = 240 // Blue for cooling / overcooling
				saturation = 100
				brightness = 50
			} else if let original = originalLightStates[light.uniqueIdentifier] {
				power = original.power
				hue = original.hue
				saturation = original.saturation
				brightness = original.brightness
			} else {
				print("Cannot update light for \(thermostat.id)")
				continue
			}
			print("Updating light for \(thermostat.id): \(power),\(hue),\(saturation),\(brightness)")
			do {
				try await hueChar.writeValue(hue)
				try await saturationChar.writeValue(saturation)
				try await brightnessChar.writeValue(brightness)
				try await powerChar.writeValue(power)
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
	
	var colorBulbService: HMService? {
		services.first { $0.serviceType == HMServiceTypeLightbulb }
	}
}

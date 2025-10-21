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
	@Published var activeModeIds: Set<String> = []
	@Published var activeCirculateIds: Set<String> = []
	
	private let homeKitManager = HomeKitManager()
	private let pollIntervalSeconds: TimeInterval = 180
	private var timer: Timer?
	private var client: DaikinClient?
	private var accessToken: String?
	private var accessTokenExpiration: Date?
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
	
	func sectionHeader(location: Location, thermostat: Device) -> String {
		let offline: String
		if let info = statuses[thermostat.id], info.equipmentCommunication != 1 {
			offline = " (OFFLINE)"
		} else {
			offline = ""
		}
		return "\(location.locationName ?? "Unnamed Location") - \(thermostat.name ?? "Unnamed Thermostat") - \(thermostat.model) v\(thermostat.firmwareVersion)\(offline)"
	}
	
	func setThermostatMode(deviceId: String, mode: Int) async {
		do {
			let accessToken = try await getAccessToken()
			if let setpoints = statuses[deviceId] {
				let heatSetpoint = setpoints.heatSetpoint ?? setpoints.setpointMinimum.map { Double($0) } ?? 15.0
				let coolSetpoint = setpoints.coolSetpoint ?? setpoints.setpointMaximum.map { Double($0) } ?? 27.0
				let response = try await client!.setMode(mode: mode, heatSetpoint: heatSetpoint, coolSetpoint: coolSetpoint, accessToken: accessToken, deviceId: deviceId)
				print("setThermostatMode: \(response.message)")
			} else {
				
			}
		} catch {
			print("setThermostatMode failed: \(error)")
		}
	}

	func setThermostatFanCirculate(deviceId: String, circulate: Bool) async {
		do {
			let accessToken = try await getAccessToken()
			let response = try await client!.setFanCirculate(accessToken: accessToken, deviceId: deviceId, circulate: circulate)
			print("setThermostatFanCirculate: \(response.message)")
		} catch {
			print("setThermostatFanCirculate failed: \(error)")
		}
	}
	
	func loadThermostats() async {
		guard isConfigured else { return }
		
		do {
			locations = try await getLocations()
			await updateStatuses()
		} catch {
			print("Error loading thermostats: \(error)")
		}
	}
	
	func toggleActiveMode(thermostat: Device) {
		activeModeIds.insert(thermostat.id)
		Task {
			let newValue = getMode(for: thermostat.id) != 3 ? 3 : 0
			await setThermostatMode(deviceId: thermostat.id, mode: newValue)
			try? await Task.sleep(nanoseconds: 1_000_000_000 * 15)
			try await updateStatus(device: thermostat)
			activeModeIds.remove(thermostat.id)
		}
	}
	
	func toggleCirculate(thermostat: Device) {
		activeCirculateIds.insert(thermostat.id)
		Task {
			let newValue = getFanCirculate(for: thermostat.id) == 0 ? true : false
			await setThermostatFanCirculate(deviceId: thermostat.id, circulate: newValue)
			try? await Task.sleep(nanoseconds: 1_000_000_000 * 15)
			try await updateStatus(device: thermostat)
			activeCirculateIds.remove(thermostat.id)
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
		guard let accessToken = accessToken, let accessTokenExpiration = accessTokenExpiration, accessTokenExpiration > Date() else {
			let fromDate = Date().addingTimeInterval(TimeInterval(-1))
			let tokenResponse = try await client!.getAccessToken(email: email, integratorToken: integratorToken)
			self.accessTokenExpiration = fromDate.addingTimeInterval(TimeInterval(tokenResponse.accessTokenExpiresIn))
			self.accessToken = tokenResponse.accessToken
			print("\(tokenResponse.accessTokenExpiresIn), \(tokenResponse.tokenType)")
			return tokenResponse.accessToken
		}
		return accessToken
	}
	
	private func getLocations() async throws -> [Location] {
		let accessToken = try await getAccessToken()
		return try await client!.getLocations(accessToken: accessToken)
	}
	
	func updateStatus(device: Device) async throws {
		let accessToken = try await getAccessToken()
		print("Updating status for \(device.name ?? device.id)...")
		let info = try await client!.getThermostatInfo(accessToken: accessToken, deviceId: device.id)
		await MainActor.run {
			print("Completed status update for \(device.name ?? device.id)")
			self.statuses[device.id] = info
		}
	}
	
	func updateStatuses() async {
		for location in locations {
			for thermostat in location.devices {
				do {
					try await updateStatus(device: thermostat)
				} catch {
					print("Error updating status for \(thermostat.name ?? thermostat.id): \(error)")
				}
			}
		}
	}
	
	func getTemperature(for id: String) -> String {
		guard let info = statuses[id] else { return "N/A" }
		let heat = info.heatSetpoint != nil ? String(format: "%.1f", info.heatSetpoint!) : "not set"
		let cool = info.coolSetpoint != nil ? String(format: "%.1f", info.coolSetpoint!) : "not set"
		let delta = info.setpointDelta != nil ? String(format: "%.1f", info.setpointDelta!) : "not set"
		return "\(info.tempIndoor)°C (heat: \(heat), cool: \(cool), delta: \(delta))"
	}

	func getMode(for id: String) -> Int? {
		guard let info = statuses[id] else { return nil }
		return info.mode
	}

	func getModeDescription(for id: String) -> String {
		guard let mode = getMode(for: id) else { return "N/A" }
		return "\(modeDescription(mode)) (\(mode))"
	}

	func getScheduleDescription(for id: String) -> String {
		guard let info = statuses[id], let scheduleEnabled = info.scheduleEnabled else { return "N/A" }
		return scheduleEnabled ? "Yes" : "No"
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
				print("No light association for \(thermostat.name ?? thermostat.id)")
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
				brightness = 100
				print("Updating light for \(thermostat.name ?? thermostat.id): Unknown Magenta")
			} else if equipmentStatus == 3 {
				if originalLightStates[light.uniqueIdentifier] == nil {
					await saveOriginalLightStates()
				}
				power = true
				hue = 0 // Red for heating
				saturation = 100
				brightness = 50
				print("Updating light for \(thermostat.name ?? thermostat.id): Heating Red")
			} else if equipmentStatus == 1 || equipmentStatus == 2 {
				if originalLightStates[light.uniqueIdentifier] == nil {
					await saveOriginalLightStates()
				}
				power = true
				hue = 240 // Blue for cooling / overcooling
				saturation = 100
				brightness = 50
				print("Updating light for \(thermostat.name ?? thermostat.id): Cooling Blue")
			} else if let original = originalLightStates[light.uniqueIdentifier] {
				power = original.power
				hue = original.hue
				saturation = original.saturation
				brightness = original.brightness
				print("Restoring light for \(thermostat.name ?? thermostat.id) to original: \(power),\(hue),\(saturation),\(brightness)")
			} else {
				continue
			}
			do {
				try await hueChar.readValue()
				if hueChar.value as? Float != hue {
					try await hueChar.writeValue(hue)
				}
				try await saturationChar.readValue()
				if saturationChar.value as? Float != saturation {
					try await saturationChar.writeValue(saturation)
				}
				try await brightnessChar.readValue()
				if brightnessChar.value as? Float != brightness {
					try await brightnessChar.writeValue(brightness)
				}
				try await powerChar.readValue()
				if hueChar.value as? Bool != power {
					try await powerChar.writeValue(power)
				}
			} catch {
				print("Error updating light for \(thermostat.name ?? thermostat.id): \(error)")
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

import Foundation

struct TokenResponse: Codable {
	let accessToken: String
	let accessTokenExpiresIn: Int
	let tokenType: String
}

struct Device: Codable {
	let id: String
	let name: String?
	let model: String
	let firmwareVersion: String
}

struct Location: Codable {
	let locationName: String?
	let devices: [Device]
}

struct DeviceInfo: Codable {
	let tempIndoor: Double
	let mode: Int
	let fanCirculate: Int?
	let fan: Int?
	let heatSetpoint: Double?
	let coolSetpoint: Double?
	let equipmentStatus: Int?
	let humIndoor: Int?
	let humOutdoor: Int?
	let tempOutdoor: Double?
	let scheduleEnabled: Bool?
	let geofencingEnabled: Bool?
	let modeEmHeatAvailable: Bool?
	let setpointMinimum: Int?
	let setpointMaximum: Int?
	let setpointDelta: Int?
	let modeLimit: Int?
	let equipmentCommunication: Int?
}

struct TokenRequest: Codable {
	let email: String
	let integratorToken: String
}

struct ModeRequest: Codable {
	let mode: Int
	let heatSetpoint: Double
	let coolSetpoint: Double
}

struct FanRequest: Codable {
	let fanCirculate: Int
	let fanCirculateSpeed: Int
}

struct ScheduleRequest: Codable {
	let scheduleEnabled: Bool
}

struct UpdateResponse: Codable {
	let message: String
}

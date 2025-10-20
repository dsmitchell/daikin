import Foundation

class DaikinClient {
	private let baseURL: String
	private let apiKey: String
	
	init(baseURL: String, apiKey: String) {
		self.baseURL = baseURL
		self.apiKey = apiKey
	}
	
	func getHeaders(accessToken: String?) -> [String: String] {
		var headers = [
			"x-api-key": apiKey,
			"Content-Type": "application/json"
		]
		if let token = accessToken {
			headers["Authorization"] = "Bearer \(token)"
		}
		return headers
	}
	
	func getAccessToken(email: String, integratorToken: String) async throws -> TokenResponse {
		let url = URL(string: "\(baseURL)/v1/token")!
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.allHTTPHeaderFields = getHeaders(accessToken: nil)
		
		let body = TokenRequest(email: email, integratorToken: integratorToken)
		request.httpBody = try JSONEncoder().encode(body)
		
		let (data, response) = try await URLSession.shared.data(for: request)
		guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
			throw URLError(.badServerResponse)
		}
		
		let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
		return tokenResponse
	}
	
	func getDevices(accessToken: String) async throws -> [DeviceResponse] {
		let url = URL(string: "\(baseURL)/v1/devices")!
		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		request.allHTTPHeaderFields = getHeaders(accessToken: accessToken)
		
		let (data, response) = try await URLSession.shared.data(for: request)
		guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
			throw URLError(.badServerResponse)
		}
		
		return try JSONDecoder().decode([DeviceResponse].self, from: data)
	}
	
	func getThermostatInfo(accessToken: String, deviceId: String) async throws -> DeviceInfo {
		let url = URL(string: "\(baseURL)/v1/devices/\(deviceId)")!
		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		request.allHTTPHeaderFields = getHeaders(accessToken: accessToken)
		
		let (data, response) = try await URLSession.shared.data(for: request)
		guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
			throw URLError(.badServerResponse)
		}
		
		return try JSONDecoder().decode(DeviceInfo.self, from: data)
	}
	
	func setModeOff(accessToken: String, deviceId: String) async throws -> UpdateResponse {
		let url = URL(string: "\(baseURL)/v1/devices/\(deviceId)/msp")!
		var request = URLRequest(url: url)
		request.httpMethod = "PUT"
		request.allHTTPHeaderFields = getHeaders(accessToken: accessToken)
		
		let body = ModeRequest(mode: 0, heatSetpoint: 15.0, coolSetpoint: 27.0)
		request.httpBody = try JSONEncoder().encode(body)
		
		let (data, response) = try await URLSession.shared.data(for: request)
		guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
			throw URLError(.badServerResponse)
		}
		
		return try JSONDecoder().decode(UpdateResponse.self, from: data)
	}
	
	func setFanCirculate(accessToken: String, deviceId: String, circulate: Bool) async throws -> UpdateResponse {
		let url = URL(string: "\(baseURL)/v1/devices/\(deviceId)/fan")!
		var request = URLRequest(url: url)
		request.httpMethod = "PUT"
		request.allHTTPHeaderFields = getHeaders(accessToken: accessToken)
		
		let body = FanRequest(fanCirculate: circulate ? 1 : 0, fanCirculateSpeed: 1)
		request.httpBody = try JSONEncoder().encode(body)
		
		let (data, response) = try await URLSession.shared.data(for: request)
		guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
			throw URLError(.badServerResponse)
		}
		
		return try JSONDecoder().decode(UpdateResponse.self, from: data)
	}
}

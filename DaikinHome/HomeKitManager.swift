//
//  HomeKitManager.swift
//  DaikinHome
//
//  Created by David Mitchell on 10/19/25.
//

import Foundation
import HomeKit
import Combine

@MainActor
class HomeKitManager: NSObject, ObservableObject, HMHomeManagerDelegate, Sendable {
	@Published var homes: [HMHome] = []
	private let homeManager = HMHomeManager()
	
	override init() {
		super.init()
		print("HomeKitManager initialized")
		homeManager.delegate = self
		// Check HomeKit authorization status
		checkHomeKitAuthorization()
		// Force initial fetch
		homes = homeManager.homes
		print("Initial homes: \(homes.map { $0.name })")
	}
	
	nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
		print("HomeKitManager: homeManagerDidUpdateHomes called, homes: \(manager.homes.map { $0.name })")
		Task { @MainActor in
			self.homes = manager.homes
		}
	}
	
	func refreshHomes() async {
		print("HomeKitManager: refreshHomes called")
		checkHomeKitAuthorization()
		// Retry up to 3 times with a 1-second delay
		for attempt in 1...3 {
			let fetchedHomes = homeManager.homes
			print("HomeKitManager: Refresh attempt \(attempt), homes: \(fetchedHomes.map { $0.name })")
			if !fetchedHomes.isEmpty {
				await MainActor.run {
					self.homes = fetchedHomes
				}
				return
			}
			try? await Task.sleep(nanoseconds: 1_000_000_000)
		}
		print("HomeKitManager: No homes found after retries")
		await MainActor.run {
			self.homes = []
		}
	}
	
	private func checkHomeKitAuthorization() {
		let status = homeManager.authorizationStatus
		print("HomeKitManager: Authorization status: \(status)")
		if status.contains(.restricted) {
			print("HomeKitManager: HomeKit access restricted")
		} else if !status.contains(.authorized) {
			print("HomeKitManager: HomeKit not authorized")
			// HomeKit automatically prompts for authorization on first access
		} else {
			print("HomeKitManager: HomeKit authorized")
		}
	}
}

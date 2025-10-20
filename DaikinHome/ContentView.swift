//
//  ContentView.swift
//  DaikinHome
//
//  Created by David Mitchell on 10/18/25.
//

import HomeKit
import SwiftData
import SwiftUI

struct ContentView: View {
	@StateObject private var viewModel = DaikinViewModel()

	var body: some View {
		NavigationStack {
			List {
				Section(header: Text("Thermostats")) {
					ForEach(viewModel.thermostats, id: \.id) { thermostat in
						VStack {
							NavigationLink(destination: ThermostatDetailView(thermostat: thermostat, viewModel: viewModel)) {
								VStack(alignment: .leading) {
									Text(thermostat.name ?? "Unnamed Thermostat")
									Text("Temperature: \(viewModel.getTemperature(for: thermostat.id))°C")
										.font(.subheadline)
									Text("Mode: \(viewModel.getMode(for: thermostat.id))")
										.font(.subheadline)
									Text("Active Status: \(viewModel.getActiveStatus(for: thermostat.id))")
										.font(.subheadline)
									Text("Fan Circulate: \(viewModel.getFanCirculate(for: thermostat.id))")
										.font(.subheadline)
									Text("Fan: \(viewModel.getFan(for: thermostat.id))")
										.font(.subheadline)
								}
							}
							Button("Test Mode Off") {
								Task {
									await viewModel.testSetModeOff(deviceId: thermostat.id)
								}
							}
							Button("Test Fan Circulate On") {
								Task {
									await viewModel.testSetFanCirculate(deviceId: thermostat.id, circulate: true)
								}
							}
						}
					}
				}
				
				Section {
					Button(viewModel.isMonitoring ? "Stop Monitoring" : "Start Monitoring") {
						viewModel.toggleMonitoring()
					}
					.frame(maxWidth: .infinity)
					.disabled(!viewModel.isConfigured)
				} header: {
					Text(viewModel.isConfigured ? "Monitoring" : "Configure in Settings to Start")
				}
			}
			.navigationTitle("Daikin Thermostats")
			.toolbar {
				ToolbarItem(placement: .navigationBarTrailing) {
					NavigationLink("Settings") {
						SettingsView(viewModel: viewModel)
					}
				}
			}
			.onAppear {
				Task {
					await viewModel.loadThermostats()
				}
			}
		}
	}
}

struct ThermostatDetailView: View {
	let thermostat: Device
	@ObservedObject var viewModel: DaikinViewModel
	@State private var selectedHome: HMHome?
	@State private var selectedRoom: HMRoom?
	@State private var selectedLight: HMAccessory?
	@State private var rooms: [HMRoom] = []
	@State private var lights: [HMAccessory] = []
	@State private var homeKitError: String?
	@State private var saveConfirmation: String?
	
	var body: some View {
		Form {
			Section(header: Text("HomeKit Association")) {
				if let error = homeKitError {
					Text("HomeKit Error: \(error)")
						.foregroundColor(.red)
					Button("Retry HomeKit") {
						Task {
							await viewModel.refreshHomes()
							homeKitError = viewModel.homes.isEmpty ? "No homes available. Ensure Home app is set up and HomeKit access is granted." : nil
						}
					}
				} else if viewModel.homes.isEmpty {
					Text("No homes available. Ensure Home app is set up and HomeKit access is granted.")
						.foregroundColor(.red)
					Button("Retry HomeKit") {
						Task {
							await viewModel.refreshHomes()
							homeKitError = viewModel.homes.isEmpty ? "No homes available. Ensure Home app is set up and HomeKit access is granted." : nil
						}
					}
				} else {
					if let confirmation = saveConfirmation {
						Text(confirmation)
							.foregroundColor(.green)
							.transition(.opacity)
							.onAppear {
								DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
									saveConfirmation = nil
								}
							}
					}
					
					Picker("Home", selection: $selectedHome) {
						Text("None").tag(HMHome?.none)
						ForEach(viewModel.homes, id: \.uniqueIdentifier) { home in
							Text(home.name).tag(home as HMHome?)
						}
					}
					.onChange(of: selectedHome) { _, newHome in
						rooms = newHome?.rooms ?? []
						selectedRoom = nil
						selectedLight = nil
					}
					
					Picker("Room", selection: $selectedRoom) {
						Text("None").tag(HMRoom?.none)
						ForEach(rooms, id: \.uniqueIdentifier) { room in
							Text(room.name).tag(room as HMRoom?)
						}
					}
					.disabled(selectedHome == nil)
					.onChange(of: selectedRoom) { _, newRoom in
						lights = newRoom?.accessories.filter { $0.isColorLight } ?? []
						selectedLight = nil
					}
					
					Picker("Color Light", selection: $selectedLight) {
						Text("None").tag(HMAccessory?.none)
						ForEach(lights, id: \.uniqueIdentifier) { light in
							Text(light.name).tag(light as HMAccessory?)
						}
					}
					.disabled(selectedRoom == nil)
					
					Button("Save Association") {
						viewModel.saveAssociation(for: thermostat.id, home: selectedHome, room: selectedRoom, light: selectedLight)
						saveConfirmation = "Association saved successfully!"
					}
					.disabled(selectedLight == nil)
				}
			}
		}
		.navigationTitle("Associate Light")
		.task {
			await viewModel.refreshHomes()
			homeKitError = viewModel.homes.isEmpty ? "No homes available. Ensure Home app is set up and HomeKit access is granted." : nil
		}
		.onAppear {
			if let (homeUUID, roomUUID, lightUUID) = viewModel.getAssociatedUUIDs(for: thermostat.id) {
				selectedHome = viewModel.homes.first { $0.uniqueIdentifier.uuidString == homeUUID }
				rooms = selectedHome?.rooms ?? []
				selectedRoom = rooms.first { $0.uniqueIdentifier.uuidString == roomUUID }
				lights = selectedRoom?.accessories.filter { $0.isColorLight } ?? []
				selectedLight = lights.first { $0.uniqueIdentifier.uuidString == lightUUID }
			}
		}
	}
}

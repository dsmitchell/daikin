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
	@Environment(\.modelContext) private var modelContext

	var body: some View {
		NavigationStack {
			List {
				ForEach(viewModel.locations, id: \.locationName) { location in
					ForEach(location.devices, id: \.id) { thermostat in
						Section(header: Text(viewModel.sectionHeader(location: location, thermostat: thermostat)).textCase(nil)) {
							NavigationLink(destination: ThermostatDetailView(thermostat: thermostat, viewModel: viewModel)) {
								VStack(alignment: .leading) {
									Text("Temperature: \(viewModel.getTemperature(for: thermostat.id))")
										.font(.subheadline)
									Text("Mode: \(viewModel.getModeDescription(for: thermostat.id))")
										.font(.subheadline)
									Text("Running Schedule: \(viewModel.getScheduleDescription(for: thermostat.id))")
										.font(.subheadline)
									Text("Active Status: \(viewModel.getActiveStatus(for: thermostat.id))")
										.font(.subheadline)
									Text("Fan Circulate: \(viewModel.getFanCirculateDescription(for: thermostat.id))")
										.font(.subheadline)
									if viewModel.showFan(for: thermostat.id) {
										Text("Fan: \(viewModel.getFan(for: thermostat.id))")
											.font(.subheadline)
									}
								}
							}
							Button(action: {
								viewModel.toggleAutoMode(thermostat: thermostat)
							}) {
								HStack {
									Text(viewModel.getMode(for: thermostat.id) != 3 ? "Set Mode Auto" : "Set Mode Off")
									if viewModel.activeModeIds.contains(thermostat.id) {
										ProgressView()
											.progressViewStyle(CircularProgressViewStyle())
									}
								}
							}
							.disabled(viewModel.activeModeIds.contains(thermostat.id))
							Button(action: {
								viewModel.toggleCirculate(thermostat: thermostat)
							}) {
								HStack {
									Text(viewModel.getFanCirculate(for: thermostat.id) == 0 ? "Set Fan Circulate On" : "Set Fan Circulate Off")
									if viewModel.activeCirculateIds.contains(thermostat.id) {
										ProgressView()
											.progressViewStyle(CircularProgressViewStyle())
									}
								}
							}
							.disabled(viewModel.activeCirculateIds.contains(thermostat.id))
						}
					}
				}
				Section {
					VStack {
						Spacer()
						Text("Last updated: \(viewModel.lastUpdated, style: .time)")
							.font(.subheadline)
						Spacer()
						Button(viewModel.isMonitoring ? "Stop Monitoring" : "Start Monitoring") {
							viewModel.toggleMonitoring()
						}
						.frame(maxWidth: .infinity)
						.disabled(!viewModel.isConfigured)
						Spacer()
					}
				} header: {
					Text(viewModel.isConfigured ? "Monitoring" : "Configure in Settings to Start")
				}
			}
			.navigationTitle("Thermostats")
			.toolbar {
				ToolbarItem(placement: .navigationBarTrailing) {
					NavigationLink("Settings") {
						SettingsView(viewModel: viewModel)
					}
				}
			}
			.onAppear {
				viewModel.applyModelContext(modelContext: modelContext)
				Task {
					if viewModel.homes.isEmpty {
						await viewModel.refreshHomes()
					}
					if viewModel.statuses.isEmpty {
						await viewModel.loadThermostats()
					} else {
						await viewModel.updateStatuses()
					}
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
	@State private var isLoading = true
	
	var body: some View {
		if isLoading {
			ProgressView("Loading Association...")
				.navigationTitle("Associate Light")
				.task {
					if viewModel.homes.isEmpty {
						await viewModel.refreshHomes()
					}
					homeKitError = viewModel.homes.isEmpty ? "No homes available. Ensure Home app is set up and HomeKit access is granted." : nil
					if let (homeUUID, roomUUID, lightUUID) = viewModel.getAssociatedUUIDs(for: thermostat.id) {
						selectedHome = viewModel.homes.first { $0.uniqueIdentifier == homeUUID }
						rooms = selectedHome?.rooms ?? []
						selectedRoom = rooms.first { $0.uniqueIdentifier == roomUUID }
						lights = selectedRoom?.accessories.filter { $0.isColorLight } ?? []
						selectedLight = lights.first { $0.uniqueIdentifier == lightUUID }
					}
					isLoading = false
				}
		} else {
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
		}
	}
}

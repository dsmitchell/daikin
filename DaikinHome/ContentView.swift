//
//  ContentView.swift
//  DaikinHome
//
//  Created by David Mitchell on 10/18/25.
//

import HomeKit
import SwiftUI
import SwiftData

struct ContentView: View {
	@Environment(\.modelContext) private var modelContext
	@StateObject private var viewModel = DaikinViewModel()

	var body: some View {
		NavigationStack {
			List {
				Section(header: Text("Thermostats")) {
					ForEach(viewModel.thermostats, id: \.id) { thermostat in
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
				viewModel.loadThermostats()
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
	@State private var homes: [HMHome] = []
	@State private var rooms: [HMRoom] = []
	@State private var lights: [HMAccessory] = []
	
	var body: some View {
		Form {
			Section(header: Text("HomeKit Association")) {
				Picker("Home", selection: $selectedHome) {
					Text("None").tag(HMHome?.none)
					ForEach(homes, id: \.uniqueIdentifier) { home in
						Text(home.name).tag(home as HMHome?)
					}
				}
				.onChange(of: selectedHome) { newHome in
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
				.onChange(of: selectedRoom) { newRoom in
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
					if let light = selectedLight {
						viewModel.saveAssociation(for: thermostat.id, light: light)
					}
				}
				.disabled(selectedLight == nil)
			}
		}
		.navigationTitle("Associate Light")
		.onAppear {
			viewModel.homeManager.requestAccess { success in
				if success {
					homes = viewModel.homeManager.homes
				}
			}
			if let light = viewModel.getAssociatedLight(for: thermostat.id) {
				selectedHome = light.room?.home
				selectedRoom = light.room
				selectedLight = light
			}
		}
	}
}

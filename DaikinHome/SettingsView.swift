//
//  SettingsView.swift
//  daikin
//
//  Created by David Mitchell on 10/18/25.
//


import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: DaikinViewModel
    
    var body: some View {
        Form {
            Section(header: Text("Daikin Account")) {
                TextField("Email", text: $viewModel.email)
                    .autocapitalization(.none)
                SecureField("API Key", text: $viewModel.apiKey)
                SecureField("Integrator Token", text: $viewModel.integratorToken)
            }
        }
        .navigationTitle("Settings")
    }
}
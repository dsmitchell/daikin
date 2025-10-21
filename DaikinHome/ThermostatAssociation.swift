//
//  ThermostatAssociation.swift
//  DaikinHome
//
//  Created by David Mitchell on 10/21/25.
//

import SwiftData

@Model
class ThermostatAssociation {
	@Attribute(.unique) var thermostatId: String
    var homeUUID: String
    var roomUUID: String
    var lightUUID: String
    
    init(thermostatId: String, homeUUID: String, roomUUID: String, lightUUID: String) {
        self.thermostatId = thermostatId
        self.homeUUID = homeUUID
        self.roomUUID = roomUUID
        self.lightUUID = lightUUID
    }
}

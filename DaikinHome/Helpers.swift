import Foundation

func modeDescription(_ mode: Int) -> String {
	switch mode {
	case 0: return "Off"
	case 1: return "Heating"
	case 2: return "Cooling"
	case 3: return "Auto"
	case 4: return "Emergency Heat"
	default: return "Unknown"
	}
}

func equipmentStatusDescription(_ status: Int?) -> String {
	guard let status = status else { return "Unknown (nil)" }
	switch status {
	case 1: return "Cooling"
	case 2: return "Drying/Overcool"
	case 3: return "Heating"
	case 4: return "Fan Only"
	case 5: return "Idle"
	default: return "Unknown"
	}
}

func fanCirculateDescription(_ fanCirculate: Int?) -> String {
	guard let circulate = fanCirculate else { return "Unknown (nil)" }
	switch circulate {
	case 0: return "Circulate Off"
	case 1: return "Circulate Enabled"
	default: return "Unexpected"
	}
}

func fanDescription(_ fan: Int?) -> String {
	guard let fan = fan else { return "Unknown (nil)" }
	return fan == 0 ? "Not Running (0)" : "Non-Zero (\(fan))"
}

func setPointsDescription(mode: Int, heatSetpoint: Double?, coolSetpoint: Double?) -> String {
	switch mode {
	case 1: // Heating
		if let heat = heatSetpoint {
			return "Heat Setpoint: \(String(format: "%.1f", heat))°C"
		}
		return "Heat Setpoint: N/A"
	case 2: // Cooling
		if let cool = coolSetpoint {
			return "Cool Setpoint: \(String(format: "%.1f", cool))°C"
		}
		return "Cool Setpoint: N/A"
	case 3: // Auto
		let heat = heatSetpoint != nil ? String(format: "%.1f", heatSetpoint!) : "N/A"
		let cool = coolSetpoint != nil ? String(format: "%.1f", coolSetpoint!) : "N/A"
		return "Heat Setpoint: \(heat)°C, Cool Setpoint: \(cool)°C"
	default: // Off or Emergency Heat
		return "Setpoints: N/A"
	}
}

import AppIntents
import SwiftBluetooth
import CoreBluetooth

// TODO: Use ProgressReportingIntent.

struct GetBluetoothDevices: AppIntent {
	static let title: LocalizedStringResource = "Get Bluetooth Devices"

	static let description = IntentDescription(
		"""
		Returns the Bluetooth devices in range.

		DO NOT COPY THE IDENTIFIER FROM THE PREVIEW. Shortcuts sometimes adds an extra dash. Instead, fetch the "identifier" property.

		On iOS & visionOS, it has to open the main app while scanning because they do not allow scanning for arbitrary devices in the background.

		Use the “Get Bluetooth Device” action to check for a specific device.

		NOTE: You need to allow the Bluetooth permission in the main app before using this action.

		NOTE: The “connected” status may not be correct. For a correct connection status, use the “Get Bluetooth Device” action.

		NOTE: The “Services” field is only available in the “Get Bluetooth Device” action.
		""",
		categoryName: "Bluetooth",
		searchKeywords: [
			"ble",
			"peripheral"
		],
		resultValueName: "Bluetooth Devices"
	)

	// iOS & visionOS do not support scanning for arbitrary devices in the background.
	#if canImport(UIKit)
	static let openAppWhenRun = true
	#endif

	@Parameter(
		title: "Scan Duration (seconds)",
		description: "Default: 5. Max: 25",
		default: 5,
		inclusiveRange: (0, 25)
	)
	var scanDuration: Double

	@Parameter(title: "Include Unnamed Devices", default: false)
	var includeUnnamedDevices: Bool

	static var parameterSummary: some ParameterSummary {
		Summary("Get Bluetooth Devices (PLEASE READ THE ACTION DESCRIPTION)") {
			\.$scanDuration
			\.$includeUnnamedDevices
		}
	}

	@MainActor
	func perform() async throws -> some IntentResult & ReturnsValue<[BluetoothDevice_AppEntity]> {
		#if canImport(UIKit)
		try await Task.sleep(for: .seconds(0.1))
		AppState.shared.fullscreenMessage = "Scanning for Bluetooth devices"
		#endif

		defer {
			AppState.shared.fullscreenMessage = nil
		}

		let central = try await getBluetoothCentral()

		var devices = [UUID: BluetoothDevice_AppEntity]()

		// We have to pass in a list of known services because the API does not support getting all devices.
		let connectedDevices = central.retrieveConnectedPeripherals(withServices: CBCentralManager.commonServices)

		for await peripheral in await central.scanForPeripherals(timeout: scanDuration) {
			let name = peripheral.name ?? peripheral.discovery.advertisementData.localName

			if
				!includeUnnamedDevices,
				name == nil
			{
				continue
			}

			print("Discovered:", peripheral.name ?? "Unknown", peripheral.identifier)

			devices[peripheral.identifier] = BluetoothDevice_AppEntity(
				peripheral: peripheral,
				rssi: peripheral.discovery.rssi,
				isConnected: connectedDevices.contains { $0.identifier == peripheral.identifier }
			)
		}

		#if canImport(UIKit)
		ShortcutsApp.open()
		#endif

		return .result(value: Array(devices.values))
	}
}

@MainActor
func getBluetoothCentral() async throws -> CentralManager {
	try Bluetooth.ensureAccess()
	let central = CentralManager()
	try await central.waitUntilReady()
	return central
}

struct BluetoothDevice_AppEntity: TransientAppEntity {
	static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bluetooth Device"

	@Property(title: "Identifier")
	var identifier: String

	@Property(title: "Name")
	var name: String?

	@Property(title: "Is Connected")
	var isConnected: Bool

	@Property(title: "Signal Strength (as percentage in the range 0...1)")
	var signalStrength: Double

	@Property(title: "Received Signal Strength Indicator (RSSI)")
	var rssi: Int

	@Property(title: "Transmit Power Level (Tx)")
	var transmitPowerLevel: Int?

	@Property(title: "Services (UUIDs)")
	var services: [String]

	var displayRepresentation: DisplayRepresentation {
		.init(
			title: "\(name ?? "")",
			subtitle:
				"""
				Identifier: \(identifier)
				Connected: \(isConnected ? "true" : "false")
				Signal: \(signalStrength.formatted(.percent.noFraction))
				RSSI: \(rssi)
				Unique Services: \(services.filter { !CBCentralManager.commonServices.map(\.uuidString).contains($0) }.joined(separator: ", "))
				Services: \(services.joined(separator: ", "))
				"""
		)
	}
}

extension BluetoothDevice_AppEntity {
	init(
		peripheral: Peripheral,
		rssi: Int,
		isConnected: Bool,
		services: [CBUUID] = []
	) {
		let advertisementData = peripheral.discovery?.advertisementData
		let name = peripheral.name ?? advertisementData?.localName
		let txPowerLevel = advertisementData?.txPowerLevel

		self.identifier = peripheral.identifier.uuidString
		self.name = name
		self.isConnected = isConnected // `peripheral.state == .connected` only returns whether this app is connected to a device, not whether the system is.
		self.signalStrength = signalStrengthPercentage(rssi: rssi)
		self.rssi = rssi
		self.transmitPowerLevel = txPowerLevel
		self.services = services.map(\.uuidString)
	}
}

func signalStrengthPercentage(rssi: Int) -> Double {
	// Define the typical RSSI range for Bluetooth connections
	// Example: -100 dBm (weak) to -40 dBm (strong)
	let minRSSI = -100.0
	let maxRSSI = -40.0

	// Normalize the RSSI value within this range
	let percentage = (Double(rssi) - minRSSI) / (maxRSSI - minRSSI)

	return percentage.clamped(to: 0...1)
}

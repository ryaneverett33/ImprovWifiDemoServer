//
//  server.swift
//  ImprovWifiServer
//
//  Created by Ryan Everett on 12/27/23.
//

import Foundation
import Cocoa
import CoreBluetooth

/// Describes the current executing state of the server
enum ImprovState : Int {
    /// The state of the server is unknown or hasn't been started yet
    case Unknown = 0x0
    
    /// Awaiting authorization via physical interaction
    case AuthorizationRequired = 0x1
    
    /// Ready to accept credentials
    case Authorized = 0x2
    
    /// Credentials received, attempting to connect
    case Provisioning = 0x3
    
    /// Connection successful
    case Provisioned = 0x4
}

/// Describes the current error state of the server
enum ImprovErrorState : Int {
    /// This shows there is no current error state
    case NoError = 0x0
    
    /// RPC packet was malformed/invalid
    case InvalidRPCPacket = 0x1
    
    /// The command sent is unknown
    case UnknownRPCPacket = 0x2
    
    /// The credentials have been received and an attempt to connect to the network has failed
    case UnableToConnect = 0x3
    
    /// Credentials were sent via RPC but the Improv service is not authorized
    case NotAuthorized = 0x4
    
    /// An unknown server error has ocurred
    case UnknownError = 0xFF
}

/// Describes any known capabilities of the server
enum ImprovCapabilities: Int {
    /// Server has no known capabilities
    case None = 0x0
    
    /// Server accepts the identify command
    case CanBeIdentified = 0x1
}

/// Known valid RPC commands
enum ImprovRPCCommands: UInt8 {
    /// Command to submit ssid/password credientials and attempt to provision
    /// the device.
    case SubmitCredentials = 0x1
    
    /// Command to "identify" the server to the user. Typically involves blinking
    /// a light or playing a sound
    case Identify = 0x2
}

/// Get a string representation for a Bluetooth state
///
/// state: A valid bluetooth state to lookup
func BluetoothStatusToString(_ state: CBManagerState) -> String {
    switch state {
        case .unknown:
            return "UNKNOWN";
        case .unsupported:
            return "UNSUPPORTED";
        case .unauthorized:
            return "UNAUTHORIZED";
        case .resetting:
            return "RESETTING";
        case .poweredOff:
            return "POWERED OFF";
        case .poweredOn:
            return "POWERED ON";
        @unknown default:
            return "INVALID";
    }
}

/// Get a string representation for an Improv state
///
/// state: A valid improv state to lookup
func ImprovStateToString(_ state: ImprovState) -> String {
    switch state {
        case .AuthorizationRequired:
            return "Authorization Required";
        case .Authorized:
            return "Authorized";
        case .Provisioned:
            return "Provisioned";
        case .Provisioning:
            return "Provisioning";
        case .Unknown:
            return "Not Started/Unknown";
    }
}

/// Get a string representation for an improv error state
///
/// state: A valid improv error state to lookup
func ImprovErrorStateToString(_ state: ImprovErrorState) -> String {
    switch state {
        case .NoError:
            return "None";
        case .InvalidRPCPacket:
            return "Invalid RPC Packet";
        case .NotAuthorized:
            return "Not Authorized";
        case .UnableToConnect:
            return "Unable To Connect";
        case .UnknownError:
            return "Unknown";
        case .UnknownRPCPacket:
            return "Unknown RPC Packet";
    }
}

/// Helper function for converting a u8 to a data object
///
/// u8: The integer to convert to Data
func u8ToBytes(_ u8: Int) -> Data {
    return withUnsafeBytes(of: Int8(u8).littleEndian) { Data($0) }
}

/// Debug method for printing the contents of a data object
func dumpData(_ data: Data) {
    print(data.map { String(format: "%02x ", $0) }.joined())
}

/// The Server object that's responsible for managing bluetooth state
/// and operating the Improv protocol with connected clients
class ImprovWifiServer : NSObject, CBPeripheralManagerDelegate {
    /// A reference to the view controller so that we can update UI state
    /// and prompt for user feedback
    private var viewController: ViewController;
    
    /// The URL to redirect connected clients to after successful
    /// provisioning. Will be nil if not set in the UI
    private var redirectURL: String? = nil
    
    /// The timeout length to stay authorized if authorization
    /// is required. Will be nil if not set in the UI
    private var authorizationTimeout: Int? = nil
    
    /// The time left, in seconds, for the authorization timer
    /// once started. Will be nil if no timer is activated.
    private var authorizationTimeLeft: Int? = nil
    
    /// The timer instance responsible for revoking authorization.
    /// Will be nil if no authorization timer is set in the UI
    private var authorizationTimer: Timer? = nil
    
    // Improv Service deets
    
    /// The current server state
    private var state: ImprovState = ImprovState.Unknown;
    
    /// The state of the last error
    private var errorState: ImprovErrorState = ImprovErrorState.NoError;
    
    /// The known capabilities this server exposes
    /// Currently this is just: does the server support "identify"?
    private var capabilities: ImprovCapabilities = ImprovCapabilities.None;
    
    /// The result of the last RPC command
    private var rpcResult: Data? = nil
    
    // Bluetooth deets
    
    /// The constructed improv service to advertise over bluetooth
    private var bluetoothService: CBMutableService!
    
    /// A reference to the bluetooth manager that manages the improv
    /// service. Used for service advertisement and writing to
    /// subscribers
    private var bluetoothManager: CBPeripheralManager!
    
    /// A list of subscribers and their subscribed characteristic.
    /// When a characteristic's value is updated, subscribers in this
    /// list will be notified
    private var subscribers: [(CBCentral, CBCharacteristic)]
    
    /// A list of characteristic values that need to be resent to
    /// subscribers. This is primarily used when responding to
    /// the submitCredientials command
    private var resendQueue: [(CBMutableCharacteristic, Data)]
    
    // Improv Characteristics
    
    private var currentStateCharacteristic: CBMutableCharacteristic!
    private var errorStateCharacteristic: CBMutableCharacteristic!
    private var rpcResultCharacteristic: CBMutableCharacteristic!
    
    // Improv UUIDs
    
    static let CLIENT_CHARACTERISTIC_UUID: CBUUID = CBUUID(string: "2702")
    static let SERVICE_UUID: CBUUID = CBUUID(string:"00467768-6228-2272-4663-277478268000")
    static let CAPABILITIES_UUID: CBUUID = CBUUID(string: "00467768-6228-2272-4663-277478268005")
    static let CURRENT_STATE_UUID: CBUUID = CBUUID(string: "00467768-6228-2272-4663-277478268001")
    static let ERROR_STATE_UUID: CBUUID = CBUUID(string: "00467768-6228-2272-4663-277478268002")
    static let RPC_COMMAND_UUID: CBUUID = CBUUID(string: "00467768-6228-2272-4663-277478268003")
    static let RPC_RESULT_UUID: CBUUID = CBUUID(string: "00467768-6228-2272-4663-277478268004")
    
    init(controller: ViewController) {
        self.viewController = controller
        self.subscribers = []
        self.resendQueue = []
        super.init()
        
        // Update initial states in the UI
        self.UpdateImprovState(ImprovState.Unknown)
        self.updateErrorState(ImprovErrorState.NoError)
    }
    
    /// Calculates the checksum for an RPC request or response payload.
    /// The payload should match what will be sent or was recieved by the
    /// client. The last byte, the checksum byte, will be ignored when
    /// calculating the checksum. The command byte and data length byte
    /// are included in the checksum calculation
    ///
    /// payload: The data to calculate a checksum for
    static func CalculateChecksum(_ payload: Data) -> UInt8 {
        var checksum: UInt32 = 0
        
        for index in 0...payload.count - 2 {
            checksum += UInt32(payload[index])
        }
        return UInt8(truncatingIfNeeded: checksum)
    }
    
    /// Verify a recieved RPC packet has the correct checksum
    ///
    /// packet: The RPC packet to verify
    static func VerifyPacketChecksum(_ packet: Data) -> Bool {
        let expectedChecksum: UInt8 = packet[packet.count - 1]
        let calculatedChecksum: UInt8 = CalculateChecksum(packet)
        
        if expectedChecksum != calculatedChecksum {
            print("Packet has invalid checksum!")
            print(String(format: "Expected Checksum: %02x, Calculated Checksum: %02x", expectedChecksum, calculatedChecksum))
            return false
        }
        return true
    }
    
    /// Helper function for destroying the authorization timer
    private func clearTimer() {
        if let timer = self.authorizationTimer {
            timer.invalidate()
            self.authorizationTimer = nil
            self.authorizationTimeLeft = nil
            self.viewController.UpdateTimeoutValue(self.authorizationTimeout!)
        }
    }
    
    /// Helper function for notifying subscribers with updated data
    ///
    /// characteristic: The characteristic with updated data, used to find
    /// subscribers
    /// data: The updated data to write to subscribers
    private func updateSubscribers(characteristic: CBMutableCharacteristic, data: Data) {
        // Find any devices that are subscribed to the characteristic
        var stateSubscribers: [CBCentral] = []
        for subscriber in subscribers {
            if subscriber.1.uuid == characteristic.uuid {
                stateSubscribers.append(subscriber.0)
            }
        }
        
        // If there are subscribers, attempt to write the value and requeue if failed
        if !stateSubscribers.isEmpty {
            if !self.bluetoothManager.updateValue(data, for: characteristic, onSubscribedCentrals: stateSubscribers) {
                self.resendQueue.append((characteristic, data))
            }
        }
    }
    
    /// Update the current improv state and notify any subscribers. Additionally,
    /// this function handles starting and stopping the authorization timer
    ///
    /// newState: The new improv state for the serer
    private func UpdateImprovState(_ newState: ImprovState) {
        let justAuthorized: Bool = self.state == ImprovState.AuthorizationRequired && newState == ImprovState.Authorized
        
        // Keep track of the state and notify any subscribers
        self.state = newState
        self.viewController.UpdateImprovState(ImprovStateToString(newState))
        
        // The current state characteristic can be nil on initial server construction
        // where the bluetooth state hasn't been constructed. In this case, don't try to
        // notify any subscribers
        if let currentStateCharacteristic = self.currentStateCharacteristic {
            updateSubscribers(characteristic: currentStateCharacteristic, data: u8ToBytes(self.state.rawValue))
        }
        
        // If the server just became authorized, start the authorization timer
        // if it's enabled
        if justAuthorized && self.authorizationTimeout != nil {
            // start authorization timer
            self.authorizationTimeLeft = self.authorizationTimeout
            self.authorizationTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(authorizationTimerTick), userInfo: nil, repeats: true)
        }
        // If the server successfully provisioned, then clear the authorization
        // timer if it's been enabled
        else if newState == ImprovState.Provisioned {
            self.clearTimer()
        }
    }
    
    /// Update the current improv error state and notify any subscribers
    ///
    /// newState: The last error state
    private func updateErrorState(_ newState: ImprovErrorState) {
        self.errorState = newState
        self.viewController.UpdateImprovErrorState(ImprovErrorStateToString(newState))
        
        // Similarly to updateImproveState(), the error state characteristic is nil before
        // the service has been constructed. Don't try to notify subscribers in this case
        if let errorStateCharacteristic = self.errorStateCharacteristic {
            updateSubscribers(characteristic: errorStateCharacteristic, data: u8ToBytes(self.errorState.rawValue))
        }
    }
    
    /// Send the result of an RPC command to any clients who are subscribed
    /// to the RPC result characteristic
    ///
    /// command: The command that generated the result
    /// results: Results to send to clients
    private func sendRPCResult(command: ImprovRPCCommands, results: [String]) {
        // Construct the payload data. The payload data format is:
        // (String Length, String)*
        // The payload data may be empty if there are no results to send
        var payloadData: Data = Data()
        for result in results {
            let stringData: Data = Data(result.utf8)
            payloadData.append([UInt8(truncatingIfNeeded: stringData.count)], count: 1)
            payloadData.append(stringData)
        }
        
        // Construct the packet with the payload data. The packet format is:
        // Command byte
        // Payload Length byte
        // Payload bytes
        // Packet Checksum byte
        var packet: Data = Data(count: 3 + payloadData.count)
        packet[0] = command.rawValue
        packet[1] = UInt8(truncatingIfNeeded: payloadData.count)
        if results.count > 0 {
            packet[2...(2+payloadData.count - 1)] = payloadData
        }
        packet[2+payloadData.count] = ImprovWifiServer.CalculateChecksum(packet)
        
        // Actually send the packet
        self.rpcResult = packet
        updateSubscribers(characteristic: self.rpcResultCharacteristic, data: self.rpcResult!)
    }
    
    /// Helper function for creating, adding, and advertising the improv service.
    /// NOTE: the bluetooth device must be powered on to add the service
    private func addImprovService() {
        let emptyValue = Data(bytes: [0,0], count: 2)
        
        // Create the capabilities characteristic
        let capabilitiesCharacterisitic = CBMutableCharacteristic(type: ImprovWifiServer.CAPABILITIES_UUID, properties: [.read], value: nil, permissions: [.readable])
        capabilitiesCharacterisitic.descriptors = [CBMutableDescriptor(type: ImprovWifiServer.CLIENT_CHARACTERISTIC_UUID, value: emptyValue)]

        // Create the current state characteristic
        self.currentStateCharacteristic = CBMutableCharacteristic(type: ImprovWifiServer.CURRENT_STATE_UUID, properties: [.read, .notify], value: nil, permissions: [.readable])
        self.currentStateCharacteristic.descriptors = [CBMutableDescriptor(type: ImprovWifiServer.CLIENT_CHARACTERISTIC_UUID, value: emptyValue)]
        
        // Create the error state characteristic
        self.errorStateCharacteristic = CBMutableCharacteristic(type: ImprovWifiServer.ERROR_STATE_UUID, properties: [.read, .notify], value: nil, permissions: [.readable])
        self.errorStateCharacteristic.descriptors = [CBMutableDescriptor(type: ImprovWifiServer.CLIENT_CHARACTERISTIC_UUID, value: emptyValue)]

        // Create the RPC Command characteristic
        let rpcCommandCapability = CBMutableCharacteristic(type: ImprovWifiServer.RPC_COMMAND_UUID, properties: [.writeWithoutResponse], value: nil, permissions: [.writeable])
        rpcCommandCapability.descriptors = [CBMutableDescriptor(type: ImprovWifiServer.CLIENT_CHARACTERISTIC_UUID, value: emptyValue)]

        // Create the RPC Result Characteristic
        self.rpcResultCharacteristic = CBMutableCharacteristic(type: ImprovWifiServer.RPC_RESULT_UUID, properties: [.read, .notify], value: nil, permissions: [.readable])
        self.rpcResultCharacteristic.descriptors = [CBMutableDescriptor(type: ImprovWifiServer.CLIENT_CHARACTERISTIC_UUID, value: emptyValue)]
        
        // Create the service
        self.bluetoothService = CBMutableService(type: ImprovWifiServer.SERVICE_UUID, primary: true)
        self.bluetoothService.characteristics = [capabilitiesCharacterisitic,
                                                self.currentStateCharacteristic,
                                                self.errorStateCharacteristic,
                                                rpcCommandCapability,
                                                self.rpcResultCharacteristic]
        
        // Add the service
        self.bluetoothManager.removeAllServices()
        self.bluetoothManager.add(self.bluetoothService)
        
        // Start advertising the service
        self.bluetoothManager.startAdvertising([CBAdvertisementDataLocalNameKey : "Server", CBAdvertisementDataServiceUUIDsKey : [ImprovWifiServer.SERVICE_UUID]])
    }
    
    /// Enable the server and start advertising the service to clients. Bluetooth
    /// hardware must be powered on to enable the server
    ///
    /// requiresAuthorization: Whether the user must authorize the server before
    /// it can be provisioned
    /// canBeIdentified: Whether or not to enable the "Identify" command
    /// authorizationTimeout: An optional timeout before the client must re-authorize
    /// redirectionURL: An optional URL to report to the client after the device
    /// has been provisioned
    ///
    /// returns True if the server was enabled, False otherwise
    func enable(requiresAuthorization: Bool, canBeIdentified: Bool, authorizationTimeout: Int?, redirectionURL: String?) -> Bool {
        if self.bluetoothManager.state == .poweredOn {
            // Store setup values
            self.redirectURL = redirectionURL
            self.authorizationTimeout = authorizationTimeout
            
            // Start advertising the service and update initial state
            addImprovService()
            updateErrorState(ImprovErrorState.NoError)
            
            // NOTE: we don't need to save this value for two reasons
            // 1. If we don't require authorization, there's no way to get back to
            // the AuthorizationRequired state
            // 2. If we do require authorization, the authorization timer will handle
            // returning to AuthorizationRequired if it's enabled. If it's not enabled
            // then there is no way to return to AuthorizationRequired
            if requiresAuthorization {
                self.UpdateImprovState(ImprovState.AuthorizationRequired)
            }
            else {
                self.UpdateImprovState(ImprovState.Authorized)
            }
            return true
        }
        return false
    }
    
    /// Disables the server and stops advertising the service.
    func disable() {
        if self.bluetoothManager.state == .poweredOn {
            // Clear bluetooth data
            self.bluetoothManager.removeAllServices()
            self.bluetoothManager.stopAdvertising()
            self.subscribers.removeAll()
            
            // Clear the authorization timer if it exists
            self.clearTimer()
            
            // Reset improv states
            UpdateImprovState(ImprovState.Unknown)
            updateErrorState(ImprovErrorState.NoError)
            
            // Update the UI now that we're not advertising
            self.viewController.UpdateAdvertising(false)
        }
    }
    
    /// Authorize the server if authorization is required
    func buttonClick() {
        if self.state == ImprovState.AuthorizationRequired {
            self.UpdateImprovState(ImprovState.Authorized)
        }
    }
    
    /// Authorization timer function. Updates the UI for time remaining
    /// and revokes authorization when time is up
    @objc private func authorizationTimerTick() {
        self.authorizationTimeLeft! -= 1
        self.viewController.UpdateTimeoutValue(self.authorizationTimeLeft!)
        
        if self.authorizationTimeLeft! <= 0 {
            self.clearTimer()
            
            // Revoke authorization
            self.UpdateImprovState(ImprovState.AuthorizationRequired)
        }
    }
    
    /// Callback function to indicate that the WiFi connection was successful
    func wifiConnected() {
        UpdateImprovState(ImprovState.Provisioned)
        
        // If the user configured a redirect url, send it as the result of the command,
        // otherwise send an empty result
        let results: [String] = redirectURL != nil ? [redirectURL!] : []
        sendRPCResult(command: ImprovRPCCommands.SubmitCredentials, results: results)
    }
    
    /// Callback function to indicate that the WiFi connection was not successful
    func wifiFailedToConnect() {
        updateErrorState(ImprovErrorState.UnableToConnect)
        UpdateImprovState(ImprovState.Authorized)
    }

    func peripheralManagerDidUpdateState(_ manager: CBPeripheralManager) {
        // Save a reference to the manager if we haven't already
        if self.bluetoothManager == nil {
            self.bluetoothManager = manager
        }
        
        // Disable the service if bluetooth is disabled
        if manager.state == .poweredOff && self.bluetoothService != nil {
            self.disable()
            self.viewController.BluetoothDisabled()
        }
        
        // Update the UI with the current state
        print(String(format: "Bluetooth Device is %@", BluetoothStatusToString(manager.state)))
        self.viewController.UpdateBluetoothState(manager.state)
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        // Respond to the client read request with the characteristic data
        switch request.characteristic.uuid {
            case ImprovWifiServer.CURRENT_STATE_UUID:
                print("Reading Current State")
                request.value = u8ToBytes(self.state.rawValue)
                peripheral.respond(to: request, withResult: CBATTError.success)
                break
            case ImprovWifiServer.ERROR_STATE_UUID:
                print("Reading Error State")
                request.value = u8ToBytes(self.errorState.rawValue)
                peripheral.respond(to: request, withResult: CBATTError.success)
                break
            case ImprovWifiServer.RPC_RESULT_UUID:
                print("Reading RPC result")
                peripheral.respond(to: request, withResult: CBATTError.requestNotSupported)
                break
            case ImprovWifiServer.CAPABILITIES_UUID:
                print("Reading capabilities result")
                request.value = u8ToBytes(self.capabilities.rawValue)
                peripheral.respond(to: request, withResult: CBATTError.success)
            default:
                // client tried to read an unrecognized characteristic, return an error
                print("Reading unrecognized characteristic")
                print("Characteristic UUID: " + request.characteristic.uuid.uuidString)
                peripheral.respond(to: request, withResult: CBATTError.requestNotSupported)
            }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            // If the write is an RPC command, decode it and respond to it
            if request.characteristic.uuid == ImprovWifiServer.RPC_COMMAND_UUID {
                print("Client wrote an RPC Command")
                // Reset the last RPC result if it exists
                self.rpcResult = nil
                
                if let rpcPayload = request.value {
                    // Verify payload integrity
                    if !ImprovWifiServer.VerifyPacketChecksum(rpcPayload) {
                        self.updateErrorState(ImprovErrorState.InvalidRPCPacket)
                        return
                    }
                    
                    if rpcPayload[0] == ImprovRPCCommands.SubmitCredentials.rawValue {
                        print("Client submitted wifi credientials")
                        if self.state != ImprovState.Authorized {
                            self.updateErrorState(ImprovErrorState.NotAuthorized)
                            return
                        }
                        
                        // Payload format (excluding command and checksum byte) looks like:
                        // SSID Length byte
                        // SSID bytes
                        // Password Length byte
                        // Password bytes
                        
                        let ssidStart: Int = 3
                        let ssidLength: Int = Int(rpcPayload[2])
                        let ssidEnd: Int = ssidStart + ssidLength
                        
                        let passwordStart: Int = ssidEnd + 1
                        let passwordLength: Int = Int(rpcPayload[ssidEnd])
                        let passwordEnd: Int = passwordStart + passwordLength
                        
                        let ssid: String = String(decoding: rpcPayload.subdata(in: Range(ssidStart...ssidEnd - 1)), as: UTF8.self)
                        let password: String = String(decoding: rpcPayload.subdata(in: Range(passwordStart...passwordEnd - 1)), as: UTF8.self)
                        
                        print(String(format: "Received SSID: %@, Password: %@", ssid, password))
                        self.UpdateImprovState(ImprovState.Provisioning)
                        
                        self.viewController.PromptFakeWifiConnection(ssid: ssid, password: password)
                    }
                    else if rpcPayload[0] == ImprovRPCCommands.Identify.rawValue {
                        print("Client invoked identify command")
                        
                        if self.state == ImprovState.AuthorizationRequired ||
                            self.state == ImprovState.Authorized {
                            self.viewController.Identify()
                        }
                        else {
                            print("Client sent the identify command during an invalid state")
                            
                            // Possible Improv Question: Should there be an actual error case for this?
                            self.updateErrorState(ImprovErrorState.UnknownError)
                        }
                    }
                    else {
                        // Unknown RPC Command
                        print("RPC Packet has unknown command")
                        self.updateErrorState(ImprovErrorState.UnknownRPCPacket)
                    }
                }
                else {
                    // Malformed request
                    print("RPC Packet has no payload")
                    self.updateErrorState(ImprovErrorState.InvalidRPCPacket)
                }
            }
            else {
                // client tried to read an unrecognized characteristic, do nothing
                print("Write to unknown characteristic: " + request.characteristic.uuid.uuidString)
            }
        }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        // A client subscribed to a characteristic, update self.subscribers
        switch characteristic.uuid {
            case ImprovWifiServer.CURRENT_STATE_UUID:
                print("Client subscribed to current state")
                self.subscribers.append((central, characteristic))
            case ImprovWifiServer.ERROR_STATE_UUID:
                print("Client subscribed to error state")
                self.subscribers.append((central, characteristic))
            case ImprovWifiServer.RPC_RESULT_UUID:
                print("Client subscribed to rpc result")
                self.subscribers.append((central, characteristic))
            default:
                print("Client subscribed to unknown characteristic: " + characteristic.uuid.uuidString)
        }
        
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        // A client unsubscribed to a characteristic, update self.subscribers
        switch characteristic.uuid {
            case ImprovWifiServer.CURRENT_STATE_UUID:
                print("Client unsubscribed from current state")
            case ImprovWifiServer.ERROR_STATE_UUID:
                print("Client unsubscribed from error state")
            case ImprovWifiServer.RPC_RESULT_UUID:
                print("Client unsubscribed from rpc result")
            default:
                print("Client unsubscribed from unknown characteristic: " + characteristic.uuid.uuidString)
            }
        
        // Find the subscriber in the list of subscribers and remove it.
        // There should only be one instance of it
        if let index = self.subscribers.firstIndex(where: {
            $0.0 == central && $0.1 == characteristic
        }) {
            self.subscribers.remove(at: index)
        }
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // Work through the resendQueue until a resend fails. When a resend fails, it will
        // remain in the queue and this function will eventually be called again to send it
        while (resendQueue.count > 0) {
            let job: (CBMutableCharacteristic, Data) = resendQueue.first!
            if peripheral.updateValue(job.1, for: job.0, onSubscribedCentrals: nil) {
                resendQueue.remove(at: 0)
            }
            else {
                break
            }
        }
    }
    
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        // Update the UI to indicate that the service is being advertised
        //self.viewController.UpdateAdvertising(peripheral.isAdvertising)
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if error == nil {
            print("Added service: " + service.uuid.uuidString)
        }
        else {
            print("Failed to add service: " + service.uuid.uuidString)
            if let error = error {
                print("Error: " + error.localizedDescription)
            }
            
            // Stop the server and update the UI
            self.disable()
            self.viewController.FailedToStart()
        }
    }
}


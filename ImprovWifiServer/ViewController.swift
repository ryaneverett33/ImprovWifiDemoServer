import Cocoa
import CoreBluetooth

class ViewController: NSViewController, NSTextFieldDelegate {
    // labels
    @IBOutlet weak var isAdvertisingLabel: NSTextField!
    @IBOutlet weak var improvStateLabel: NSTextField!
    @IBOutlet weak var bluetoothStateLabel: NSTextField!
    @IBOutlet weak var authorizeButton: NSButton!
    @IBOutlet weak var improvErrorStateLabel: NSTextField!
    
    // text fields
    @IBOutlet weak var authorizationTimeoutValue: NSTextField!
    @IBOutlet weak var redirectionURLValue: NSTextField!
    
    // toggles
    @IBOutlet weak var requiresAuthToggle: NSButton!
    @IBOutlet weak var serviceActivateToggle: NSSwitch!
    @IBOutlet weak var canIdentifyToggle: NSButton!
    @IBOutlet weak var authorizationTimeoutToggle: NSButton!
    
    private var server : ImprovWifiServer!
    private var manager : CBPeripheralManager!
    override func viewDidLoad() {
        // Perform any initial value setting
        isAdvertisingLabel.stringValue = "false"
        
        // Setup the formatter for the Authorization Timeout field
        let formatter = DateFormatter()
        formatter.dateFormat = "mm:ss"
        authorizationTimeoutValue.formatter = formatter
        authorizationTimeoutValue.delegate = self
        
        super.viewDidLoad()
        
        // Create the ImprovServer and Bluetooth Manager
        server = ImprovWifiServer(controller: self)
        manager = CBPeripheralManager(delegate: server, queue: DispatchQueue.main)
    }

    /// Update the IsAdvertising value in the UI
    ///
    /// isAdvertising: Whether or not bluetooth services are being advertised
    func UpdateAdvertising(_ isAdvertising: Bool) {
        DispatchQueue.main.async {
            self.isAdvertisingLabel.stringValue = String(isAdvertising)
        }
    }
    
    /// Update the Bluetooth State value in the UI
    ///
    /// state: The new Bluetooth state to report
    func UpdateBluetoothState(_ state: CBManagerState) {
        DispatchQueue.main.async {
            self.bluetoothStateLabel.stringValue = BluetoothStatusToString(state)
        }
    }
    
    /// Update the Improv State value in the UI
    ///
    /// state: The new Improv State, in string form, to report
    func UpdateImprovState(_ state: String) {
        DispatchQueue.main.async {
            self.improvStateLabel.stringValue = state
        }
    }
    
    /// Update the Improv Error State value in the UI
    ///
    /// state: The new Improv Error State, in string form, to report
    func UpdateImprovErrorState(_ state: String) {
        DispatchQueue.main.async {
            self.improvErrorStateLabel.stringValue = state
        }
    }
    
    /// A callback function used to "Identify" the device to the user.
    /// This method is invoked by the Server whenever the Identify command
    /// is recieved.
    func Identify() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Client issued the Identify command"
            alert.informativeText = "Identify"
            alert.runModal()
        }
    }
    
    /// Update the Authorization Timeout value in the UI
    ///
    /// timeLeft: The time left in ms for the authorization timer
    func UpdateTimeoutValue(_ timeLeft: Int) {
        let minutes: Int = timeLeft / 60
        let seconds: Int = timeLeft % 60
        self.authorizationTimeoutValue.stringValue = String(format: "%d:%d", minutes, seconds)
    }
    
    /// A callback function used to connect the device to the wifi.
    /// Instead of actually connecting and modifying system wifi settings,
    /// an input prompt is given to the user to "accept" the connection.
    /// This method is invoked by the Server whenever the send credientials
    /// command is recieved.
    ///
    /// ssid: The ssid to connect to
    /// password: The password to use for the connection
    func PromptFakeWifiConnection(ssid: String, password: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Connect To WiFi (Fake)"
            alert.informativeText = String(format: """
Accept the WiFi Connection?\n
SSID: %@, Password: %@\n
NOTE: This does not modify WiFi settings.
""", ssid, password)
            
            alert.addButton(withTitle: "Accept")
            alert.addButton(withTitle: "Deny")
            let result: NSApplication.ModalResponse = alert.runModal()
            if result == .alertFirstButtonReturn {
                self.server.wifiConnected()
            }
            else if result == .alertSecondButtonReturn {
                self.server.wifiFailedToConnect()
            }
        }
    }
    
    /// Helper function for server conditions that result in a "stop"
    private func stop() {
        DispatchQueue.main.async {
            // Reset the UI
            self.serviceActivateToggle.state = .off
            self.sliderActivation(self)
        }
    }
    
    /// Callback function in case the server fails to start
    func FailedToStart() {
        self.stop()
        DispatchQueue.main.async {
            // Tell the user that the activation failed
            let alert = NSAlert()
            alert.messageText = "Failed to Start Server"
            alert.informativeText = "Failed to start server, check logs for more info"
            alert.runModal()
        }
    }
    
    /// Callback function in case bluetooth hardware is disabled
    func BluetoothDisabled() {
        self.stop()
        DispatchQueue.main.async {
            // Tell the user that the activation failed
            let alert = NSAlert()
            alert.messageText = "Bluetooth Disabled"
            alert.informativeText = "Bluetooth Hardware was disabled, please re-enable it to continue"
            alert.runModal()
        }
    }
    
    /// Function handler for the UI Button click
    @IBAction func buttonClick(_ sender: Any) {
        self.server.buttonClick()
    }
    
    /// Function handler for the Activate slider. When activated, the
    /// Server is enabled and initiates the Improv process. When
    /// deactivated, the server is disabled. UI settings are restricted
    /// when the server is enabled and unrestricted when it's not.
    @IBAction func sliderActivation(_ sender: Any) {
        let useTimeout: Bool = self.authorizationTimeoutToggle.state == .on && self.authorizationTimeoutToggle.isEnabled
        
        // don't allow the user toggle initialization settings
        requiresAuthToggle.isEnabled = (serviceActivateToggle.state == .off)
        canIdentifyToggle.isEnabled = (serviceActivateToggle.state == .off)
        authorizationTimeoutValue.isEnabled = (serviceActivateToggle.state == .off)
        authorizationTimeoutToggle.isEnabled = (serviceActivateToggle.state == .off)
        redirectionURLValue.isEnabled = (serviceActivateToggle.state == .off)
        
        if (serviceActivateToggle.state == .on) {
            // turn on service
            let redirectURL = self.redirectionURLValue.stringValue != "" ? self.redirectionURLValue.stringValue : nil
            var timeout: Int? = nil
            if useTimeout {
                timeout = 0
                let timeoutString: String = self.authorizationTimeoutValue.stringValue
                
                let minuteEnd = String.Index(utf16Offset: 1, in: timeoutString)
                let secondStart = String.Index(utf16Offset: 3, in: timeoutString)
                if let minuteValue = Int(timeoutString[...minuteEnd]) {
                    timeout! += 60 * minuteValue
                    if let secondValue = Int(timeoutString[secondStart...]) {
                        timeout! += secondValue
                    }
                }
            }
            
            if !self.server.enable(requiresAuthorization: self.requiresAuthToggle.state == .on,
                                   canBeIdentified: self.canIdentifyToggle.state == .on,
                                   authorizationTimeout: timeout,
                                   redirectionURL: redirectURL) {
                serviceActivateToggle.state = .off
                requiresAuthToggle.isEnabled = true
                canIdentifyToggle.isEnabled = true
                
                let alert = NSAlert()
                alert.messageText = "Make sure bluetooth is enabled and the app has permission to use it"
                alert.informativeText = "Failed to start Improv Server"
                alert.runModal()
            }
            if self.requiresAuthToggle.state == .off {
                authorizeButton.isEnabled = false
            }
        }
        else {
            // turn off service
            self.server.disable()
            
            authorizeButton.isEnabled = true
            if self.requiresAuthToggle.state == .off {
                authorizationTimeoutValue.isEnabled = false
                authorizationTimeoutToggle.isEnabled = false
            }
            
        }
    }
    
    /// Function handler for the Enable Authorization Timeout button
    @IBAction func enableTimeoutClick(_ sender: Any) {
        self.authorizationTimeoutValue.isEnabled = self.authorizationTimeoutToggle.state == .on
        self.serviceActivateToggle.isEnabled = self.authorizationTimeoutToggle.state == .off
    }
    
    /// Function handler for the Requires Authorization button
    @IBAction func requiresAuthorizationClick(_ sender: Any) {
        if self.requiresAuthToggle.state == .on {
            self.authorizationTimeoutToggle.isEnabled = true
            self.authorizationTimeoutValue.isEnabled = self.authorizationTimeoutToggle.state == .on
        }
        else {
            self.authorizationTimeoutToggle.isEnabled = false
            self.authorizationTimeoutValue.isEnabled = false
        }
    }
    
    /// Callback function for editing the authorization timeout value.
    /// Service activation is disabled until a valid timeout value is
    /// entered or the timeout is disabled.
    func controlTextDidBeginEditing(_ obj: Notification) {
        self.serviceActivateToggle.isEnabled = false
    }
    
    /// Callback function for finalizing edits to the authorization
    /// timeout value. Restores service activation if possible.
    func controlTextDidEndEditing(_ obj: Notification) {
        if !self.authorizationTimeoutValue.stringValue.isEmpty {
            self.serviceActivateToggle.isEnabled = true
        }
    }
}

# ImprovWiFiDemoServer

<p align="center">
  <img alt="Screenshot" src="https://github.com/ryaneverett33/ImprovWifiDemoServer/raw/main/images/screenshot.png" title="Screenshot">
</p>

This project implements an example macOS Server for the [Improv Wi-Fi](https://www.improv-wifi.com/) [Bluetooth Low Energy Protocol](https://www.improv-wifi.com/ble/). This server is purely for educational purposes and does not actually provision the server device. Instead, the server can be used, in conjunction with a client, to step through the provisioning process and test out the Improv protocol.

## Using the Server

In order to use the server, simply click the `Activate` button in the bottom-left corner. Then, on a separate and supported device, navigate to [improv-wifi.com](https://www.improv-wifi.com/) and click the `Connect device to Wi-Fi` button. 

<p align="center">
  <img alt="Connect device to Wi-Fi" src="https://github.com/ryaneverett33/ImprovWifiDemoServer/raw/main/images/provisioning-connect-to-wifi.png" title="Connect device to Wi-Fi" width="400px">
</p>

One you click the `Connect device to Wi-Fi` button, you can select the `Server` and start the provisioning process.

<p align="center">
  <img alt="Select Device to Pair" src="https://github.com/ryaneverett33/ImprovWifiDemoServer/raw/main/images/provisioning-select-server.png" title="Select Device to Pair">
</p>

Now you'll be able to go through the full provisioning process.

## Server options

### Requires Authorization

This toggle determines whether or not the server/device must first be authorized before it can be provisioned. If authorization is required, the user must click the "Button" to authorize the process.

### Can Be Identified

This toggle determines whether or not the server/device supports the "identify" command. The "identify" command allows for the provisioning process to "locate" the server/device by causing the server/device to play a sound or flashing a light. This demo server implements the "identify" command by creating a popup to the user.

### Enable Authorization Timeout/Authorization Timeout

If the server/device requires an authorization prior to provisioning, a timeout can be supplied to revoke authorization after a given time.

### Redirection URL

This option allows the user to specify an optional URL to redirect the provisioning device to upon successful provisioning. If no Redirection URL is given, no URL will be returned to the provisioning device and no redirection will/should occur.
Cellular Modem support
======================

Support cellular modems with QMI or ECM mode using ModemManager.
This should support any modem that ModemManager supports.
It does not support PPP mode at all.
The main functionality implemented here is:

- Configure the modem according to /etc/sensorgnome/cellular.json
- Baby-sit the modem so it stays connected

In addition, sg-control queries mmcli directly to display the current modem status.

## Notes

- QMI vs. ECM: https://www.jeffgeerling.com/blog/2022/using-4g-lte-wireless-modems-on-raspberry-pi
  Bottom line is that in ECM mode the cell modem acts as a router with NAT while in
  QMI mode the host gets direct cell IP address and connection.
  In both modes the data flow through a network driver that is built into Linux and
  the modem shows up as wwan0 or usb0 device.
  This is in contrast to PPP where a user-level process sends/receives data using a
  serial interface.

- On LTE links there is no DHCP server on the network, IP information is provided during connection
  setup, statically through the LTE protocol.
  The DHCP server that responds on the link is specific to QMI (if you switch modem into MBIM mode there will be no DHCP server any more), and located on the modem, it is serving this static
  IP to the DHCP client so "everything works as usual".

- Undocumented mmcli commands:
  - sudo mmcli -m 1 --3gpp-profile-manager-list
  - sudo mmcli -m 0 --3gpp-set-initial-eps-bearer-settings=apn=m2mglobal,ip-type=ipv4

- Sixfab HAT:
  - GPIO13 is DTR, pulse low to wake-up modem from deep sleep
  - GPIO26 controls power: pull high to turn power OFF

- Lucas mods (2026):
  - Checks cellular/config.json for bad IMSI prefixes, cycles it if it's in the list.
  - Default list only includes Jersey ("23450")
```
sudo systemctl stop check-modem check-modem.timer
sudo rm /etc/sensorgnome/stk_enabled
sudo rm -f /run/check-modem/imsi_ok
sudo mv ~/check-modem.sh /opt/sensorgnome/cellular
sudo systemctl daemon-reload
sudo systemctl start check-modem check-modem.timer
journalctl -u check-modem -f

```


### Known issues
I think sg-control interferes with check-modem when it runs mmcli (in `/opt/sensorgnome/control/cellular.js`) so it's basically hobbling itself. It still manages to get it to run since check-modem is run on a schedule, but it should really be better coordinated.

#### Here's how it's interfering

##### Check modem starts up and cycles:
```
Jun 01 19:52:21 SG-C03BRPI38ADE check-modem[1194]: Modem 0 state: enabled, APN: super ipv4v6, Operator: -- --
Jun 01 19:52:22 SG-C03BRPI38ADE check-modem[1194]: Mon  1 Jun 19:52:22 UTC 2026
Jun 01 19:52:22 SG-C03BRPI38ADE check-modem[1194]: #2: Performing a scan
Jun 01 19:52:31 SG-C03BRPI38ADE check-modem[1194]: error: couldn't scan networks in the modem: 'unknown error'
Jun 01 19:52:31 SG-C03BRPI38ADE check-modem[1194]: Found no available operators
Jun 01 19:52:31 SG-C03BRPI38ADE check-modem[1194]: #2: Connecting modem 0, apn=super ip-type=ipv4v6 allow-roaming=yes
Jun 01 19:53:35 SG-C03BRPI38ADE check-modem[1194]: Modem 0 state: enabled, APN: super ipv4v6, Operator: -- --
Jun 01 19:53:37 SG-C03BRPI38ADE check-modem[1194]: Mon  1 Jun 19:53:37 UTC 2026
Jun 01 19:53:37 SG-C03BRPI38ADE check-modem[1194]: #3: Performing a scan
Jun 01 19:53:38 SG-C03BRPI38ADE check-modem[1194]: error: couldn't scan networks in the modem: 'unknown error'
Jun 01 19:53:38 SG-C03BRPI38ADE check-modem[1194]: Found no available operators
Jun 01 19:53:38 SG-C03BRPI38ADE check-modem[1194]: #3: Connecting modem 0, apn=super ip-type=ipv4v6 allow-roaming=yes
Jun 01 19:54:39 SG-C03BRPI38ADE check-modem[1194]: Modem 0 state: enabled, APN: super ipv4v6, Operator: -- --
Jun 01 19:54:41 SG-C03BRPI38ADE check-modem[1194]: Mon  1 Jun 19:54:41 UTC 2026
Jun 01 19:54:41 SG-C03BRPI38ADE check-modem[1194]: #4: Performing a scan
Jun 01 19:54:50 SG-C03BRPI38ADE check-modem[1194]: error: couldn't scan networks in the modem: 'unknown error'
Jun 01 19:54:50 SG-C03BRPI38ADE check-modem[1194]: Found no available operators
Jun 01 19:54:50 SG-C03BRPI38ADE check-modem[1194]: #4: Connecting modem 0, apn=super ip-type=ipv4v6 allow-roaming=yes
Jun 01 19:55:55 SG-C03BRPI38ADE check-modem[1194]: Modem 0 state: enabled, APN: super ipv4v6, Operator: -- --
Jun 01 19:55:56 SG-C03BRPI38ADE check-modem[1194]: Mon  1 Jun 19:55:56 UTC 2026
Jun 01 19:55:56 SG-C03BRPI38ADE check-modem[1194]: #5: Performing a scan
Jun 01 19:56:28 SG-C03BRPI38ADE check-modem[1194]: Found 4 available operators: 302220 302270 302610 302720
Jun 01 19:56:28 SG-C03BRPI38ADE check-modem[1194]: #5: Registering with operator 302720
```
##### Meanwhile sg-control has already started asking about the cell status:
```
Jun 01 19:56:31 SG-C03BRPI38ADE sg-control[850]: getCellStatus: /usr/bin/mmcli -m 0 -J --3gpp-scan failed: error: couldn't scan networks in the modem: 'GDBus.Error:org.freedesktop.ModemManager1.Error.Core.Failed: QMI protocol error: Couldn't scan networks: QMI protocol>
Jun 01 19:56:31 SG-C03BRPI38ADE sg-control[850]: getCellStatus: /usr/bin/mmcli -m 0 -J --3gpp-scan failed: error: couldn't scan networks in the modem: 'GDBus.Error:org.freedesktop.ModemManager1.Error.Core.Failed: QMI protocol error: Couldn't scan networks: QMI protocol>
```
##### This causes check-modem to fail:
```
Jun 01 19:56:35 SG-C03BRPI38ADE check-modem[1194]: error: couldn't register the modem: 'GDBus.Error:org.freedesktop.ModemManager1.Error.Core.Failed: Failed: Couldn't peek QMI port'
Jun 01 19:56:36 SG-C03BRPI38ADE check-modem[1194]: error: couldn't find modem
Jun 01 19:56:36 SG-C03BRPI38ADE systemd[1]: check-modem.service: Main process exited, code=exited, status=1/FAILURE
Jun 01 19:56:36 SG-C03BRPI38ADE systemd[1]: check-modem.service: Failed with result 'exit-code'.
Jun 01 19:56:36 SG-C03BRPI38ADE systemd[1]: check-modem.service: Consumed 16.230s CPU time.
Jun 01 19:56:36 SG-C03BRPI38ADE systemd[1]: Started check-modem.service - Baby-sit cellular modem.
Jun 01 19:56:36 SG-C03BRPI38ADE check-modem[2536]: Mon  1 Jun 19:56:36 UTC 2026
Jun 01 19:56:37 SG-C03BRPI38ADE check-modem[2536]: No modem found
Jun 01 19:56:37 SG-C03BRPI38ADE systemd[1]: check-modem.service: Main process exited, code=exited, status=1/FAILURE
Jun 01 19:56:37 SG-C03BRPI38ADE systemd[1]: check-modem.service: Failed with result 'exit-code'.


```
##### The next time check-modem starts up it runs smoothly:
```
Jun 01 19:58:44 SG-C03BRPI38ADE check-modem[2684]: Mon  1 Jun 19:58:44 UTC 2026
Jun 01 19:58:46 SG-C03BRPI38ADE check-modem[2684]: Modem 1 state: disabled, APN: super ipv4v6, Operator: -- --
Jun 01 19:58:48 SG-C03BRPI38ADE check-modem[2684]: Enabling modem
Jun 01 19:58:49 SG-C03BRPI38ADE check-modem[2684]: successfully enabled the modem
Jun 01 19:58:51 SG-C03BRPI38ADE check-modem[2684]: Successfully set initial EPS bearer properties
Jun 01 19:58:51 SG-C03BRPI38ADE check-modem[2684]: Successfully setup signal quality information polling
Jun 01 19:58:52 SG-C03BRPI38ADE check-modem[2684]: Mon  1 Jun 19:58:52 UTC 2026
Jun 01 19:58:52 SG-C03BRPI38ADE check-modem[2684]: #1: Connecting modem 1, apn=super ip-type=ipv4v6 allow-roaming=yes
Jun 01 19:58:54 SG-C03BRPI38ADE check-modem[2684]: Modem 1 state: connected, APN: super ipv4v6, Operator: 302720 Rogers Wireless
Jun 01 19:58:55 SG-C03BRPI38ADE check-modem[2684]: default via 100.80.117.125 dev wwan0 proto dhcp src 100.80.117.124 metric 10001 mtu 1360
Jun 01 19:58:55 SG-C03BRPI38ADE check-modem[2684]: RX bytes in last 90 minutes: 0
Jun 01 19:58:55 SG-C03BRPI38ADE check-modem[2684]: Default route uses wwan0
Jun 01 19:58:55 SG-C03BRPI38ADE check-modem[2684]: No traffic in last 90 minutes, pinging 1.1.1.1
Jun 01 19:59:15 SG-C03BRPI38ADE check-modem[2684]: Ping OK
Jun 01 19:59:15 SG-C03BRPI38ADE check-modem[2684]: Successfully setup signal quality information polling
Jun 01 19:59:15 SG-C03BRPI38ADE systemd[1]: check-modem.service: Deactivated successfully.
Jun 01 19:59:15 SG-C03BRPI38ADE systemd[1]: check-modem.service: Consumed 5.968s CPU time.
```
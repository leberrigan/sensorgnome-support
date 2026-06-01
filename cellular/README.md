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
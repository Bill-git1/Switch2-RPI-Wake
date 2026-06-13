# Switch2-RPI-Wake

Wake a docked **Nintendo Switch 2** from a **Raspberry Pi Zero 2 W** by replaying a captured **Joy-Con 2 BLE wake advertisement**.

This is useful for remote Switch 2 setups where the Pi already acts as a USB gadget/controller device, for example with [NS-PC-Control](https://github.com/Dycool/NS-PC-Control). The Pi wakes the console over BLE, then your existing USB controller path can take over once the Switch 2 is awake.

> Tested with a Raspberry Pi Zero 2 W and a captured right Joy-Con 2 wake packet.

---

## What this does

A paired Joy-Con 2 wakes the Switch 2 by briefly broadcasting a Nintendo BLE advertisement.

This project replays that wake advertisement from the Pi by:

1. Stopping `bluetoothd` so it does not interfere.
2. Setting the Pi Bluetooth public address to the captured Joy-Con 2 MAC.
3. Configuring raw BLE advertising.
4. Broadcasting the captured Nintendo manufacturer advertisement.
5. Stopping advertising.

The wake payload is controller-specific enough that public example packets may not work. The reliable method is to capture your own Joy-Con 2 wake packet.

---

## Hardware requirements

- Raspberry Pi Zero 2 W
- Raspberry Pi OS Lite
- Docked Nintendo Switch 2
- Paired Joy-Con 2, preferably the right Joy-Con 2 because it has the HOME button
- Android phone with **nRF Connect** for capturing your own BLE packet

---

## Install dependencies

```bash
sudo apt update
sudo apt install -y bluez rfkill
```

Check that the required tools exist:

```bash
which btmgmt
which hcitool
which bluetoothctl
```

Check that the Pi has a Bluetooth controller:

```bash
bluetoothctl show
sudo btmgmt info
```

If Bluetooth is blocked:

```bash
rfkill list
sudo rfkill unblock bluetooth
sudo systemctl restart bluetooth
```

---

## Make the script executable

The repo includes the wake script as:

```text
ns2-ble-wake-v4-raw
```

Make it executable:

```bash
chmod +x ./ns2-ble-wake-v4-raw
```

> The script name still says `v4`; that is fine. It is the raw HCI wake sender used by this guide.

---

## Known-good example

This command woke the Switch 2 in testing:

```bash
sudo ./ns2-ble-wake-v4-raw \
  --mac '98:E2:55:B1:28:5B' \
  --adv '0201061BFF53050100037E056620000181AB669B55E2980F00000000000000' \
  --seconds 1
```

Captured Joy-Con 2 BLE MAC:

```text
98:E2:55:B1:28:5B
```

Captured wake advertising payload:

```text
0201061BFF53050100037E056620000181AB669B55E2980F00000000000000
```

The payload contains Nintendo manufacturer data:

```text
Company ID: 0x0553
Raw byte order in advert: 53 05
```

---

## Wake the Switch 2

Put the Switch 2 into **normal sleep mode**. This does not wake a fully powered-off console.

Run:

```bash
sudo ./ns2-ble-wake-v4-raw \
  --mac '98:E2:55:B1:28:5B' \
  --adv '0201061BFF53050100037E056620000181AB669B55E2980F00000000000000' \
  --seconds 1
```

The console should wake almost immediately.

After wake, your USB gadget/controller setup can take over.

---

## Capture your own Joy-Con 2 wake packet

Use Android with **nRF Connect**.

Do **not** pair the Joy-Con 2 to Android. Pairing is not needed and may interfere with the controller’s normal pairing to the Switch 2. Android is only used as a BLE scanner.

### Capture steps

1. Install **nRF Connect** on Android.
2. Open nRF Connect.
3. Start a BLE scan.
4. Put the phone close to the right Joy-Con 2.
5. Put the Switch 2 to sleep.
6. Press the HOME button on the right Joy-Con 2.
7. Look for a BLE device showing Nintendo manufacturer data.
8. Copy the device address and raw advertising payload.

The company ID should show as:

```text
0x0553
```

The raw advertising data should look like:

```text
0x0201061BFF5305...
```

Remove the leading `0x` before passing it to the script.

Example captured values:

```text
MAC:
98:E2:55:B1:28:5B

Raw advertising data:
0x0201061BFF53050100037E056620000181AB669B55E2980F00000000000000
```

Use them like this:

```bash
sudo ./ns2-ble-wake-v4-raw \
  --mac '98:E2:55:B1:28:5B' \
  --adv '0201061BFF53050100037E056620000181AB669B55E2980F00000000000000' \
  --seconds 1
```

---

## How to identify the right packet

A useful Joy-Con 2 wake advert usually has:

```text
Company ID: 0x0553
Raw bytes contain: FF 53 05
Payload length: usually 31 bytes
Strong RSSI if the phone is close to the Joy-Con
```

The packet often starts like this:

```text
02 01 06 1B FF 53 05 ...
```

Breakdown:

```text
02 01 06
```

BLE flags.

```text
1B FF
```

Manufacturer-specific data field.

```text
53 05
```

Nintendo company ID, little-endian for `0x0553`.

The remaining bytes are the controller/wake-specific data.

---

## Optional: capture with the Pi

Android with nRF Connect was easier, but the Pi can also capture BLE advertisements using `btmon`.

Start `btmon`:

```bash
sudo systemctl stop bluetooth || true
sudo btmgmt -i hci0 power off || true
sudo btmgmt -i hci0 privacy off
sudo btmgmt -i hci0 bredr off
sudo btmgmt -i hci0 le on
sudo btmgmt -i hci0 power on

sudo btmon | tee ~/joycon2-wake-btmon.txt
```

In another SSH session, start aggressive active scanning:

```bash
sudo hcitool -i hci0 cmd 0x08 0x000B 01 04 00 04 00 00 00
sudo hcitool -i hci0 cmd 0x08 0x000C 01 00
```

Then put the Switch 2 to sleep and press HOME on the Joy-Con 2.

Search the capture for Nintendo data:

```bash
grep -in -A20 -B10 -E 'Nintendo|53 05|0553|LE Advertising Report' ~/joycon2-wake-btmon.txt
```

---

## Troubleshooting

### `Invalid Index`, `Network is down`, or Bluetooth disappears

The script changes the Pi Bluetooth public address. Sometimes the Pi Bluetooth controller can briefly drop/re-enumerate.

Reset Bluetooth:

```bash
sudo systemctl stop bluetooth
sudo rfkill unblock bluetooth
sudo systemctl restart hciuart || true
sleep 3
sudo btmgmt info
```

If it still looks broken:

```bash
sudo reboot
```

### `hcitool not found`

Install BlueZ:

```bash
sudo apt update
sudo apt install -y bluez
```

### The phone sees a Nintendo advert but the Switch does not wake

Make sure the MAC and payload are from your own Joy-Con 2 while it is waking your own Switch 2.

Public sample payloads can look valid but still fail.

### The Switch 2 is fully powered off

This method wakes from normal sleep only. It does not power on a fully shut down console.

### Locale warning

You may see:

```text
setlocale: LC_ALL: cannot change locale
```

This is harmless. You can suppress it by running:

```bash
sudo env LC_ALL=C LANG=C ./ns2-ble-wake-v4-raw ...
```

---

## Notes

- Keep your captured MAC/payload private-ish. It is effectively your controller’s wake identity.
- The Pi Zero 2 W can handle the BLE wake side by itself; no ESP32 is required for this setup.
- Once the Switch 2 is awake, normal USB gadget control can continue through your existing controller software.

---

## Final known-good command

```bash
sudo ./ns2-ble-wake-v4-raw \
  --mac '98:E2:55:B1:28:5B' \
  --adv '0201061BFF53050100037E056620000181AB669B55E2980F00000000000000' \
  --seconds 1
```

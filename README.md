# Switch2-RPI-Wake
Use a RPI zero2 to wake a Switch 2 over BLE using captured Payload
Wake Nintendo Switch 2 from a Raspberry Pi Zero 2 W using a captured Joy-Con 2 BLE packet
This guide shows how to wake a docked Nintendo Switch 2 from a Raspberry Pi Zero 2 W by replaying the BLE wake advertisement from a real Joy-Con 2.
This is useful when using a Pi Zero 2 W for remote Switch 2 control with a USB gadget/controller setup such as NS-PC-Control. The Pi wakes the console over BLE, then the existing USB controller path can control it after wake.
Confirmed working command
This command woke the Switch 2:
sudo ./ns2-ble-wake-v4-raw \
  --mac '98:E2:55:B1:28:5B' \
  --adv '0201061BFF53050100037E056620000181AB669B55E2980F00000000000000' \
  --seconds 1
Captured Joy-Con 2 BLE MAC:
98:E2:55:B1:28:5B
Confirmed working advertising payload:
0201061BFF53050100037E056620000181AB669B55E2980F00000000000000
This payload contains Nintendo manufacturer data:
Company ID: 0x0553
Raw byte order in advert: 53 05
What is happening
A paired Joy-Con 2 wakes the Switch 2 by broadcasting a short BLE advertisement. The Pi Zero 2 W can imitate that by:
Stopping bluetoothd so it does not interfere.
Setting the Pi Bluetooth public address to the captured Joy-Con 2 MAC.
Configuring raw BLE advertising.
Broadcasting the captured Nintendo manufacturer advertisement for 1 second.
Stopping advertising.
The important parts are:
MAC address must match the captured Joy-Con 2 wake advert.
Advertising payload must match the captured Nintendo wake payload.
Advertising type is non-connectable.
Duration of 1 second is enough in testing.
Install dependencies
On Raspberry Pi OS Lite:
sudo apt update
sudo apt install -y bluez rfkill
Check the tools exist:
which btmgmt
which hcitool
which bluetoothctl
Check the Pi has a Bluetooth controller:
bluetoothctl show
sudo btmgmt info
If Bluetooth is blocked:
rfkill list
sudo rfkill unblock bluetooth
sudo systemctl restart bluetooth
Create the raw wake script
Create ns2-ble-wake-v4-raw:
cat > ./ns2-ble-wake-v4-raw <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export LANG=C

HCI_DEV="hci0"
SECONDS="1"
MAC="98:E2:55:B1:28:5B"
ADV="0201061BFF53050100037E056620000181AB669B55E2980F00000000000000"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mac) MAC="$2"; shift 2 ;;
    --adv) ADV="$2"; shift 2 ;;
    --seconds) SECONDS="$2"; shift 2 ;;
    --hci) HCI_DEV="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || {
  echo "Run with sudo"
  exit 1
}

MAC="$(echo "$MAC" | tr '[:upper:]' '[:lower:]')"
ADV="$(echo "$ADV" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"

command -v hcitool >/dev/null 2>&1 || {
  echo "hcitool not found. Install BlueZ: sudo apt install -y bluez"
  exit 1
}

command -v btmgmt >/dev/null 2>&1 || {
  echo "btmgmt not found. Install BlueZ: sudo apt install -y bluez"
  exit 1
}

if ! [[ "$MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
  echo "Bad MAC: $MAC" >&2
  exit 1
fi

if ! [[ "$ADV" =~ ^[0-9A-F]+$ ]] || [ $(( ${#ADV} % 2 )) -ne 0 ]; then
  echo "Bad ADV hex" >&2
  exit 1
fi

ADV_BYTES=$(( ${#ADV} / 2 ))

if [ "$ADV_BYTES" -gt 31 ]; then
  echo "ADV is ${ADV_BYTES} bytes, max is 31" >&2
  exit 1
fi

hex_to_args() {
  local h="$1"
  while [ -n "$h" ]; do
    echo "${h:0:2}"
    h="${h:2}"
  done
}

mapfile -t ADV_ARGS < <(hex_to_args "$ADV")

while [ "${#ADV_ARGS[@]}" -lt 31 ]; do
  ADV_ARGS+=("00")
done

LEN_ARG="$(printf "%02X" "$ADV_BYTES")"

cleanup() {
  hcitool -i "$HCI_DEV" cmd 0x08 0x000A 00 >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "[+] Stopping bluetoothd"
systemctl stop bluetooth || true

echo "[+] Preparing Bluetooth controller"
btmgmt -i "$HCI_DEV" power off >/dev/null 2>&1 || true
btmgmt -i "$HCI_DEV" privacy off
btmgmt -i "$HCI_DEV" bredr off
btmgmt -i "$HCI_DEV" le on
btmgmt -i "$HCI_DEV" public-addr "$MAC"
btmgmt -i "$HCI_DEV" power on

echo "[+] Controller info"
btmgmt -i "$HCI_DEV" info

echo "[+] Disable existing raw advertising"
hcitool -i "$HCI_DEV" cmd 0x08 0x000A 00 >/dev/null

echo "[+] Set advertising parameters"
# LE Set Advertising Parameters
#
# 20 00 = min interval 0x0020
# 40 00 = max interval 0x0040
# 03    = ADV_NONCONN_IND, non-connectable undirected advertising
# 00    = own address type: public
# 00    = direct address type
# 00..  = direct address
# 07    = advertise on channels 37, 38, 39
# 00    = allow any scanner
hcitool -i "$HCI_DEV" cmd 0x08 0x0006 \
  20 00 \
  40 00 \
  03 \
  00 \
  00 \
  00 00 00 00 00 00 \
  07 \
  00

echo "[+] Set advertising data (${ADV_BYTES} bytes)"
hcitool -i "$HCI_DEV" cmd 0x08 0x0008 "$LEN_ARG" "${ADV_ARGS[@]}"

echo "[+] Clear scan response data"
hcitool -i "$HCI_DEV" cmd 0x08 0x0009 \
  00 \
  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 \
  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00

echo "[+] Enable advertising as $MAC for ${SECONDS}s"
hcitool -i "$HCI_DEV" cmd 0x08 0x000A 01

sleep "$SECONDS"

echo "[+] Disable advertising"
cleanup

echo "[+] Done"
EOF

chmod +x ./ns2-ble-wake-v4-raw
Wake the Switch 2
Put the Switch 2 into normal sleep mode, not full power-off.
Then run:
sudo ./ns2-ble-wake-v4-raw \
  --mac '98:E2:55:B1:28:5B' \
  --adv '0201061BFF53050100037E056620000181AB669B55E2980F00000000000000' \
  --seconds 1
If it works, the Switch 2 should wake almost immediately.
Capture your own Joy-Con 2 wake packet with Android
Use Android with nRF Connect. Do not pair the Joy-Con 2 to Android. Pairing is not needed and may interfere with the controller’s normal pairing to the Switch 2.
Android capture steps
Install nRF Connect on Android.
Open the app.
Start a BLE scan.
Put the phone close to the right Joy-Con 2.
Put the Switch 2 to sleep.
Press the HOME button on the right Joy-Con 2.
Look for a BLE device showing Nintendo manufacturer data.
The company ID should show as:
0x0553
The raw advertising data should look like:
0x0201061BFF5305...
The important values to copy are:
Address / MAC
Raw advertising data
Company ID / manufacturer data
RSSI, optional
For example:
MAC:
98:E2:55:B1:28:5B

Raw advertising data:
0x0201061BFF53050100037E056620000181AB669B55E2980F00000000000000
Remove the leading 0x before using it in the script:
sudo ./ns2-ble-wake-v4-raw \
  --mac '98:E2:55:B1:28:5B' \
  --adv '0201061BFF53050100037E056620000181AB669B55E2980F00000000000000' \
  --seconds 1
How to spot the correct packet
A useful Joy-Con 2 wake advert has:
Company ID: 0x0553
Raw bytes contain: FF 53 05
Payload length: usually 31 bytes
RSSI: often strong if phone is close to Joy-Con
The first bytes usually look like:
02 01 06 1B FF 53 05 ...
Broken down:
02 01 06
BLE flags.
1B FF
Manufacturer-specific data field.
53 05
Nintendo company ID, little-endian for 0x0553.
The rest is the controller/wake-specific data.
Optional: capture with the Pi instead of Android
Android nRF Connect is easier, but the Pi can also scan with btmon.
Install tools:
sudo apt install -y bluez
Start a capture:
sudo systemctl stop bluetooth || true
sudo btmgmt -i hci0 power off || true
sudo btmgmt -i hci0 privacy off
sudo btmgmt -i hci0 bredr off
sudo btmgmt -i hci0 le on
sudo btmgmt -i hci0 power on

sudo btmon | tee ~/joycon2-wake-btmon.txt
In another SSH session, start scanning:
sudo hcitool -i hci0 cmd 0x08 0x000B 01 04 00 04 00 00 00
sudo hcitool -i hci0 cmd 0x08 0x000C 01 00
Then press HOME on the Joy-Con 2 while the Switch 2 is asleep.
After capture, search for Nintendo data:
grep -in -A20 -B10 -E 'Nintendo|53 05|0553|LE Advertising Report' ~/joycon2-wake-btmon.txt
Android was easier in this case because the wake packet was very brief and the phone captured repeated raw adverts cleanly.
Troubleshooting
Command works once, then Bluetooth acts strange
The script spoofs the Pi Bluetooth public address. If Bluetooth gets stuck, restart services:
sudo systemctl restart hciuart || true
sudo systemctl restart bluetooth || true
If still weird:
sudo reboot
The phone sees a valid Nintendo advert but the Switch does not wake
Make sure the MAC and raw advertising payload are from your own Joy-Con 2 while it is waking your own Switch 2.
Public sample payloads can look valid but not wake your console.
btmgmt public-addr fails or HCI disappears
Reboot and try again:
sudo reboot
Then re-run the raw wake command.
hcitool not found
Install BlueZ:
sudo apt update
sudo apt install -y bluez
The Switch is fully powered off
This method wakes from normal sleep. It does not power on a fully shut down console.
Final known-good command
sudo ./ns2-ble-wake-v4-raw \
  --mac '98:E2:55:B1:28:5B' \
  --adv '0201061BFF53050100037E056620000181AB669B55E2980F00000000000000' \
  --seconds 1

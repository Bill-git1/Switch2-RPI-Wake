#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export LANG=C

HCI_DEV="hci0"
SECONDS="1"
MAC="78:81:8c:05:0f:fa"
ADV="0201061BFF53050100037E0566200001810917158C81780F00000000000000"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mac) MAC="$2"; shift 2 ;;
    --adv) ADV="$2"; shift 2 ;;
    --seconds) SECONDS="$2"; shift 2 ;;
    --hci) HCI_DEV="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }

MAC="$(echo "$MAC" | tr '[:upper:]' '[:lower:]')"
ADV="$(echo "$ADV" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"

command -v hcitool >/dev/null 2>&1 || {
  echo "hcitool not found. Try: sudo apt install -y bluez"
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
  echo "ADV is ${ADV_BYTES} bytes, max 31" >&2
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

echo "[+] Preparing controller"
btmgmt -i "$HCI_DEV" power off >/dev/null 2>&1 || true
btmgmt -i "$HCI_DEV" privacy off
btmgmt -i "$HCI_DEV" bredr off
btmgmt -i "$HCI_DEV" le on
btmgmt -i "$HCI_DEV" public-addr "$MAC"
btmgmt -i "$HCI_DEV" power on

echo "[+] Controller info:"
btmgmt -i "$HCI_DEV" info

echo "[+] Disable existing raw advertising"
hcitool -i "$HCI_DEV" cmd 0x08 0x000A 00 >/dev/null

echo "[+] Set advertising parameters"
# LE Set Advertising Parameters:
# min interval 0x0020, max interval 0x0040
# adv type 0x03 = ADV_NONCONN_IND
# own addr type 0x00 = public address
# direct addr all zero
# channel map 0x07
# filter policy 0x00
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

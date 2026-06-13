#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export LANG=C

HCI_DEV="${HCI_DEV:-hci0}"
DURATION="1"

# Confirmed working Joy-Con 2 wake values
MAC="98:E2:55:B1:28:5B"
ADV="0201061BFF53050100037E056620000181AB669B55E2980F00000000000000"

usage() {
  cat <<USAGE
Usage:
  sudo env LC_ALL=C LANG=C ./ns2-ble-wake-v5 [options]

Options:
  --mac AA:BB:CC:DD:EE:FF     BLE/public MAC to advertise as
  --adv HEX                   Raw advertising payload
  --seconds N                 Advertise duration, default: 1
  --hci hci0                  HCI device hint, default: hci0
  --help

Default MAC:
  $MAC

Default ADV:
  $ADV
USAGE
}

log() {
  echo "[+] $*"
}

warn() {
  echo "[!] $*" >&2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

find_hci() {
  btmgmt info 2>/dev/null | awk '/^hci[0-9]+:/{gsub(":","",$1); print $1; exit}'
}

wait_for_hci() {
  local i dev
  for i in $(seq 1 30); do
    dev="$(find_hci || true)"
    if [ -n "$dev" ]; then
      HCI_DEV="$dev"
      return 0
    fi
    sleep 0.5
  done
  return 1
}

reset_bt_stack() {
  warn "Resetting Bluetooth stack / hciuart"

  systemctl stop bluetooth >/dev/null 2>&1 || true
  rfkill unblock bluetooth >/dev/null 2>&1 || true

  # Stop any stale LE advertising if the device is still reachable.
  hcitool -i "$HCI_DEV" cmd 0x08 0x000A 00 >/dev/null 2>&1 || true

  systemctl restart hciuart >/dev/null 2>&1 || true
  sleep 3

  wait_for_hci
}

mgmt_cmd() {
  local out rc
  echo "+ btmgmt -i $HCI_DEV $*" >&2

  set +e
  out="$(btmgmt -i "$HCI_DEV" "$@" 2>&1)"
  rc=$?
  set -e

  [ -n "$out" ] && echo "$out"

  return "$rc"
}

hci_cmd() {
  local out rc
  echo "+ hcitool -i $HCI_DEV cmd $*" >&2

  set +e
  out="$(hcitool -i "$HCI_DEV" cmd "$@" 2>&1)"
  rc=$?
  set -e

  [ -n "$out" ] && echo "$out"

  return "$rc"
}

hex_to_args() {
  local h="$1"
  while [ -n "$h" ]; do
    echo "${h:0:2}"
    h="${h:2}"
  done
}

cleanup() {
  hcitool -i "$HCI_DEV" cmd 0x08 0x000A 00 >/dev/null 2>&1 || true
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mac) MAC="$2"; shift 2 ;;
    --adv) ADV="$2"; shift 2 ;;
    --seconds) DURATION="$2"; shift 2 ;;
    --hci) HCI_DEV="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "Run with sudo/root"

need_cmd btmgmt
need_cmd hcitool
need_cmd rfkill
need_cmd systemctl
need_cmd awk

MAC="$(echo "$MAC" | tr '[:upper:]' '[:lower:]')"
ADV="$(echo "$ADV" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"

[[ "$MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || die "Bad MAC: $MAC"
[[ "$ADV" =~ ^[0-9A-F]+$ ]] || die "Bad ADV hex"
[ $(( ${#ADV} % 2 )) -eq 0 ] || die "ADV hex must have even length"

ADV_BYTES=$(( ${#ADV} / 2 ))
[ "$ADV_BYTES" -le 31 ] || die "ADV is ${ADV_BYTES} bytes, max is 31"

mapfile -t ADV_ARGS < <(hex_to_args "$ADV")
while [ "${#ADV_ARGS[@]}" -lt 31 ]; do
  ADV_ARGS+=("00")
done
LEN_ARG="$(printf "%02X" "$ADV_BYTES")"

prepare_controller() {
  local attempt info current_addr wanted_addr

  wanted_addr="$(echo "$MAC" | tr '[:lower:]' '[:upper:]')"

  systemctl stop bluetooth >/dev/null 2>&1 || true
  rfkill unblock bluetooth >/dev/null 2>&1 || true

  if ! wait_for_hci; then
    reset_bt_stack || return 1
  fi

  for attempt in 1 2 3; do
    log "Preparing Bluetooth controller, attempt $attempt, device $HCI_DEV"

    mgmt_cmd power off >/dev/null 2>&1 || true

    if ! mgmt_cmd privacy off; then
      reset_bt_stack || true
      continue
    fi

    if ! mgmt_cmd bredr off; then
      reset_bt_stack || true
      continue
    fi

    if ! mgmt_cmd le on; then
      reset_bt_stack || true
      continue
    fi

    if ! mgmt_cmd public-addr "$MAC"; then
      reset_bt_stack || true
      continue
    fi

    # public-addr can make hci0 briefly disappear/reindex.
    if ! wait_for_hci; then
      reset_bt_stack || true
      continue
    fi

    if ! mgmt_cmd power on; then
      reset_bt_stack || true
      continue
    fi

    sleep 0.5

    set +e
    info="$(btmgmt -i "$HCI_DEV" info 2>&1)"
    rc=$?
    set -e

    if [ "$rc" -ne 0 ]; then
      echo "$info"
      reset_bt_stack || true
      continue
    fi

    echo "$info"

    current_addr="$(echo "$info" | awk '/addr /{print toupper($2); exit}')"

    if [ "$current_addr" = "$wanted_addr" ]; then
      log "Controller address is correct: $current_addr"
      return 0
    fi

    warn "Controller address is $current_addr, expected $wanted_addr"
    reset_bt_stack || true
  done

  return 1
}

start_raw_advertising() {
  log "Disable existing raw advertising"
  hci_cmd 0x08 0x000A 00 >/dev/null || return 1

  log "Set advertising parameters"
  # LE Set Advertising Parameters:
  # 20 00 = min interval 0x0020
  # 40 00 = max interval 0x0040
  # 03    = ADV_NONCONN_IND
  # 00    = own address type: public
  # 00    = direct address type
  # 00..  = direct address
  # 07    = channels 37, 38, 39
  # 00    = allow any scanner
  hci_cmd 0x08 0x0006 \
    20 00 \
    40 00 \
    03 \
    00 \
    00 \
    00 00 00 00 00 00 \
    07 \
    00 || return 1

  log "Set advertising data (${ADV_BYTES} bytes)"
  hci_cmd 0x08 0x0008 "$LEN_ARG" "${ADV_ARGS[@]}" || return 1

  log "Clear scan response data"
  hci_cmd 0x08 0x0009 \
    00 \
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 \
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 || return 1

  log "Enable advertising as $MAC for ${DURATION}s"
  hci_cmd 0x08 0x000A 01 || return 1

  sleep "$DURATION"

  log "Disable advertising"
  cleanup

  return 0
}

log "Wake MAC: $MAC"
log "ADV bytes: $ADV_BYTES"
log "Duration: ${DURATION}s"

if ! prepare_controller; then
  die "Could not prepare Bluetooth controller. Try: sudo systemctl restart hciuart || sudo reboot"
fi

if ! start_raw_advertising; then
  warn "Raw advertising failed. Trying one Bluetooth stack reset, then retrying once."

  reset_bt_stack || die "Bluetooth reset failed"

  if ! prepare_controller; then
    die "Could not prepare Bluetooth controller after reset"
  fi

  start_raw_advertising || die "Raw advertising failed after retry"
fi

log "Done"
#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin"
export BATTERY_CALL_LOG="$tmp_dir/calls"
export BATTERY_STATE="$tmp_dir/enabled"
printf 'true\n' >"$BATTERY_STATE"

# A wireless mouse enumerates first, as a battery_ device that is not a power
# supply; the machine's own battery follows it.
cat >"$tmp_dir/bin/upower" <<'STUB'
#!/bin/bash

if [[ $1 == "-e" ]]; then
  echo "/org/freedesktop/UPower/devices/line_power_AC"
  [[ -n ${OMARCHY_TEST_NO_BATTERY:-} ]] && exit 0
  echo "/org/freedesktop/UPower/devices/battery_hidpp_battery_0"
  echo "/org/freedesktop/UPower/devices/battery_CMB0"
  exit 0
fi

if [[ $1 == "-i" && $2 == */battery_hidpp_battery_0 ]]; then
  echo "  power supply:         no"
  exit 0
fi

if [[ $1 == "-i" ]]; then
  echo "  power supply:         yes"
  exit 0
fi

exit 1
STUB

cat >"$tmp_dir/bin/busctl" <<'STUB'
#!/bin/bash

if [[ $1 == "get-property" ]]; then
  [[ $3 == */battery_CMB0 ]] || { echo "Unknown object '$3'." >&2; exit 1; }
  case "$5" in
    ChargeThresholdSupported) echo "b ${OMARCHY_TEST_SUPPORTED:-true}" ;;
    ChargeThresholdEnabled) echo "b $(<"$BATTERY_STATE")" ;;
    ChargeEndThreshold) echo "u 80" ;;
  esac
  exit 0
fi

if [[ $1 == "call" && $5 == "EnableChargeThreshold" ]]; then
  [[ -z ${OMARCHY_TEST_CALL_FAILS:-} ]] || { echo "Call failed: Not authorized" >&2; exit 1; }
  printf '%s\t%s\n' "$3" "$7" >>"$BATTERY_CALL_LOG"
  printf '%s\n' "$7" >"$BATTERY_STATE"
  exit 0
fi

exit 1
STUB
chmod +x "$tmp_dir/bin/upower" "$tmp_dir/bin/busctl"
export PATH="$tmp_dir/bin:$PATH"

status=$("$ROOT/bin/omarchy-battery-charge-limit")
[[ $status == $'limit\ton\nend\t80' ]] || fail "charge limit reports the state and end of the machine's battery, not the mouse's" "$status"
pass "charge limit reports the state and end threshold"

status=$("$ROOT/bin/omarchy-battery-charge-limit" off)
grep -Fx $'/org/freedesktop/UPower/devices/battery_CMB0\tfalse' "$BATTERY_CALL_LOG" >/dev/null || fail "charge limit off turns the threshold off through UPower" "$(<"$BATTERY_CALL_LOG")"
[[ $status == $'limit\toff\nend\t80' ]] || fail "charge limit off prints the new state" "$status"

"$ROOT/bin/omarchy-battery-charge-limit" on >/dev/null
grep -Fx $'/org/freedesktop/UPower/devices/battery_CMB0\ttrue' "$BATTERY_CALL_LOG" >/dev/null || fail "charge limit on turns the threshold on through UPower"
pass "charge limit turns the threshold on and off"

status=$(OMARCHY_TEST_SUPPORTED=false "$ROOT/bin/omarchy-battery-charge-limit")
[[ -z $status ]] || fail "a battery without a charge limit prints nothing" "$status"
status=$(OMARCHY_TEST_NO_BATTERY=1 "$ROOT/bin/omarchy-battery-charge-limit")
[[ -z $status ]] || fail "a machine without a battery prints nothing" "$status"
pass "charge limit prints nothing without a battery that supports it"

if OMARCHY_TEST_CALL_FAILS=1 "$ROOT/bin/omarchy-battery-charge-limit" off >/dev/null 2>"$tmp_dir/error"; then
  fail "a refused UPower call fails the command"
fi
grep -F "Not authorized" "$tmp_dir/error" >/dev/null || fail "a refused UPower call keeps its error" "$(<"$tmp_dir/error")"
pass "charge limit fails loudly when UPower refuses the change"

if "$ROOT/bin/omarchy-battery-charge-limit" half >/dev/null 2>&1; then
  fail "charge limit rejects an unknown argument"
fi
pass "charge limit rejects an unknown argument"

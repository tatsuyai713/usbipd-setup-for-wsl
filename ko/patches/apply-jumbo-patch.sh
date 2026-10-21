#!/bin/bash
# apply-jumbo-patch.sh <path/to/drivers/net/usb/ax88179_178a.c>
#
# Why: ax88179_bind() sets net->max_mtu = 4088, but usbnet_probe() then clamps max_mtu to
# hard_mtu (1500) unless the driver_info carries FLAG_NOMAXMTU. Adding the flag lets
# `ip link set dev enx... mtu 4000` succeed. A modinfo marker "jumbo_patch" is added so the
# build can be recognised later (modinfo -F jumbo_patch ax88179_178a.ko).
set -euo pipefail
f="${1:?usage: $0 path/to/ax88179_178a.c}"
[ -f "$f" ] || { echo "no such file: $f" >&2; exit 1; }

if grep -q 'FLAG_NOMAXMTU' "$f"; then
  echo "  FLAG_NOMAXMTU already present in $f"
else
  sed -E -i 's/^([[:space:]]*\.flags[[:space:]]*=[[:space:]]*FLAG_ETHER[[:space:]]*\|[[:space:]]*FLAG_FRAMING_AX),/\1 | FLAG_NOMAXMTU,/' "$f"
  n="$(grep -c 'FLAG_FRAMING_AX | FLAG_NOMAXMTU' "$f" || true)"
  if [ "$n" -eq 0 ]; then
    echo "ERROR: no '.flags = FLAG_ETHER | FLAG_FRAMING_AX,' line found in $f - driver source changed, update this script" >&2
    exit 1
  fi
  echo "  FLAG_NOMAXMTU added to $n driver_info definition(s)"
fi

if ! grep -q 'MODULE_INFO(jumbo_patch' "$f"; then
  printf '\nMODULE_INFO(jumbo_patch, "FLAG_NOMAXMTU");\n' >> "$f"
  echo "  modinfo marker jumbo_patch added"
fi

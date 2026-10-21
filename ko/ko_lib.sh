#!/bin/bash
# ko_lib.sh - per-kernel management of the jumbo-frame patched ax88179_178a.ko
#
# Layout:   ko/<kernel release as printed by `uname -r`>/ax88179_178a.ko  (+ BUILD_INFO.txt, jumbo.patch)
#
# Standalone usage:
#   ko/ko_lib.sh status              list stored modules, show which one applies to the running kernel
#   ko/ko_lib.sh check <file.ko>     compare a module's symbol CRCs with the running kernel
#   ko/ko_lib.sh apply               install ko/$(uname -r)/ax88179_178a.ko (needs root or sudo)
#   ko/ko_lib.sh restore             put the stock WSL module back (needs root or sudo)
# Sourced (setup_interface_for_wsl.sh, build_ko.sh):
#   . ko/ko_lib.sh && ko_apply
#
# Environment overrides: KO_ROOT (module store), KO_PRISTINE_ROOT (backup of stock modules)

KO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KO_ROOT="${KO_ROOT:-$KO_LIB_DIR}"
KO_NAME="ax88179_178a"
KO_PRISTINE_ROOT="${KO_PRISTINE_ROOT:-/var/lib/usbipd-setup-wsl/pristine}"
KO_SUDO=""
[ "$(id -u)" = 0 ] || KO_SUDO="sudo"

ko_target_path()    { echo "/lib/modules/$1/kernel/drivers/net/usb/$KO_NAME.ko"; }
ko_candidate_path() { echo "$KO_ROOT/$1/$KO_NAME.ko"; }
ko_pristine_path()  { echo "$KO_PRISTINE_ROOT/$1/$KO_NAME.ko"; }

# Kernel release a module was built for (first word of its vermagic).
ko_release_of() { modinfo -F vermagic "$1" 2>/dev/null | awk '{print $1}'; }

# True if the module carries the modinfo marker added by ko/patches/apply-jumbo-patch.sh.
ko_is_patched() { [ -n "$(modinfo -F jumbo_patch "$1" 2>/dev/null)" ]; }

# "<symbol> <0xcrc>" for every versioned import of a module.
ko_dump_versions() { modprobe --dump-modversions "$1" 2>/dev/null | awk '{printf "%s %s\n", $2, tolower($1)}'; }

# CRC table kernel KVER expects, learned from the modules it ships (the kernel checks exactly these).
# The ax88179_178a.ko installed in that kernel is skipped because it may already be one of ours;
# a pristine backup, if present, is used instead.
ko_reference_crcs() {
  local kver="$1" target pristine
  target="$(ko_target_path "$kver")"
  pristine="$(ko_pristine_path "$kver")"
  {
    if [ -r "$pristine" ]; then ko_dump_versions "$pristine"; fi
    find "/lib/modules/$kver/kernel/drivers/net" "/lib/modules/$kver/kernel/drivers/usb" \
         "/lib/modules/$kver/kernel/net" -name '*.ko' ! -path "$target" -print0 2>/dev/null |
      while IFS= read -r -d '' f; do ko_dump_versions "$f" || true; done
  } | LC_ALL=C sort -u
}

# ko_compare_crcs CANDIDATE_TABLE REFERENCE_TABLE   (files with "<symbol> <0xcrc>" lines)
# Prints a report. Return: 0 all comparable CRCs match, 1 at least one mismatch, 2 nothing comparable.
ko_compare_crcs() {
  local cand ref joined match mismatch unknown
  cand="$(mktemp)"; ref="$(mktemp)"
  LC_ALL=C sort -u -k1,1 "$1" > "$cand"
  LC_ALL=C sort -u -k1,1 "$2" > "$ref"
  joined="$(LC_ALL=C join "$cand" "$ref")"
  match="$(awk '$2==$3' <<<"$joined" | grep -c . || true)"
  mismatch="$(awk '$2!=$3' <<<"$joined" | grep -c . || true)"
  unknown="$(LC_ALL=C join -v1 "$cand" "$ref" | grep -c . || true)"
  awk '$2!=$3 {printf "  MISMATCH %-32s module=%s kernel=%s\n", $1, $2, $3}' <<<"$joined"
  LC_ALL=C join -v1 "$cand" "$ref" | awk '{printf "  (not verifiable) %s\n", $1}'
  echo "  CRC check: $match match, $mismatch mismatch, $unknown not verifiable"
  rm -f "$cand" "$ref"
  [ "$mismatch" -eq 0 ] || return 1
  [ "$match" -gt 0 ] || return 2
  return 0
}

# ko_check FILE.ko [KVER]  -> 0 compatible, 1 incompatible, 2 cannot judge
ko_check() {
  local ko="$1" kver="${2:-$(uname -r)}" c r rc=0 patched="no"
  [ -r "$ko" ] || { echo "  cannot read $ko"; return 2; }
  ko_is_patched "$ko" && patched="yes"
  echo "  module : $ko"
  echo "  built for $(ko_release_of "$ko")  (jumbo patch marker: $patched)"
  echo "  kernel : $kver"
  c="$(mktemp)"; r="$(mktemp)"
  ko_dump_versions "$ko" > "$c"
  ko_reference_crcs "$kver" > "$r"
  if [ ! -s "$r" ]; then
    echo "  no reference modules found under /lib/modules/$kver"
    rm -f "$c" "$r"; return 2
  fi
  ko_compare_crcs "$c" "$r" || rc=$?
  rm -f "$c" "$r"
  case $rc in
    0) echo "  => compatible with kernel $kver" ;;
    1) echo "  => NOT compatible (the kernel would reject it: 'disagrees about version of symbol ...')" ;;
    *) echo "  => cannot judge" ;;
  esac
  return $rc
}

ko_matches_store() {
  local f
  for f in "$KO_ROOT"/*/"$KO_NAME.ko"; do
    [ -f "$f" ] && cmp -s "$f" "$1" && return 0
  done
  return 1
}

ko_status() {
  local kver cand target pristine d name rel found=0 iface mark note
  kver="$(uname -r)"
  cand="$(ko_candidate_path "$kver")"
  target="$(ko_target_path "$kver")"
  pristine="$(ko_pristine_path "$kver")"
  echo "Running kernel : $kver"
  echo "Module store   : $KO_ROOT"
  for d in "$KO_ROOT"/*/; do
    [ -f "$d$KO_NAME.ko" ] || continue
    found=1
    name="$(basename "$d")"
    rel="$(ko_release_of "$d$KO_NAME.ko")"
    mark=" "; [ "$name" = "$kver" ] && mark="*"
    note=""; [ "$rel" = "$name" ] || note="  (!) folder name differs from vermagic"
    printf "  %s %-45s vermagic=%s%s\n" "$mark" "$name" "$rel" "$note"
  done
  [ $found = 1 ] || echo "  (no modules stored)"
  if [ -f "$cand" ]; then
    if [ -f "$target" ] && cmp -s "$cand" "$target"; then
      echo "For this kernel: INSTALLED  ($cand)"
    else
      echo "For this kernel: available, not installed  ($cand)"
    fi
  else
    echo "For this kernel: none stored -> build it with: $(dirname "$KO_ROOT")/build_ko.sh"
  fi
  if [ -f "$target" ]; then
    note="no"; ko_is_patched "$target" && note="yes"
    mark="no"; [ -f "$pristine" ] && mark="yes"
    echo "Installed file : $target (jumbo patch marker: $note; stock backup: $mark)"
  fi
  for iface in /sys/class/net/enx*; do
    [ -e "$iface" ] || continue
    iface="$(basename "$iface")"
    echo "Interface $iface: mtu=$(cat "/sys/class/net/$iface/mtu") $(ip -d link show "$iface" 2>/dev/null | grep -o 'maxmtu [0-9]*')  (maxmtu 4088 = jumbo build active)"
  done
}

# Unbind devices, remove and re-insert the module so the installed file takes effect.
ko_reload() {
  local dev
  if [ -d "/sys/bus/usb/drivers/$KO_NAME" ]; then
    for dev in "/sys/bus/usb/drivers/$KO_NAME"/*:*; do
      [ -e "$dev" ] || continue
      echo "  unbinding $(basename "$dev")"
      basename "$dev" | $KO_SUDO tee "/sys/bus/usb/drivers/$KO_NAME/unbind" >/dev/null || true
    done
  fi
  if lsmod | grep -q "^$KO_NAME "; then
    $KO_SUDO rmmod "$KO_NAME" || { echo "  rmmod $KO_NAME failed"; return 1; }
  fi
  $KO_SUDO modprobe "$KO_NAME" || { echo "  modprobe $KO_NAME failed"; return 1; }
  echo "  driver reloaded"
}

# Install the stored module matching the running kernel. Never installs an incompatible one.
ko_apply() {
  local kver="${1:-$(uname -r)}" cand target pristine avail rc=0
  cand="$(ko_candidate_path "$kver")"
  target="$(ko_target_path "$kver")"
  pristine="$(ko_pristine_path "$kver")"
  echo "== jumbo-frame $KO_NAME.ko for kernel $kver =="
  if [ ! -f "$cand" ]; then
    avail="$(cd "$KO_ROOT" 2>/dev/null && ls -- */"$KO_NAME.ko" 2>/dev/null | xargs -r -n1 dirname | tr '\n' ' ')"
    echo "  No module stored for this kernel in $KO_ROOT"
    echo "  Stored versions: ${avail:-none}"
    echo "  Build one inside WSL as your normal user:  $(dirname "$KO_ROOT")/build_ko.sh"
    echo "  Continuing with the stock driver (MTU limited to 1500)."
    return 0
  fi
  if [ -f "$target" ] && cmp -s "$cand" "$target"; then
    echo "  Already installed: $target"
    lsmod | grep -q "^$KO_NAME " || $KO_SUDO modprobe "$KO_NAME" 2>/dev/null || true
    return 0
  fi
  echo "  Verifying symbol CRCs against the running kernel ..."
  ko_check "$cand" "$kver" || rc=$?
  if [ $rc -ne 0 ]; then
    echo "  ERROR: refusing to install an incompatible module. Rebuild it with build_ko.sh"
    return 1
  fi
  if [ -f "$target" ] && [ ! -f "$pristine" ]; then
    if ko_is_patched "$target" || ko_matches_store "$target"; then
      echo "  (installed module is already a custom build; no stock backup taken)"
    else
      $KO_SUDO mkdir -p "$(dirname "$pristine")"
      $KO_SUDO cp "$target" "$pristine" && echo "  Stock module backed up to $pristine"
    fi
  fi
  echo "  Installing -> $target"
  $KO_SUDO mkdir -p "$(dirname "$target")"
  $KO_SUDO cp "$cand" "$target" || { echo "  copy failed"; return 1; }
  $KO_SUDO chmod 644 "$target"
  $KO_SUDO depmod -a "$kver"
  ko_reload || return 1
  echo "  Done."
}

# Put the stock module back from the backup taken by ko_apply.
ko_restore() {
  local kver="${1:-$(uname -r)}" target pristine
  target="$(ko_target_path "$kver")"
  pristine="$(ko_pristine_path "$kver")"
  [ -f "$pristine" ] || { echo "No stock backup at $pristine"; return 1; }
  $KO_SUDO cp "$pristine" "$target"
  $KO_SUDO depmod -a "$kver"
  ko_reload || return 1
  echo "Stock module restored for $kver."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-status}" in
    status)  ko_status ;;
    check)   [ -n "${2:-}" ] || { echo "usage: $0 check <file.ko> [kernel-release]"; exit 2; }
             ko_check "$2" "${3:-$(uname -r)}" ;;
    apply)   ko_apply ;;
    restore) ko_restore ;;
    *) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
fi

#!/bin/bash
# build_ko.sh - build the jumbo-frame patched ax88179_178a.ko for the running WSL2 kernel
#               and store it as ko/<kernel release>/ax88179_178a.ko for setup_interface_for_wsl.sh.
#
# Run inside WSL as your normal user (not root):   ./build_ko.sh
#
# Steps
#   1. find the microsoft/WSL2-Linux-Kernel tag matching `uname -r` (fetches it if needed)
#   2. check it out into its own git worktree (an existing checkout is left untouched)
#   3. use the running kernel's configuration (/proc/config.gz)
#   4. apply ko/patches/apply-jumbo-patch.sh (FLAG_NOMAXMTU)
#   5. build drivers/net/usb as modules (modules_prepare + M=drivers/net/usb)
#   6. compute the CRC of every imported symbol from source (genksyms) and verify it against
#      the CRCs the running kernel's own modules carry; refuse to continue on a mismatch
#   7. strip debug info and save ko/<release>/{ax88179_178a.ko,BUILD_INFO.txt,jumbo.patch}
#
# Options
#   --ref TAG        build this git tag/commit instead of the one matching uname -r
#   --config FILE    use this kernel config (.config or config.gz) instead of /proc/config.gz
#   --no-fetch       never touch the network (fail if the tag is not available locally)
#   --out DIR        store the result under DIR/<release>/ instead of ko/
#   --src DIR        kernel git checkout to use/create (default: $HOME/src/WSL2-Linux-Kernel, env KSRC)
#   --build-dir DIR  where worktrees are created (default: $HOME/src/wsl-ko-build, env KO_BUILD_DIR)
#   -j N             parallel jobs (default: nproc)
#   --install        run `ko_lib.sh apply` afterwards (asks for sudo)
#   --clean          remove the build worktree when done
#   --force          save the module even if CRC verification fails (unsafe, for experiments)
#   --allow-root     allow running as root
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ko/ko_lib.sh
. "$SCRIPT_DIR/ko/ko_lib.sh"

REPO_URL="${KSRC_URL:-https://github.com/microsoft/WSL2-Linux-Kernel.git}"
KSRC="${KSRC:-$HOME/src/WSL2-Linux-Kernel}"
KO_BUILD_DIR="${KO_BUILD_DIR:-$HOME/src/wsl-ko-build}"
PATCH_SCRIPT="$SCRIPT_DIR/ko/patches/apply-jumbo-patch.sh"
MODDIR="drivers/net/usb"

REF=""; FETCH=1; CONFIG_FILE=""; OUT_ROOT="$KO_ROOT"; JOBS="$(nproc)"
FORCE=0; CLEAN=0; INSTALL=0; ALLOW_ROOT=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
log()   { echo "[build_ko] $*"; }
die()   { echo "[build_ko] ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)        REF="$2"; shift 2 ;;
    --config)     CONFIG_FILE="$2"; shift 2 ;;
    --no-fetch)   FETCH=0; shift ;;
    --out)        OUT_ROOT="$2"; shift 2 ;;
    --src)        KSRC="$2"; shift 2 ;;
    --build-dir)  KO_BUILD_DIR="$2"; shift 2 ;;
    -j|--jobs)    JOBS="$2"; shift 2 ;;
    --install)    INSTALL=1; shift ;;
    --clean)      CLEAN=1; shift ;;
    --force)      FORCE=1; shift ;;
    --allow-root) ALLOW_ROOT=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [ "$(id -u)" = 0 ] && [ $ALLOW_ROOT = 0 ]; then
  die "do not run as root (the source tree would become root-owned). Run as your normal WSL user, or pass --allow-root."
fi

RUNNING="$(uname -r)"              # e.g. 6.18.40.1-microsoft-standard-WSL2
RUN_VER="${RUNNING%%-*}"           # e.g. 6.18.40.1
log "running kernel: $RUNNING"

# ---------------------------------------------------------------- 1. build tools
missing=""
for t in git make gcc flex bison bc; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
dpkg -s libssl-dev >/dev/null 2>&1 || missing="$missing libssl-dev"
dpkg -s libelf-dev >/dev/null 2>&1 || missing="$missing libelf-dev"
if [ -n "$missing" ]; then
  log "installing build dependencies (missing:$missing)"
  sudo apt-get update
  sudo apt-get install -y build-essential flex bison bc libssl-dev libelf-dev git kmod dwarves
fi

# ---------------------------------------------------------------- 2. kernel source
if [ -n "$REF" ]; then
  candidates=("$REF")
else
  candidates=("linux-msft-wsl-$RUN_VER" "rolling-lts/wsl/$RUN_VER")
fi

resolve()   { git -C "$KSRC" rev-parse -q --verify "$1^{commit}" 2>/dev/null; }
fetch_tag() {
  local depth=()
  [ "$(git -C "$KSRC" rev-parse --is-shallow-repository 2>/dev/null)" = true ] && depth=(--depth 1)
  git -C "$KSRC" fetch "${depth[@]}" --no-tags origin "refs/tags/$1:refs/tags/$1"
}

if [ ! -d "$KSRC/.git" ]; then
  [ $FETCH = 1 ] || die "no kernel source at $KSRC and --no-fetch given"
  log "cloning $REPO_URL into $KSRC (shallow) ..."
  cloned=""
  for r in "${candidates[@]}"; do
    if git clone --depth 1 --branch "$r" "$REPO_URL" "$KSRC"; then cloned="$r"; break; fi
    rm -rf "$KSRC"
  done
  [ -n "$cloned" ] || die "could not clone any of: ${candidates[*]}"
fi

COMMIT=""
for r in "${candidates[@]}"; do
  if COMMIT="$(resolve "$r")" && [ -n "$COMMIT" ]; then REF="$r"; break; fi
  if [ $FETCH = 1 ]; then
    log "fetching tag $r ..."
    if fetch_tag "$r" && COMMIT="$(resolve "$r")" && [ -n "$COMMIT" ]; then REF="$r"; break; fi
  fi
done
[ -n "$COMMIT" ] || die "no source found for kernel $RUN_VER (tried: ${candidates[*]}). Check network, or pass --ref <tag>."
log "source: $REF ($COMMIT)"

# ---------------------------------------------------------------- 3. worktree
WT="$KO_BUILD_DIR/$(echo "$REF" | tr '/' '_')"
mkdir -p "$KO_BUILD_DIR"
git -C "$KSRC" worktree prune
if [ -e "$WT/.git" ]; then
  [ "$(git -C "$WT" rev-parse HEAD)" = "$COMMIT" ] || die "$WT exists but is at another commit. Remove it: git -C $KSRC worktree remove --force $WT"
  git -C "$WT" checkout -- "$MODDIR/ax88179_178a.c"
  log "reusing worktree $WT"
else
  log "creating worktree $WT"
  git -C "$KSRC" worktree add --detach "$WT" "$COMMIT"
fi
# LOCALVERSION= keeps setlocalversion from appending '+' (tree not on an annotated tag)
mk() { make -C "$WT" --no-print-directory LOCALVERSION= "$@"; }

SRC_VER="$(mk -s kernelversion)"
TARGET_IS_RUNNING=0
[ "$SRC_VER" = "$RUN_VER" ] && TARGET_IS_RUNNING=1

# ---------------------------------------------------------------- 4. config
if [ -n "$CONFIG_FILE" ]; then
  CONFIG_SRC="$CONFIG_FILE"
elif [ $TARGET_IS_RUNNING = 1 ] && [ -r /proc/config.gz ]; then
  CONFIG_SRC="/proc/config.gz"
else
  CONFIG_SRC="$WT/Microsoft/config-wsl"
  log "WARNING: source is $SRC_VER but the running kernel is $RUN_VER; using $CONFIG_SRC."
  log "         The shipped WSL kernel may use a different config, so CRCs may not match that kernel."
fi
log "config: $CONFIG_SRC"
case "$CONFIG_SRC" in
  *.gz) zcat "$CONFIG_SRC" > "$WT/.config" ;;
  *)    cp "$CONFIG_SRC" "$WT/.config" ;;
esac
cp "$WT/.config" "$WT/.config.source"
mk -s olddefconfig
changed="$("$WT/scripts/diffconfig" "$WT/.config.source" "$WT/.config" |
  grep -vE '^[-+ ]?(CC_VERSION_TEXT|GCC_VERSION|CC_IS_|CLANG_VERSION|AS_IS_|AS_VERSION|LD_IS_|LD_VERSION|LLD_VERSION|PAHOLE_VERSION|RUSTC_VERSION|BINDGEN_VERSION|RUST_IS_)' || true)"
if [ -n "$changed" ]; then
  log "olddefconfig changed these options relative to the source config:"
  echo "$changed" | sed 's/^/    /'
fi
grep -q '^CONFIG_MODVERSIONS=y' "$WT/.config"           || die "CONFIG_MODVERSIONS is off in this config; CRC verification is impossible"
grep -q '^CONFIG_USB_NET_AX88179_178A=m' "$WT/.config"  || die "CONFIG_USB_NET_AX88179_178A is not =m in this config"

REL="$(mk -s kernelrelease)"
log "kernel release of this build: $REL"
if [ $TARGET_IS_RUNNING = 1 ] && [ "$REL" != "$RUNNING" ]; then
  die "release '$REL' differs from the running '$RUNNING' (CONFIG_LOCALVERSION?)"
fi

# ---------------------------------------------------------------- 5. patch
log "applying jumbo-frame patch"
"$PATCH_SCRIPT" "$WT/$MODDIR/ax88179_178a.c"
git -C "$WT" diff -- "$MODDIR/ax88179_178a.c" > "$WT/jumbo.patch"

# ---------------------------------------------------------------- 6. build
log "modules_prepare (-j$JOBS) ... log: $WT/build-prepare.log"
mk -j"$JOBS" modules_prepare >"$WT/build-prepare.log" 2>&1 || { tail -30 "$WT/build-prepare.log"; die "modules_prepare failed"; }

# Pass 1 only has to produce the objects (no Module.symvers yet, so modpost cannot resolve
# symbols; KBUILD_MODPOST_WARN=1 turns those errors into warnings). Other modules in the
# directory (lan78xx, qmi_wwan, ...) are built as a side effect and are not used.
log "building $MODDIR modules (pass 1, objects only) ... log: $WT/build-pass1.log"
rm -f "$WT/$MODDIR"/*.ko "$WT/$MODDIR/Module.symvers" "$WT/Module.symvers"
mk -j"$JOBS" M="$MODDIR" KBUILD_MODPOST_WARN=1 modules >"$WT/build-pass1.log" 2>&1 || { tail -40 "$WT/build-pass1.log"; die "module build failed"; }
OBJ="$WT/$MODDIR/ax88179_178a.o"
[ -f "$OBJ" ] || die "$OBJ was not produced"

# ---------------------------------------------------------------- 7. symbol CRCs
# Imported symbols of our module (modpost always adds module_layout as well).
{ nm -u "$OBJ" | awk '{print $NF}'; echo module_layout; } | sort -u > "$WT/imports.txt"
log "$(wc -l < "$WT/imports.txt") imported symbols; locating the source files that export them ..."

exporters=()
while read -r sym; do
  files="$(git -C "$WT" grep -lE "(EXPORT_SYMBOL[A-Z_]*|define_netdev_printk_level)\(\s*$sym\s*[,)]" -- \
            '*.c' '*.S' ':!tools/' ':!samples/' ':!Documentation/' ':!scripts/' 2>/dev/null |
            awk '!/^arch\// || /^arch\/x86\//' || true)"
  for f in $files; do
    case "$f" in "$MODDIR"/*) ;; *) exporters+=("$f") ;; esac
  done
done < "$WT/imports.txt"

objs=()
if [ ${#exporters[@]} -gt 0 ]; then
  mapfile -t objs < <(printf '%s\n' "${exporters[@]}" | sort -u | sed -E 's/\.(c|S)$/.o/')
fi
if [ ${#objs[@]} -gt 0 ]; then
  log "compiling ${#objs[@]} exporting objects to obtain genksyms CRCs ... log: $WT/build-exporters.log"
  mk -k -j"$JOBS" "${objs[@]}" >"$WT/build-exporters.log" 2>&1 ||
    log "  (some exporter objects failed to compile; their CRCs are taken from the running kernel if possible)"
fi

# genksyms writes "#SYMVER <symbol> <crc>" into the .<object>.cmd file of each exporting object.
{
  for o in "${objs[@]}" "$WT/$MODDIR"/*.o; do
    o="${o#"$WT/"}"
    cmd="$WT/$(dirname "$o")/.$(basename "$o").cmd"
    if [ -f "$cmd" ]; then grep -h '^#SYMVER ' "$cmd" | awk '{printf "%s %s\n", $2, tolower($3)}' || true; fi
  done
} | sort -u > "$WT/crcs-from-source.txt"
# symbols exported by the module directory itself: modpost takes those from the objects it links
grep -h '^#SYMVER ' "$WT/$MODDIR"/.*.o.cmd 2>/dev/null | awk '{print $2}' | sort -u > "$WT/local-exports.txt" || true

join "$WT/imports.txt" "$WT/crcs-from-source.txt" > "$WT/crcs-genuine.txt"
n_imports="$(wc -l < "$WT/imports.txt")"
n_genuine="$(wc -l < "$WT/crcs-genuine.txt")"
log "CRCs computed from source for $n_genuine of $n_imports imported symbols"

ko_reference_crcs "$RUNNING" > "$WT/crcs-running-kernel.txt"
VERIFY_NOTE=""
if [ -s "$WT/crcs-running-kernel.txt" ]; then
  log "comparing source-computed CRCs with the running kernel ($RUNNING) ..."
  rc=0; ko_compare_crcs "$WT/crcs-genuine.txt" "$WT/crcs-running-kernel.txt" || rc=$?
  if [ $TARGET_IS_RUNNING = 1 ]; then
    case $rc in
      0) VERIFY_NOTE="verified: source-computed CRCs match the running kernel $RUNNING" ;;
      1) [ $FORCE = 1 ] || die "CRC mismatch: this source tree/config does not match the running kernel. Check the tag and config, or pass --force (unsafe)."
         VERIFY_NOTE="CRC MISMATCH IGNORED (--force) against $RUNNING" ;;
      *) VERIFY_NOTE="could not verify (no comparable CRCs)" ;;
    esac
  else
    VERIFY_NOTE="built for $REL while running $RUNNING - comparison above is informational only"
  fi
else
  VERIFY_NOTE="not verified (no reference modules for $RUNNING)"
fi

# Module.symvers for modpost: source-computed CRCs, then the running kernel's values for symbols
# we could not compute (asm/macro exports), minus symbols exported inside $MODDIR.
{
  cat "$WT/crcs-genuine.txt"
  if [ $TARGET_IS_RUNNING = 1 ]; then
    join -v1 "$WT/imports.txt" "$WT/crcs-genuine.txt" | join - "$WT/crcs-running-kernel.txt"
  fi
} | sort -u -k1,1 | join -v1 - "$WT/local-exports.txt" > "$WT/crcs-symvers.txt"

MODSYM="/lib/modules/$RUNNING/modules.symbols"
MODDEP="/lib/modules/$RUNNING/modules.dep"
exporter_of() {   # symbol -> "vmlinux" or "drivers/net/mii" (only affects the module's "depends:" field)
  local m p
  m="$(awk -v s="symbol:$1" '$2==s {print $3; exit}' "$MODSYM" 2>/dev/null || true)"
  [ -n "$m" ] || { echo vmlinux; return; }
  p="$(grep -m1 -E "^kernel/.*/${m//_/[_-]}\.ko:" "$MODDEP" 2>/dev/null | cut -d: -f1 || true)"
  p="${p#kernel/}"; p="${p%.ko}"
  echo "${p:-$m}"
}
while read -r sym crc; do
  printf '%s\t%s\t%s\tEXPORT_SYMBOL\t\n' "$crc" "$sym" "$(exporter_of "$sym")"
done < "$WT/crcs-symvers.txt" > "$WT/Module.symvers"
log "Module.symvers with $(wc -l < "$WT/Module.symvers") entries written"

# Pass 2: modpost now finds our Module.symvers. The sibling modules still have unresolved
# symbols (their imports are not in the table), so keep KBUILD_MODPOST_WARN=1 and check
# ax88179_178a.ko strictly afterwards.
log "building $MODDIR modules (pass 2, with CRCs) ... log: $WT/build-pass2.log"
rm -f "$WT/$MODDIR"/*.ko "$WT/$MODDIR/Module.symvers"
mk -j"$JOBS" M="$MODDIR" KBUILD_MODPOST_WARN=1 modules >"$WT/build-pass2.log" 2>&1 || { tail -40 "$WT/build-pass2.log"; die "module build (pass 2) failed"; }
if grep -E "\[$KO_NAME\.ko\] (undefined!|has no CRC)" "$WT/build-pass2.log"; then
  die "modpost could not resolve/version all symbols of $KO_NAME.ko (see above)"
fi

BUILT="$WT/$MODDIR/$KO_NAME.ko"
[ -f "$BUILT" ] || die "$BUILT not produced"
BUILT_REL="$(ko_release_of "$BUILT")"
[ "$BUILT_REL" = "$REL" ] || die "vermagic says '$BUILT_REL', expected '$REL'"
ko_is_patched "$BUILT"     || die "built module lacks the jumbo_patch marker - patch not applied?"

# Final gate: the CRCs embedded in the module vs. the running kernel.
n_versions="$(ko_dump_versions "$BUILT" | wc -l)"
if [ $TARGET_IS_RUNNING = 1 ]; then
  log "final check: CRCs embedded in the module ($n_versions) vs running kernel ..."
  ko_dump_versions "$BUILT" > "$WT/crcs-built.txt"
  rc=0; ko_compare_crcs "$WT/crcs-built.txt" "$WT/crcs-running-kernel.txt" || rc=$?
  if [ $rc -eq 1 ] && [ $FORCE = 0 ]; then die "embedded CRCs do not match the running kernel"; fi
fi

# ---------------------------------------------------------------- 8. save
OUT_DIR="$OUT_ROOT/$REL"
mkdir -p "$OUT_DIR"
strip --strip-debug -o "$OUT_DIR/$KO_NAME.ko" "$BUILT"
cp "$WT/jumbo.patch" "$OUT_DIR/jumbo.patch"
cat > "$OUT_DIR/BUILD_INFO.txt" <<INFO
module            : $KO_NAME.ko (jumbo frames: FLAG_NOMAXMTU, max_mtu 4088)
kernel_release    : $REL
built_for_running : $([ $TARGET_IS_RUNNING = 1 ] && echo yes || echo no) (kernel running at build time: $RUNNING)
source            : $REPO_URL
ref               : $REF
commit            : $COMMIT
config            : $CONFIG_SRC
patch             : ko/patches/apply-jumbo-patch.sh (resulting diff: jumbo.patch)
toolchain         : $(gcc --version | head -1)
built_on          : $(date -Iseconds) by $(id -un)
vermagic          : $(modinfo -F vermagic "$OUT_DIR/$KO_NAME.ko")
versioned_imports : $n_versions ($n_genuine CRCs computed from source, rest taken from the running kernel's modules)
crc_verification  : $VERIFY_NOTE
stripped          : strip --strip-debug (size $(stat -c %s "$OUT_DIR/$KO_NAME.ko") bytes)
INFO

log "saved: $OUT_DIR/$KO_NAME.ko"
sed 's/^/    /' "$OUT_DIR/BUILD_INFO.txt"

if [ $CLEAN = 1 ]; then
  log "removing worktree $WT"
  git -C "$KSRC" worktree remove --force "$WT"
fi

if [ $INSTALL = 1 ]; then
  if [ "$REL" = "$RUNNING" ]; then
    KO_ROOT="$OUT_ROOT" ko_apply
  else
    log "not installing: built for $REL, running $RUNNING"
  fi
else
  log "to install now:  sudo $SCRIPT_DIR/ko/ko_lib.sh apply   (run.bat / setup_interface_for_wsl.sh does this automatically)"
fi

#!/bin/bash
# clone-vm.sh — Clone one or more ESXi VMs from a template
# Requires: vmkfstools, vim-cmd (ESXi shell)

set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────
die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date '+%H:%M:%S')] $*"; }

command -v vmkfstools >/dev/null 2>&1 || die "vmkfstools not found — run this on an ESXi shell"
command -v vim-cmd    >/dev/null 2>&1 || die "vim-cmd not found — run this on an ESXi shell"

# ── select datastore ─────────────────────────────────────────────────────────
mapfile -t DATASTORES < <(find /vmfs/volumes -mindepth 1 -maxdepth 1 -type d -not -type l 2>/dev/null | sort)
[[ ${#DATASTORES[@]} -gt 0 ]] || die "No datastores found under /vmfs/volumes"

echo ""
echo "Available datastores:"
for i in "${!DATASTORES[@]}"; do
  echo "  [$i] ${DATASTORES[$i]}"
done
read -rp "Select datastore [0-$((${#DATASTORES[@]}-1))]: " DS_IDX
[[ "$DS_IDX" =~ ^[0-9]+$ && $DS_IDX -lt ${#DATASTORES[@]} ]] || die "Invalid selection"
DATASTORE="${DATASTORES[$DS_IDX]}"

# ── select template VM folder ─────────────────────────────────────────────────
mapfile -t FOLDERS < <(find "$DATASTORE" -mindepth 1 -maxdepth 1 -type d | sort)
[[ ${#FOLDERS[@]} -gt 0 ]] || die "No VM folders found in $DATASTORE"

echo ""
echo "VM folders in $(basename "$DATASTORE"):"
for i in "${!FOLDERS[@]}"; do
  echo "  [$i] $(basename "${FOLDERS[$i]}")"
done
read -rp "Select template VM [0-$((${#FOLDERS[@]}-1))]: " TPL_IDX
[[ "$TPL_IDX" =~ ^[0-9]+$ && $TPL_IDX -lt ${#FOLDERS[@]} ]] || die "Invalid selection"
TPL_DIR="${FOLDERS[$TPL_IDX]}"
TPL_NAME="$(basename "$TPL_DIR")"

# locate descriptor vmdk (not flat) and vmx
TPL_VMX="$(find  "$TPL_DIR" -maxdepth 1 -name '*.vmx'                       | head -1)"
TPL_VMDK="$(find "$TPL_DIR" -maxdepth 1 -name '*.vmdk' ! -name '*-flat.vmdk' | head -1)"
[[ -f "$TPL_VMX"  ]] || die "No .vmx found in $TPL_DIR"
[[ -f "$TPL_VMDK" ]] || die "No .vmdk descriptor found in $TPL_DIR"

# ── number of clones ──────────────────────────────────────────────────────────
echo ""
read -rp "How many clones to create (1-15): " CLONE_COUNT
[[ "$CLONE_COUNT" =~ ^([1-9]|1[0-5])$ ]] || die "Must be a number between 1 and 15"

# ── collect clone names ───────────────────────────────────────────────────────
CLONE_NAMES=()
for ((i=1; i<=CLONE_COUNT; i++)); do
  read -rp "  Name for clone $i: " cname
  [[ -n "$cname" ]] || die "Name cannot be empty"
  [[ ! -d "$DATASTORE/$cname" ]] || die "Folder '$DATASTORE/$cname' already exists"
  CLONE_NAMES+=("$cname")
done

# ── disk provisioning type ───────────────────────────────────────────────────
echo ""
echo "Disk provisioning:"
echo "  [1] eagerzeroedthick  (pre-zeroed thick — recommended for production)"
echo "  [2] zeroedthick       (lazy-zeroed thick)"
echo "  [3] thin              (thin provisioned)"
read -rp "Select [1-3, default=1]: " PROV_IDX
case "${PROV_IDX:-1}" in
  1) PROV="eagerzeroedthick" ;;
  2) PROV="zeroedthick"      ;;
  3) PROV="thin"             ;;
  *) die "Invalid provisioning selection" ;;
esac

echo ""
log "Template : $TPL_DIR"
log "Clones   : ${CLONE_NAMES[*]}"
log "Disk type: $PROV"
echo ""

# ── clone loop ────────────────────────────────────────────────────────────────
for CLONE_NAME in "${CLONE_NAMES[@]}"; do
  DEST_DIR="$DATASTORE/$CLONE_NAME"
  log ">>> Starting clone: $TPL_NAME  →  $CLONE_NAME"

  mkdir -p "$DEST_DIR"

  # 1. copy vmdk via vmkfstools (preserves provisioning / re-provisions)
  DEST_VMDK="$DEST_DIR/${CLONE_NAME}.vmdk"
  log "    vmkfstools  ($PROV)  …"
  vmkfstools -i "$TPL_VMDK" "$DEST_VMDK" -d "$PROV"

  # 2. copy extra config files, renaming TPL_NAME → CLONE_NAME in filenames
  for src in "$TPL_DIR"/*; do
    ext="${src##*.}"
    base="$(basename "$src")"
    # skip: vmdk (done), vmx (patched below), logs, lock dirs, flat vmdk
    case "$ext" in
      vmdk|vmx|log|lck) continue ;;
    esac
    [[ -f "$src" ]] || continue
    dest_file="${base/$TPL_NAME/$CLONE_NAME}"
    cp "$src" "$DEST_DIR/$dest_file"
    log "    cp  $base  →  $dest_file"
  done

  # 3. patch vmx: update displayName, disk references, and any other name refs
  DEST_VMX="$DEST_DIR/${CLONE_NAME}.vmx"
  sed \
    -e "s|displayName = \".*\"|displayName = \"${CLONE_NAME}\"|g" \
    -e "s|${TPL_NAME}\.vmdk|${CLONE_NAME}.vmdk|g" \
    -e "s|nvram = \"${TPL_NAME}|nvram = \"${CLONE_NAME}|g" \
    -e "s|extendedConfigFile = \"${TPL_NAME}|extendedConfigFile = \"${CLONE_NAME}|g" \
    "$TPL_VMX" > "$DEST_VMX"
  log "    vmx patched  →  $DEST_VMX"

  # 4. register VM in ESXi
  VMID="$(vim-cmd solo/registervm "$DEST_VMX")"
  log "    Registered with VM ID: $VMID"

  log ">>> Done: $CLONE_NAME"
  echo ""
done

log "All $CLONE_COUNT clone(s) completed successfully."

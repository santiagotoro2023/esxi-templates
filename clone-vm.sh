#!/bin/sh
# clone-vm.sh — Clone one or more ESXi VMs from a template
# Requires: vmkfstools, vim-cmd (ESXi shell) — POSIX sh only, no bash needed

set -eu

VMKFSTOOLS=/bin/vmkfstools
VIMCMD=/bin/vim-cmd

# ── helpers ──────────────────────────────────────────────────────────────────
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }


DS_FILE=/tmp/_esxi_ds.$$
FOLDER_FILE=/tmp/_esxi_folders.$$
NAMES_FILE=/tmp/_esxi_names.$$
trap 'rm -f "$DS_FILE" "$FOLDER_FILE" "$NAMES_FILE"' EXIT

# ── select datastore ─────────────────────────────────────────────────────────
find /vmfs/volumes -mindepth 1 -maxdepth 1 -type d -not -type l 2>/dev/null | sort > "$DS_FILE"
DS_COUNT=$(wc -l < "$DS_FILE")
[ "$DS_COUNT" -gt 0 ] || die "No datastores found under /vmfs/volumes"

printf '\nAvailable datastores:\n'
i=0
while IFS= read -r ds; do
  printf '  [%d] %s\n' "$i" "$ds"
  i=$((i+1))
done < "$DS_FILE"

printf 'Select datastore [0-%d]: ' "$((DS_COUNT-1))"
read -r DS_IDX
case "$DS_IDX" in ''|*[!0-9]*) die "Invalid selection" ;; esac
[ "$DS_IDX" -lt "$DS_COUNT" ] || die "Invalid selection"
DATASTORE=$(sed -n "$((DS_IDX+1))p" "$DS_FILE")

# ── select template VM folder ─────────────────────────────────────────────────
find "$DATASTORE" -mindepth 1 -maxdepth 1 -type d | sort > "$FOLDER_FILE"
FOLDER_COUNT=$(wc -l < "$FOLDER_FILE")
[ "$FOLDER_COUNT" -gt 0 ] || die "No VM folders found in $DATASTORE"

printf '\nVM folders in %s:\n' "$(basename "$DATASTORE")"
i=0
while IFS= read -r folder; do
  printf '  [%d] %s\n' "$i" "$(basename "$folder")"
  i=$((i+1))
done < "$FOLDER_FILE"

printf 'Select template VM [0-%d]: ' "$((FOLDER_COUNT-1))"
read -r TPL_IDX
case "$TPL_IDX" in ''|*[!0-9]*) die "Invalid selection" ;; esac
[ "$TPL_IDX" -lt "$FOLDER_COUNT" ] || die "Invalid selection"
TPL_DIR=$(sed -n "$((TPL_IDX+1))p" "$FOLDER_FILE")
TPL_NAME=$(basename "$TPL_DIR")

TPL_VMX=$(find  "$TPL_DIR" -maxdepth 1 -name '*.vmx'                        | head -1)
TPL_VMDK=$(find "$TPL_DIR" -maxdepth 1 -name '*.vmdk' ! -name '*-flat.vmdk' | head -1)
[ -f "$TPL_VMX"  ] || die "No .vmx found in $TPL_DIR"
[ -f "$TPL_VMDK" ] || die "No .vmdk descriptor found in $TPL_DIR"

# ── number of clones ──────────────────────────────────────────────────────────
printf '\nHow many clones to create (1-15): '
read -r CLONE_COUNT
case "$CLONE_COUNT" in
  [1-9]|1[0-5]) ;;
  *) die "Must be a number between 1 and 15" ;;
esac

# ── collect clone names ───────────────────────────────────────────────────────
> "$NAMES_FILE"
i=1
while [ "$i" -le "$CLONE_COUNT" ]; do
  printf '  Name for clone %d: ' "$i"
  read -r cname
  [ -n "$cname" ] || die "Name cannot be empty"
  [ ! -d "$DATASTORE/$cname" ] || die "Folder '$DATASTORE/$cname' already exists"
  printf '%s\n' "$cname" >> "$NAMES_FILE"
  i=$((i+1))
done

# ── disk provisioning type ───────────────────────────────────────────────────
printf '\nDisk provisioning:\n'
printf '  [1] eagerzeroedthick  (pre-zeroed thick - recommended for production)\n'
printf '  [2] zeroedthick       (lazy-zeroed thick)\n'
printf '  [3] thin              (thin provisioned)\n'
printf 'Select [1-3, default=1]: '
read -r PROV_IDX
case "${PROV_IDX:-1}" in
  1) PROV="eagerzeroedthick" ;;
  2) PROV="zeroedthick"      ;;
  3) PROV="thin"             ;;
  *) die "Invalid provisioning selection" ;;
esac

printf '\n'
log "Template : $TPL_DIR"
log "Disk type: $PROV"
printf '\n'

# ── clone loop ────────────────────────────────────────────────────────────────
while IFS= read -r CLONE_NAME; do
  DEST_DIR="$DATASTORE/$CLONE_NAME"
  log ">>> Starting clone: $TPL_NAME  ->  $CLONE_NAME"

  mkdir -p "$DEST_DIR"

  # 1. copy vmdk via vmkfstools
  DEST_VMDK="$DEST_DIR/${CLONE_NAME}.vmdk"
  log "    vmkfstools ($PROV) ..."
  "$VMKFSTOOLS" -i "$TPL_VMDK" "$DEST_VMDK" -d "$PROV"

  # 2. copy supporting files (nvram, vmsd, vmxf, ...), rename on the fly
  for src in "$TPL_DIR"/*; do
    [ -f "$src" ] || continue
    ext="${src##*.}"
    base=$(basename "$src")
    case "$ext" in
      vmdk|vmx|log|lck) continue ;;
    esac
    dest_file=$(printf '%s' "$base" | sed "s/${TPL_NAME}/${CLONE_NAME}/g")
    cp "$src" "$DEST_DIR/$dest_file"
    log "    cp $base -> $dest_file"
  done

  # 3. patch vmx
  DEST_VMX="$DEST_DIR/${CLONE_NAME}.vmx"
  sed \
    -e "s|displayName = \".*\"|displayName = \"${CLONE_NAME}\"|g" \
    -e "s|${TPL_NAME}\.vmdk|${CLONE_NAME}.vmdk|g" \
    -e "s|nvram = \"${TPL_NAME}|nvram = \"${CLONE_NAME}|g" \
    -e "s|extendedConfigFile = \"${TPL_NAME}|extendedConfigFile = \"${CLONE_NAME}|g" \
    "$TPL_VMX" > "$DEST_VMX"
  log "    vmx patched -> $DEST_VMX"

  # 4. register in ESXi
  VMID=$("$VIMCMD" solo/registervm "$DEST_VMX")
  log "    Registered VM ID: $VMID"

  log ">>> Done: $CLONE_NAME"
  printf '\n'
done < "$NAMES_FILE"

log "All $CLONE_COUNT clone(s) completed successfully."

#!/bin/sh
# clone-vm.sh — Clone one or more ESXi VMs from a template
# Santiago Toro - 06.05.2026 - Optimisiert durch Claude :)
set -eu

VMKFSTOOLS=/bin/vmkfstools
VIMCMD=/bin/vim-cmd

# ── helpers ──────────────────────────────────────────────────────────────────
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

# Generate a random UUID in VMware VMX format: "XX XX XX XX XX XX XX XX-XX XX XX XX XX XX XX XX"
gen_vmware_uuid() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | \
    awk '{s=$0; printf "%s %s %s %s %s %s %s %s-%s %s %s %s %s %s %s %s\n",
      substr(s,1,2),  substr(s,3,2),  substr(s,5,2),  substr(s,7,2),
      substr(s,9,2),  substr(s,11,2), substr(s,13,2), substr(s,15,2),
      substr(s,17,2), substr(s,19,2), substr(s,21,2), substr(s,23,2),
      substr(s,25,2), substr(s,27,2), substr(s,29,2), substr(s,31,2)}'
}

DS_FILE=/tmp/_esxi_ds.$$
FOLDER_FILE=/tmp/_esxi_folders.$$
NAMES_FILE=/tmp/_esxi_names.$$
trap 'rm -f "$DS_FILE" "$FOLDER_FILE" "$NAMES_FILE"' EXIT

# ── build datastore list: "friendly_name|resolved_path" ──────────────────────
# Skip UUID-named entries (two common ESXi UUID formats), keep only named ones
for _link in /vmfs/volumes/*; do
  _name=$(basename "$_link")
  case "$_name" in
    ????????-????-????-????-????????????) continue ;;
    ????????-????????-????-????????????) continue ;;
  esac
  _resolved=$(readlink -f "$_link" 2>/dev/null) || continue
  printf '%s|%s\n' "$_name" "$_resolved"
done > "$DS_FILE"
DS_COUNT=$(wc -l < "$DS_FILE")
[ "$DS_COUNT" -gt 0 ] || die "No named datastores found under /vmfs/volumes"

# ── print_datastores: display friendly name list ──────────────────────────────
print_datastores() {
  i=0
  while IFS='|' read -r _name _path; do
    printf '  [%d] %s\n' "$i" "$_name"
    i=$((i+1))
  done < "$DS_FILE"
}

# ── pick_ds_field <index> <field>: extract field 1=name 2=path ───────────────
pick_ds_field() {
  awk -F'|' -v n="$(($1+1))" -v f="$2" 'NR==n{print $f}' "$DS_FILE"
}

# ── browse_dir: interactive folder browser ────────────────────────────────────
# Usage: result=$(browse_dir <start_dir> <stop_mode>)
#   stop_mode=vmx   — offer "use this folder" only when a .vmx is present
#   stop_mode=any   — always offer "use this folder"
browse_dir() {
  _bd_dir="$1"
  _bd_mode="$2"

  while true; do
    find "$_bd_dir" -mindepth 1 -maxdepth 1 -type d | sort > "$FOLDER_FILE"
    _bd_fc=$(wc -l < "$FOLDER_FILE")

    if [ "$_bd_mode" = "vmx" ]; then
      _bd_vmx=$(find "$_bd_dir" -maxdepth 1 -name '*.vmx' 2>/dev/null | head -1)
    else
      _bd_vmx="yes"
    fi

    printf '\nLocation: %s\n' "$_bd_dir" >/dev/tty

    _bd_total=0
    if [ -n "$_bd_vmx" ]; then
      printf '  [0] *** Use this folder ***\n' >/dev/tty
      _bd_i=1
      while IFS= read -r _bd_f; do
        printf '  [%d] %s\n' "$_bd_i" "$(basename "$_bd_f")" >/dev/tty
        _bd_i=$((_bd_i+1))
      done < "$FOLDER_FILE"
      _bd_total=$((1 + _bd_fc))
    else
      _bd_i=0
      while IFS= read -r _bd_f; do
        printf '  [%d] %s\n' "$_bd_i" "$(basename "$_bd_f")" >/dev/tty
        _bd_i=$((_bd_i+1))
      done < "$FOLDER_FILE"
      _bd_total=$_bd_fc
    fi

    [ "$_bd_total" -gt 0 ] || die "No subfolders and no VM found in $_bd_dir"

    printf 'Select [0-%d]: ' "$((_bd_total-1))" >/dev/tty
    read -r _bd_sel </dev/tty
    case "$_bd_sel" in ''|*[!0-9]*) die "Invalid selection" ;; esac
    [ "$_bd_sel" -lt "$_bd_total" ] || die "Invalid selection"

    if [ -n "$_bd_vmx" ] && [ "$_bd_sel" -eq 0 ]; then
      printf '%s' "$_bd_dir"
      return
    elif [ -n "$_bd_vmx" ]; then
      _bd_dir=$(sed -n "${_bd_sel}p" "$FOLDER_FILE")
    else
      _bd_dir=$(sed -n "$((_bd_sel+1))p" "$FOLDER_FILE")
    fi
  done
}

# ── source datastore + template ───────────────────────────────────────────────
printf '\n=== SOURCE: select datastore ===\n'
print_datastores
printf 'Select datastore [0-%d]: ' "$((DS_COUNT-1))"
read -r DS_IDX
case "$DS_IDX" in ''|*[!0-9]*) die "Invalid selection" ;; esac
[ "$DS_IDX" -lt "$DS_COUNT" ] || die "Invalid selection"
SRC_DS=$(pick_ds_field "$DS_IDX" 2)
SRC_DS_NAME=$(pick_ds_field "$DS_IDX" 1)

printf '\n=== SOURCE: navigate to template VM folder ===\n'
TPL_DIR=$(browse_dir "$SRC_DS" vmx)

TPL_NAME=$(basename "$TPL_DIR")
TPL_VMX=$(find  "$TPL_DIR" -maxdepth 1 -name '*.vmx'                        | head -1)
TPL_VMDK=$(find "$TPL_DIR" -maxdepth 1 -name '*.vmdk' ! -name '*-flat.vmdk' | head -1)
[ -f "$TPL_VMX"  ] || die "No .vmx found in $TPL_DIR"
[ -f "$TPL_VMDK" ] || die "No .vmdk descriptor found in $TPL_DIR"
VMDK_BASE=$(basename "$TPL_VMDK" .vmdk)

# ── destination datastore + folder ───────────────────────────────────────────
printf '\n=== DESTINATION: select datastore ===\n'
print_datastores
printf 'Select datastore [0-%d]: ' "$((DS_COUNT-1))"
read -r DST_DS_IDX
case "$DST_DS_IDX" in ''|*[!0-9]*) die "Invalid selection" ;; esac
[ "$DST_DS_IDX" -lt "$DS_COUNT" ] || die "Invalid selection"
DST_DS=$(pick_ds_field "$DST_DS_IDX" 2)
DST_DS_NAME=$(pick_ds_field "$DST_DS_IDX" 1)

printf '\n=== DESTINATION: navigate to target parent folder ===\n'
DEST_PARENT=$(browse_dir "$DST_DS" any)

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
  [ ! -d "$DEST_PARENT/$cname" ] || die "Folder '$DEST_PARENT/$cname' already exists"
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
log "Template  : $TPL_NAME  (on $SRC_DS_NAME)"
log "Dest root : $DEST_PARENT  (on $DST_DS_NAME)"
log "Disk type : $PROV"
printf '\n'

# ── clone loop ────────────────────────────────────────────────────────────────
while IFS= read -r CLONE_NAME; do
  DEST_DIR="$DEST_PARENT/$CLONE_NAME"
  log ">>> Starting clone: $TPL_NAME  ->  $CLONE_NAME"
  NEW_VM_UUID=$(gen_vmware_uuid)
  NEW_BIOS_UUID=$(gen_vmware_uuid)

  mkdir -p "$DEST_DIR"

  DEST_VMDK="$DEST_DIR/${CLONE_NAME}.vmdk"
  log "    vmkfstools ($PROV) ..."
  "$VMKFSTOOLS" -i "$TPL_VMDK" "$DEST_VMDK" -d "$PROV"

  for src in "$TPL_DIR"/*; do
    [ -f "$src" ] || continue
    ext="${src##*.}"
    base=$(basename "$src")
    case "$ext" in
      vmdk|vmx|log|lck) continue ;;
    esac
    dest_file=$(printf '%s' "$base" | sed "s/${VMDK_BASE}/${CLONE_NAME}/g")
    cp "$src" "$DEST_DIR/$dest_file"
    log "    cp $base -> $dest_file"
  done

  DEST_VMX="$DEST_DIR/${CLONE_NAME}.vmx"
  sed \
    -e "s|displayName = \".*\"|displayName = \"${CLONE_NAME}\"|g" \
    -e "s|\"[^\"]*${VMDK_BASE}\.vmdk\"|\"${CLONE_NAME}.vmdk\"|g" \
    -e "s|nvram = \"[^\"]*${VMDK_BASE}[^\"]*\"|nvram = \"${CLONE_NAME}.nvram\"|g" \
    -e "s|extendedConfigFile = \"[^\"]*${VMDK_BASE}[^\"]*\"|extendedConfigFile = \"${CLONE_NAME}.vmxf\"|g" \
    -e '/^uuid\.location /d' \
    -e '/^uuid\.bios /d' \
    -e '/^vc\.uuid /d' \
    "$TPL_VMX" > "$DEST_VMX"
  printf 'uuid.location = "%s"\n' "$NEW_VM_UUID"  >> "$DEST_VMX"
  printf 'uuid.bios = "%s"\n'     "$NEW_BIOS_UUID" >> "$DEST_VMX"
  log "    vmx patched -> $DEST_VMX"

  VMID=$("$VIMCMD" solo/registervm "$DEST_VMX")
  log "    Registered VM ID: $VMID"

  log ">>> Done: $CLONE_NAME"
  printf '\n'
done < "$NAMES_FILE"

log "All $CLONE_COUNT clone(s) completed successfully."

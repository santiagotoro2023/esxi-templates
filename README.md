# esxi-templates

A single Bash script that clones an ESXi VM from a template — up to 15 copies in one run.

For each clone it:
1. Copies the disk with `vmkfstools` (preserves / re-provisions)
2. Copies all supporting files (`nvram`, `vmsd`, `vmxf`, …) with names adjusted
3. Patches the `.vmx` (display name + file references)
4. Registers the new VM with `vim-cmd` so it appears immediately in ESXi

---

## Requirements

| Requirement | Notes |
|---|---|
| ESXi 6.x / 7.x / 8.x | Script must run **on the ESXi shell**, not a remote client |
| `vmkfstools` | Built into ESXi |
| `vim-cmd` | Built into ESXi |
| Bash ≥ 4 | `/bin/bash` on ESXi 6.5+ is sufficient |

> **The template VM must be powered off before running the script.**

---

## Usage

### 1. SSH into the ESXi host

```sh
ssh root@<esxi-ip>
```

### 2. Run — no download needed

```sh
curl -sSL https://raw.githubusercontent.com/santiagotoro2023/esxi-templates/main/clone-vm.sh > /tmp/clone-vm.sh && bash /tmp/clone-vm.sh
```

> If `curl` is not available (older ESXi), use `wget`:
> ```sh
> wget -qO /tmp/clone-vm.sh https://raw.githubusercontent.com/santiagotoro2023/esxi-templates/main/clone-vm.sh && bash /tmp/clone-vm.sh
> ```

> **Why not `curl ... | bash`?**
> ESXi's default shell is `ash` (busybox). Piping into bash closes stdin and breaks all interactive prompts. Writing to `/tmp` first keeps stdin on your terminal.

### 3. Follow the prompts

```
Available datastores:
  [0] /vmfs/volumes/datastore1
  [1] /vmfs/volumes/ssd-pool
Select datastore [0-1]: 0

VM folders in datastore1:
  [0] LERN-ST-IMG-21
  [1] WIN11-BASE
Select template VM [0-1]: 0

How many clones to create (1-15): 3
  Name for clone 1: LERN-ST-TEST-01
  Name for clone 2: LERN-ST-TEST-02
  Name for clone 3: LERN-ST-TEST-03

Disk provisioning:
  [1] eagerzeroedthick  (pre-zeroed thick — recommended for production)
  [2] zeroedthick       (lazy-zeroed thick)
  [3] thin              (thin provisioned)
Select [1-3, default=1]: 1
```

The script clones all VMs and registers them. Done.

---

## What gets copied

| File | How |
|---|---|
| `*.vmdk` (descriptor + flat) | `vmkfstools -i` — re-provisions with chosen disk type |
| `*.nvram` | `cp` + renamed |
| `*.vmsd` | `cp` + renamed |
| `*.vmxf` | `cp` + renamed |
| `*.vmx` | `sed`-patched: `displayName`, disk path, nvram/config refs updated |
| `*.log`, `*.lck` | **skipped** (not needed for a fresh clone) |

---

## Disk provisioning types

| Type | Description |
|---|---|
| `eagerzeroedthick` | Pre-zeroes all blocks upfront. Slowest to create, best runtime I/O. Required for FT & encryption. |
| `zeroedthick` | Allocates full space, zeroes on first write. Faster to create. |
| `thin` | Allocates only used space. Fast to create, best for lab/test environments. |

---

## Cleanup — remove a failed or unwanted clone

```sh
vim-cmd vmsvc/unregister <VMID>
rm -rf /vmfs/volumes/<datastore>/<clone-name>
```

---

## Manual equivalent (what the script automates)

```sh
# 1. copy disk
vmkfstools -i LERN-ST-IMG-21/LERN-ST-IMG-01.vmdk \
           ./LERN-ST-TEST-03/LERN-ST-TEST-03.vmdk \
           -d eagerzeroedthick

# 2. copy config files
cp LERN-ST-IMG-21/LERN-ST-IMG-01.nvram  ./LERN-ST-TEST-03/LERN-ST-TEST-03.nvram
cp LERN-ST-IMG-21/LERN-ST-IMG-01.vmsd   ./LERN-ST-TEST-03/LERN-ST-TEST-03.vmsd
cp LERN-ST-IMG-21/LERN-ST-IMG-01.vmxf   ./LERN-ST-TEST-03/LERN-ST-TEST-03.vmxf

# 3. patch vmx
sed -e 's|displayName = ".*"|displayName = "LERN-ST-TEST-03"|' \
    -e 's|LERN-ST-IMG-01.vmdk|LERN-ST-TEST-03.vmdk|g' \
    LERN-ST-IMG-21/LERN-ST-IMG-01.vmx > ./LERN-ST-TEST-03/LERN-ST-TEST-03.vmx

# 4. register
vim-cmd solo/registervm ./LERN-ST-TEST-03/LERN-ST-TEST-03.vmx
```

---

## License

MIT

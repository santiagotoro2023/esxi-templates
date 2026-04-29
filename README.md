# esxi-templates

A shell script that clones an ESXi VM from a template — up to 15 copies in one run. Written in pure POSIX `sh`, no bash required.

For each clone it:
1. Copies the disk with `vmkfstools` (preserves / re-provisions)
2. Copies all supporting files (`nvram`, `vmsd`, `vmxf`) with names adjusted
3. Patches the `.vmx` (display name + all file references)
4. Registers the new VM with `vim-cmd` so it appears immediately in ESXi

Clones are placed in the same folder as the template VM.

---

## Requirements

| Requirement | Notes |
|---|---|
| ESXi 6.x / 7.x / 8.x | Script must run **on the ESXi shell**, not a remote client |
| `vmkfstools` | Built into ESXi |
| `vim-cmd` | Built into ESXi |
| `/bin/sh` | Built into ESXi — no bash needed |

> **The template VM must be powered off before running the script.**

---

## Setup — transfer the script to ESXi

ESXi cannot reach GitHub directly. Run this **on your local machine** to download and transfer the script:

**Windows (PowerShell):**
```powershell
curl.exe -sSL https://raw.githubusercontent.com/santiagotoro2023/esxi-templates/main/clone-vm.sh -o "$env:TEMP\clone-vm.sh"
scp "$env:TEMP\clone-vm.sh" root@<esxi-ip>:/tmp/clone-vm.sh
```

**macOS / Linux:**
```sh
curl -sSL https://raw.githubusercontent.com/santiagotoro2023/esxi-templates/main/clone-vm.sh | ssh root@<esxi-ip> "cat > /tmp/clone-vm.sh"
```

---

## Usage

SSH into ESXi and run:

```sh
sh /tmp/clone-vm.sh
```

---

## Walkthrough

### 1. Select datastore

```
Available datastores:
  [0] /vmfs/volumes/datastore1
  [1] /vmfs/volumes/ssd-pool
Select datastore [0-1]: 0
```

### 2. Navigate to the template VM

The browser lets you go as deep as needed. At each level, pick a subfolder to enter it. Once you're inside a folder that contains a VM, option `[0]` appears to select it as the template.

```
Location: /vmfs/volumes/datastore1
  [0] Lernumgebung-03-ST
  [1] other-folder
Select [0-1]: 0

Location: /vmfs/volumes/datastore1/Lernumgebung-03-ST
  [0] LERN-ST-IMG-21
  [1] LERN-ST-TEST-01
Select [0-1]: 0

Location: /vmfs/volumes/datastore1/Lernumgebung-03-ST/LERN-ST-IMG-21
  [0] *** Use this folder as template ***
Select [0-0]: 0
```

### 3. Name the clones

```
How many clones to create (1-15): 2
  Name for clone 1: LERN-ST-TEST-04
  Name for clone 2: LERN-ST-TEST-05
```

### 4. Choose disk provisioning

```
Disk provisioning:
  [1] eagerzeroedthick  (pre-zeroed thick - recommended for production)
  [2] zeroedthick       (lazy-zeroed thick)
  [3] thin              (thin provisioned)
Select [1-3, default=1]:
```

The script then clones all VMs, patches their configs, and registers them. Done.

---

## What gets copied

| File | How |
|---|---|
| `*.vmdk` (descriptor + flat) | `vmkfstools -i` — full copy with chosen provisioning |
| `*.nvram` | `cp` + renamed to match clone |
| `*.vmsd` | `cp` + renamed to match clone |
| `*.vmxf` | `cp` + renamed to match clone |
| `*.vmx` | `sed`-patched: `displayName`, disk path, nvram + config refs |
| `*.log`, `*.lck` | **skipped** |

---

## Disk provisioning types

| Type | Description |
|---|---|
| `eagerzeroedthick` | Pre-zeroes all blocks upfront. Best runtime I/O. Required for FT & encryption. |
| `zeroedthick` | Allocates full space, zeroes on first write. |
| `thin` | Allocates only used space. Best for lab/test environments. |

---

## Cleanup — remove a clone

```sh
vim-cmd vmsvc/unregister <VMID>
rm -rf /vmfs/volumes/<datastore>/<path-to-clone>
```

---

## License

MIT

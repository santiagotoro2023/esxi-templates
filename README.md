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

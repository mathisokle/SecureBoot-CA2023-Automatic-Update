# Invoke-SecureBootCA2023Update

PowerShell automation to **detect, remediate, and validate** the Microsoft **Windows UEFI CA 2023** Secure Boot update state on supported Windows systems.

This script is intended for administrators who need a repeatable way to:

- detect whether a host still needs the Secure Boot **DB** update and/or **Boot Manager** update
- apply the update workflow using the built-in Windows scheduled task
- continue automatically across reboots
- validate that the Secure Boot DB and EFI Boot Manager trust **Windows UEFI CA 2023**
- generate logs and a clear final summary

---

## What the script does

The script automates the Microsoft Secure Boot update workflow in multiple stages.

### Detection (`-Check`)
In check mode, the script performs **read-only validation** and does not modify the system.

It checks:

- whether **Secure Boot** is enabled
- whether the scheduled task `\Microsoft\Windows\PI\Secure-Boot-Update` exists
- the current Secure Boot servicing registry state
- whether the Secure Boot **DB** contains `Windows UEFI CA 2023`
- whether `bootmgfw.efi` is chained to `Windows UEFI CA 2023`

### Remediation (default mode)
When run without `-Check`, the script:

1. Performs pre-checks
2. Backs up BitLocker protector information
3. Detects whether the **DB** update is needed
4. Detects whether the **Boot Manager** update is needed
5. Triggers the Microsoft scheduled task for the required phase
6. Registers itself in **RunOnce** so it continues after reboot
7. Reboots as needed
8. Re-validates DB and Boot Manager state after reboot
9. Prints a final summary showing whether the host is compliant

---

## Supported platforms

### Intended platforms
This script is intended for:

- **Windows Server** systems
- **Windows client** systems
- systems booting in **UEFI** mode
- systems with **Secure Boot enabled**
- physical devices or VMs where the platform properly supports Secure Boot variable updates

### Common environments
This can be useful on:

- Windows Server 2016 / 2019 / 2022 / 2025
- Windows 10 / 11
- Hyper-V VMs
- VMware VMs with UEFI + Secure Boot enabled
- physical OEM hardware with supported firmware

### Requirements
The script assumes:

- PowerShell is run **as Administrator**
- Secure Boot is enabled
- the Windows scheduled task exists:
  - `\Microsoft\Windows\PI\Secure-Boot-Update`
- the system has the relevant Microsoft servicing support for the Secure Boot CA 2023 update process

---

## Important notes

### BitLocker
Before changing Secure Boot state, make sure your BitLocker recovery process is understood and documented.

This script **backs up BitLocker protector information**, but it does **not** automatically suspend BitLocker unless you add that behavior yourself.

If your environment requires it, consider suspending BitLocker before remediation.

### Reboots are required
This workflow is **multi-stage** and uses **reboots** intentionally.

The script uses:

- a local **state file**
- a **RunOnce** entry

so that it can continue automatically after reboot.

### Status values may lag behind
On some systems, especially virtualized ones, the registry servicing state may still show values like `InProgress` for some time even when the DB and Boot Manager already validate successfully.

For that reason, this script treats the following as the **real compliance signal**:

- DB contains `Windows UEFI CA 2023`
- Boot Manager validates against `Windows UEFI CA 2023`

---

## Script behavior by stage

### Stage 0
Pre-checks and decision logic:

- verifies admin context
- verifies Secure Boot
- verifies the scheduled task exists
- backs up BitLocker info
- checks whether DB already contains CA 2023
- checks whether Boot Manager already chains to CA 2023
- decides whether to:
  - finish immediately
  - trigger the DB update
  - skip DB and go directly to Boot Manager update

### Stage 1
Post-reboot validation of the DB update:

- checks whether the Secure Boot DB now contains `Windows UEFI CA 2023`
- if successful, triggers the Boot Manager update

### Stage 2
Post-reboot validation of the Boot Manager update:

- mounts the EFI partition
- copies `bootmgfw.efi`
- checks the certificate chain for `Windows UEFI CA 2023`
- triggers an additional confirmation reboot

### Stage 3
Final validation:

- checks DB state again
- checks Boot Manager chain again
- writes a final summary
- removes RunOnce and state data if successful

---

## Parameters

### `-Check`
Read-only detection mode.

The script will:

- not modify registry values
- not start the scheduled task
- not reboot
- return exit codes suitable for deployment tools

### `-NoReboot`
Skips actual reboot execution.

Useful for testing the logic without rebooting.

### `-ContinueAfterReboot`
Used internally by the script through **RunOnce**.

Normally you do not need to run this manually.

---

## Exit codes

### `-Check` mode
- `0` = compliant / update not needed
- `1` = update needed
- `2` = detection failed

### remediation mode
- `0` = success / compliant
- `1` = remediation failed or final validation failed

---

## Usage

### Check only
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Invoke-SecureBootCA2023Update.ps1 -Check

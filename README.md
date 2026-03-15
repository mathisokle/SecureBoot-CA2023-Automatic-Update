<div align="center">

<img src="./assets/securebootca2023-banner.svg" alt="Secure Boot CA 2023 Update" width="100%">

# Invoke-SecureBootCA2023Update

**Professional operational guide for checking and applying the Microsoft Secure Boot CA 2023 update on Windows systems**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207.x-5391FE?logo=powershell&logoColor=white)](#requirements)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011%20%7C%20Server%202019%20%7C%202022%20%7C%202025-0078D4?logo=windows&logoColor=white)](#validated-platforms)
[![Privilege](https://img.shields.io/badge/Run%20as-Administrator-important)](#execution)
[![Secure%20Boot](https://img.shields.io/badge/Feature-Secure%20Boot-success)](#overview)

</div>

---

## Overview

`Invoke-SecureBootCA2023Update.ps1` is an administrative PowerShell script designed to:

- inspect the current Secure Boot CA 2023 readiness state,
- trigger the Microsoft-managed Secure Boot update workflow,
- evaluate KEK, DB, and Boot Manager update evidence,
- handle reboot continuation when the Boot Manager stage requires it,
- provide structured logging and post-run status summaries.

The script supports two primary operating modes:

- **Check mode**: reads the current state and reports whether the machine is already compliant.
- **Apply mode**: triggers the official Microsoft-managed update path and verifies the resulting state.

---

## Important VMware Prerequisite

### For VMware-based Windows virtual machines, complete the Secure Boot Platform Key update first

Before running this script on **VMware Windows VMs**, you must first complete the manual Secure Boot Platform Key remediation described in the Broadcom knowledge article below:

**Broadcom guide:**  
<https://knowledge.broadcom.com/external/article/423919/manual-update-of-secure-boot-variables-i.html>

### Why this matters

On affected VMware virtual machines, an invalid or outdated **Platform Key (PK)** can prevent the Secure Boot update chain from completing correctly. If this prerequisite is skipped, the Windows Secure Boot CA 2023 servicing workflow can fail even when the PowerShell script itself is working exactly as intended. Human beings do enjoy blaming the script for firmware and platform-state problems, but reality remains stubborn.

### Required order of operations

1. **If the system is a VMware Windows VM**, complete the Broadcom PK update process first.
2. Reboot the VM if required by the platform procedure.
3. Confirm the machine boots normally with Secure Boot enabled.
4. Only then run `Invoke-SecureBootCA2023Update.ps1`.

### Applies to

- VMware Windows Server 2019 VMs
- VMware Windows Server 2022 VMs
- VMware Windows Server 2025 VMs
- VMware Windows 10 VMs
- VMware Windows 11 VMs

---

## Validated Platforms

This README is written for the following target operating systems:

| Operating System | Architecture | Secure Boot | Notes |
|---|---:|---:|---|
| Windows Server 2019 | x64 | Required | Run elevated PowerShell |
| Windows Server 2022 | x64 | Required | Run elevated PowerShell |
| Windows Server 2025 | x64 | Required | Run elevated PowerShell |
| Windows 10 | x64 | Required | UEFI required |
| Windows 11 | x64 | Required | UEFI required |

> **Note**
> The script is intended for systems using **UEFI + Secure Boot**. It is not relevant for legacy BIOS systems.

---

## What the Script Does

The script performs the following major actions:

### 1. Read current Secure Boot state

It evaluates:

- Secure Boot availability and enablement
- registry servicing state under:
  - `HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot`
  - `HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing`
- scheduled task presence:
  - `\Microsoft\Windows\PI\Secure-Boot-Update`
- recent Secure Boot related event log entries
- Boot Manager signing evidence
- whether KEK and DB already contain 2023 CA entries

### 2. Trigger the Microsoft-managed update path

In **Apply mode**, the script sets:

- `MicrosoftUpdateManagedOptIn = 1`
- `AvailableUpdates = 0x5944`

It then starts the scheduled task:

- `\Microsoft\Windows\PI\Secure-Boot-Update`

### 3. Detect reboot handoff conditions

If the machine reaches the expected intermediary stage for the Boot Manager update, the script can:

- register a continuation command in `RunOnce`,
- reboot automatically unless `-NoReboot` is used,
- resume validation after restart using `-ContinueAfterReboot`.

### 4. Write logs and summaries

The script writes state and logs under:

```text
%ProgramData%\SecureBootCA2023
```

Key files:

```text
%ProgramData%\SecureBootCA2023\Invoke-SecureBootCA2023Update.log
%ProgramData%\SecureBootCA2023\state.json
```

---

## Requirements

### Mandatory requirements

- Windows PowerShell running **as Administrator**
- UEFI firmware
- Secure Boot enabled
- Microsoft Secure Boot servicing components available on the OS
- Scheduled task present:

```text
\Microsoft\Windows\PI\Secure-Boot-Update
```

### Recommended requirements

- Recent Windows updates installed
- Maintenance window available for reboot handling
- Console or remote management access in case platform remediation is required
- Snapshot or backup before applying changes on production systems

### VMware recommendation

For VMware-hosted Windows VMs:

- take a VM snapshot before platform-key remediation,
- complete the Broadcom PK update guidance first,
- then run this script.

---

## Files

### Primary script

```text
Invoke-SecureBootCA2023Update.ps1
```

### Generated working directory

```text
C:\ProgramData\SecureBootCA2023
```

---

## Parameters

| Parameter | Purpose |
|---|---|
| `-Check` | Runs inspection only and returns compliance status |
| `-Apply` | Applies the Microsoft-managed Secure Boot CA 2023 workflow |
| `-ContinueAfterReboot` | Internal continuation stage after reboot |
| `-NoReboot` | Prevents automatic restart during Apply mode |

### Parameter notes

- If no mode is supplied, the script defaults to **Check mode**.
- `-ContinueAfterReboot` is intended for the continuation path and normally should not be used manually unless you explicitly want to resume post-reboot validation yourself.

---

## Execution

### 1. Open an elevated PowerShell session

Use **Run as administrator**.

### 2. Change to the script directory

```powershell
cd C:\Path\To\Script
```

### 3. Run a compliance check

```powershell
.\Invoke-SecureBootCA2023Update.ps1 -Check
```

### 4. Apply the update workflow

```powershell
.\Invoke-SecureBootCA2023Update.ps1 -Apply
```

### 5. Apply without automatic reboot

```powershell
.\Invoke-SecureBootCA2023Update.ps1 -Apply -NoReboot
```

If a reboot is required and `-NoReboot` was used, reboot the machine manually and then run:

```powershell
.\Invoke-SecureBootCA2023Update.ps1 -Apply
```

---

## Recommended Operational Workflow

### Standard physical machine workflow

```text
1. Confirm Secure Boot is enabled
2. Run script in -Check mode
3. Review status and log output
4. Run script in -Apply mode
5. Allow reboot if requested
6. Review final compliance summary
```

### VMware Windows VM workflow

```text
1. Read and complete Broadcom PK remediation procedure
2. Snapshot the VM
3. Confirm Secure Boot is enabled and VM boots normally
4. Run script in -Check mode
5. Run script in -Apply mode
6. Reboot when prompted or required
7. Verify final compliance state
```

---

## Understanding Exit Codes

| Exit Code | Meaning |
|---:|---|
| `0` | Success or already compliant |
| `1` | Check completed and system still needs update |
| `2` | Reboot required, but `-NoReboot` prevented automatic restart |
| `99` | Failure condition encountered |

---

## Typical Outcomes

### Already compliant

Indicators may include:

- KEK contains the 2023 CA
- DB contains the 2023 CA
- Boot Manager is confirmed as signed by Windows UEFI CA 2023
- final summary reports `Completed = True`

### Update required

Indicators may include:

- Secure Boot DB does not contain 2023 CA(s)
- KEK does not contain the 2023 CA
- Boot Manager is not yet confirmed as 2023-signed

### Reboot handoff reached

This commonly means:

- KEK/DB processing has progressed,
- Boot Manager update confirmation requires reboot completion,
- the script registers continuation via `RunOnce` unless prevented.

---

## Logging and Evidence Collection

The script records operational detail to:

```text
C:\ProgramData\SecureBootCA2023\Invoke-SecureBootCA2023Update.log
```

It also evaluates:

- registry state,
- scheduled task state,
- Secure Boot variables,
- selected system event IDs,
- Boot Manager signing evidence via `certutil` and signature inspection.

This makes it suitable for administrative verification and change documentation. A rare moment of order in the usual infrastructure circus.

---

## Troubleshooting

## 1. `Secure Boot is not enabled.`

### Cause

The machine is not currently booted with Secure Boot active.

### Action

- enable UEFI Secure Boot in firmware or VM settings,
- confirm the OS boots successfully,
- rerun the script.

---

## 2. `Scheduled task \Microsoft\Windows\PI\Secure-Boot-Update is missing.`

### Cause

The Windows servicing components required for the Secure Boot update workflow are not available.

### Action

- install the relevant Windows updates,
- confirm the task exists,
- rerun the script.

---

## 3. `Event 1803` or message about missing OEM PK-signed KEK

### Cause

The system cannot proceed because the platform does not expose a valid OEM PK-signed KEK path.

### Action

- for VMware Windows VMs, complete the Broadcom Platform Key remediation first,
- for physical devices, review OEM or firmware guidance,
- rerun the script after the platform issue is corrected.

---

## 4. `Event 1795` firmware error

### Cause

The firmware rejected a Secure Boot variable update.

### Action

- treat this as a firmware or platform issue,
- check BIOS, UEFI, OEM, hypervisor, or VM configuration,
- do not assume the PowerShell script is the root cause.

---

## 5. Boot Manager not yet confirmed as 2023-signed

### Cause

The Boot Manager phase has not completed or a reboot is still pending.

### Action

- reboot if requested,
- rerun the script in `-Apply` mode if necessary,
- review the log and final summary.

---

## Verification Checklist

Use this checklist after execution:

- [ ] System boots successfully
- [ ] Secure Boot is enabled
- [ ] `-Check` mode reports compliant
- [ ] KEK contains 2023 CA
- [ ] DB contains 2023 CA
- [ ] Boot Manager is confirmed as CA 2023 signed
- [ ] No blocking Event 1795 or 1803 remains
- [ ] Final summary shows `Completed = True`

---

## Example Commands

### Simple read-only compliance check

```powershell
PowerShell.exe -ExecutionPolicy Bypass -File .\Invoke-SecureBootCA2023Update.ps1 -Check
```

### Apply update path interactively

```powershell
PowerShell.exe -ExecutionPolicy Bypass -File .\Invoke-SecureBootCA2023Update.ps1 -Apply
```

### Apply update path but keep reboot manual

```powershell
PowerShell.exe -ExecutionPolicy Bypass -File .\Invoke-SecureBootCA2023Update.ps1 -Apply -NoReboot
```

---

## Best Practices

- test first on non-production systems,
- use snapshots for VMware VMs,
- schedule a maintenance window,
- preserve log output for audit or support review,
- complete platform remediation before blaming automation.

---

## Disclaimer

This script helps automate the **Windows-managed Secure Boot CA 2023 update workflow**, but it cannot override platform, firmware, OEM, or hypervisor-level failures. If the underlying PK, firmware trust chain, or Secure Boot platform state is wrong, the script will report the failure honestly instead of pretending everything is fine like half the tooling market.

---

## Quick Start

```powershell
# 1) VMware Windows VM only: complete the Broadcom PK guide first
# 2) Run a compliance check
.\Invoke-SecureBootCA2023Update.ps1 -Check

# 3) Apply the update workflow
.\Invoke-SecureBootCA2023Update.ps1 -Apply
```

---

<div align="center">

**Professional documentation for administrators who prefer clear outcomes over mystical troubleshooting rituals.**

</div>
****

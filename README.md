<div align="center">

<img src="./assets/securebootca2023-banner.svg" alt="Secure Boot CA 2023 Update" width="100%">

# Invoke-SecureBootCA2023Update

**Operational guide for checking and applying the Microsoft Secure Boot CA 2023 update on supported Windows platforms**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207.x-5391FE?logo=powershell&logoColor=white)](#requirements)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011%20%7C%20Server%202019%20%7C%202022%20%7C%202025-0078D4?logo=windows&logoColor=white)](#supported-platforms)
[![Run as Administrator](https://img.shields.io/badge/Run%20as-Administrator-CB3837)](#execution)
[![Secure Boot](https://img.shields.io/badge/Feature-Secure%20Boot-2EA44F)](#overview)

</div>

---

## Overview

`Invoke-SecureBootCA2023Update.ps1` is a PowerShell script for inspecting and triggering the Microsoft-managed Secure Boot CA 2023 update workflow on supported Windows systems.

It is intended to help administrators:

- check current Secure Boot update readiness,
- apply the CA 2023 update workflow,
- review KEK, DB, and Boot Manager state,
- handle reboot continuation when required,
- produce consistent operational logs.

The script supports two primary modes:

- **Check mode** to inspect status without making changes
- **Apply mode** to trigger the Microsoft-managed update path

---

## Supported Platforms

This documentation is written for the following supported operating systems:

| Operating System | Architecture | UEFI Required | Secure Boot Required | Status |
|---|---:|---:|---:|---|
| Windows Server 2019 | x64 | Yes | Yes | Supported |
| Windows Server 2022 | x64 | Yes | Yes | Supported |
| Windows Server 2025 | x64 | Yes | Yes | Supported |
| Windows 10 | x64 | Yes | Yes | Supported |
| Windows 11 | x64 | Yes | Yes | Supported |

### Unsupported platforms

- **Windows Server 2016 and lower are not supported by this documentation**
- Legacy BIOS systems are not supported
- Systems without Secure Boot enabled are not in scope for this workflow

If the machine is not running UEFI with Secure Boot enabled, this script is the wrong tool for the job. The universe remains cruelly consistent on that point.

---

## Official Microsoft Guidance

Use the following Microsoft guidance as the primary reference set for planning and validation:

- **Microsoft support guidance for organizations:**
  <https://support.microsoft.com/en-us/topic/secure-boot-certificate-updates-guidance-for-it-professionals-and-organizations-e2b43f9f-b424-42df-bc6a-8476db65ab2f>
- **Microsoft support article for Secure Boot revocations and mitigation flow:**
  <https://support.microsoft.com/en-us/topic/how-to-manage-the-windows-boot-manager-revocations-for-secure-boot-changes-associated-with-cve-2023-24932-41a975df-beb2-40c1-99a3-b3ff139f832d>
- **Microsoft Tech Community post:**
  <https://techcommunity.microsoft.com/blog/windows-itpro-blog/act-now-secure-boot-certificates-expire-in-june-2026/4426856>

Microsoft states that all Windows devices with Secure Boot enabled must be updated to the 2023 certificates before the 2011 certificates expire, and it continues to reference the CVE-2023-24932 revocation guidance as part of the supported Secure Boot update process. citeturn391804search2turn391804search0turn619394search7

---

## Important VMware Prerequisite

### VMware Windows virtual machines must be remediated first

Before running this script on **VMware Windows VMs**, complete the Broadcom Secure Boot variable remediation first:

- **Broadcom knowledge article:**
  <https://knowledge.broadcom.com/external/article/423919/manual-update-of-secure-boot-variables-i.html>

This must be done **before** running `Invoke-SecureBootCA2023Update.ps1` on affected VMware guests.

Broadcom documents that certain VMware Windows VMs can have an invalid Platform Key state that prevents Secure Boot variable updates from working correctly. Their remediation replaces the invalid Platform Key with the Windows OEM Device Key before automated Secure Boot update steps are attempted. citeturn391804search2

### Required order of operations for VMware VMs

1. Complete the Broadcom Platform Key remediation.
2. Reboot the VM if the platform procedure requires it.
3. Confirm the VM boots normally with Secure Boot enabled.
4. Run this PowerShell script.

---

## What the Script Does

### 1. Inspects Secure Boot update state

The script checks for:

- Secure Boot availability and enablement
- relevant registry values under:
  - `HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot`
  - `HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing`
- presence of the scheduled task:
  - `\Microsoft\Windows\PI\Secure-Boot-Update`
- recent Secure Boot related event log entries
- Boot Manager signing evidence
- whether KEK and DB already contain 2023 CA entries

### 2. Triggers the Microsoft-managed update workflow

In **Apply mode**, the script sets:

- `MicrosoftUpdateManagedOptIn = 1`
- `AvailableUpdates = 0x5944`

It then starts:

- `\Microsoft\Windows\PI\Secure-Boot-Update`

### 3. Handles reboot continuation

If the Boot Manager update stage requires a reboot, the script can:

- register a continuation command in `RunOnce`,
- resume validation with `-ContinueAfterReboot`,
- reboot automatically unless `-NoReboot` is used.

### 4. Writes operational logs

The script writes data to:

```text
%ProgramData%\SecureBootCA2023
```

Primary files:

```text
%ProgramData%\SecureBootCA2023\Invoke-SecureBootCA2023Update.log
%ProgramData%\SecureBootCA2023\state.json
```

---

## Requirements

### Mandatory

- Windows PowerShell running **as Administrator**
- UEFI firmware
- Secure Boot enabled
- Windows servicing components required for Secure Boot certificate servicing
- scheduled task present:

```text
\Microsoft\Windows\PI\Secure-Boot-Update
```

### Recommended

- current cumulative updates installed
- console or out-of-band access for recovery scenarios
- tested reboot window
- snapshot or backup before changing production systems

---

## Parameters

| Parameter | Purpose |
|---|---|
| `-Check` | Inspection only. No configuration changes are made. |
| `-Apply` | Triggers the Microsoft-managed Secure Boot CA 2023 workflow. |
| `-ContinueAfterReboot` | Continues post-reboot validation. |
| `-NoReboot` | Prevents automatic restart during Apply mode. |

### Reboot handling

The only reboot-control switch exposed by the script is:

```powershell
-NoReboot
```

Use it when you want the script to stage the workflow without forcing an immediate reboot.

---

## Execution

### Open an elevated PowerShell session

Run PowerShell **as Administrator**.

### Change to the script folder

```powershell
cd C:\Path\To\Script
```

### Check current status

```powershell
.\Invoke-SecureBootCA2023Update.ps1 -Check
```

### Apply the update workflow

```powershell
.\Invoke-SecureBootCA2023Update.ps1 -Apply
```

### Apply the workflow without automatic reboot

```powershell
.\Invoke-SecureBootCA2023Update.ps1 -Apply -NoReboot
```

---

## Recommended Change Workflow

### Physical or non-VMware systems

1. Confirm UEFI and Secure Boot are enabled.
2. Run the script in `-Check` mode.
3. Review current status and event output.
4. Run the script in `-Apply` mode.
5. Reboot if required.
6. Re-run `-Check` mode to confirm completion.

### VMware Windows VMs

1. Complete the Broadcom Platform Key remediation first.
2. Reboot if required by the Broadcom process.
3. Run `-Check` mode.
4. Run `-Apply -NoReboot` if you want to control restart timing manually.
5. Reboot during the approved maintenance window.
6. Re-run `-Check` mode and verify events.

---

## Verification

### Registry

Review:

```text
HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot
HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing
```

### Scheduled task

Confirm the task exists:

```text
\Microsoft\Windows\PI\Secure-Boot-Update
```

### Log output

Review:

```text
C:\ProgramData\SecureBootCA2023\Invoke-SecureBootCA2023Update.log
```

### Event Viewer

Check Secure Boot related events and servicing results after execution.

Microsoft’s Secure Boot guidance and event documentation remain the authoritative source for interpreting the update sequence and related Secure Boot servicing behavior. citeturn391804search2turn391804search0

---

## Troubleshooting

### Script reports Secure Boot is unavailable or disabled

Verify that:

- the system is installed in UEFI mode,
- Secure Boot is enabled in firmware,
- the platform is actually in scope for this process.

### Scheduled task is missing

If `\Microsoft\Windows\PI\Secure-Boot-Update` does not exist, the required Windows servicing components are not available on that system or the system is not yet at the required update state.

### VMware VM does not update correctly

Stop and complete the Broadcom remediation first. Running Windows-level automation against a broken platform key state is just structured disappointment.

### Reboot is required but must be controlled manually

Use:

```powershell
.\Invoke-SecureBootCA2023Update.ps1 -Apply -NoReboot
```

### Older Windows versions

Windows Server 2016 and lower are not supported by this README. Do not treat this document as deployment guidance for those platforms.

---

## Repository Layout

```text
.
├── Invoke-SecureBootCA2023Update.ps1
├── README.md
└── assets
    └── securebootca2023-banner-v2.svg
```

---

## Summary

Use this script on supported Windows systems to inspect and apply the Microsoft-managed Secure Boot CA 2023 update workflow.

For VMware Windows VMs, complete the Broadcom Secure Boot variable remediation first.

For official planning and implementation guidance, use the Microsoft support articles and Tech Community post linked above.

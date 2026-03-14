#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$ContinueAfterReboot,
    [switch]$NoReboot,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

# -------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------
$TaskName          = '\Microsoft\Windows\PI\Secure-Boot-Update'
$StateRoot         = 'C:\ProgramData\SecureBootCA2023'
$StateFile         = Join-Path $StateRoot 'state.json'
$LogFile           = Join-Path $StateRoot 'SecureBootCA2023.log'
$BitLockerFile     = Join-Path $StateRoot 'BitLocker-Protectors.txt'
$TranscriptFile    = Join-Path $StateRoot 'Transcript.txt'
$EfiMount          = 'S:'
$BootCopy          = 'C:\bootmgfw_2023.efi'
$RunOnceName       = 'SecureBootCA2023Continue'
$ThisScript        = $MyInvocation.MyCommand.Path

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level = 'INFO'
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line

    if (-not (Test-Path $StateRoot)) {
        New-Item -Path $StateRoot -ItemType Directory -Force | Out-Null
    }

    Add-Content -Path $LogFile -Value $line
}

function Ensure-StateRoot {
    if (-not (Test-Path $StateRoot)) {
        New-Item -Path $StateRoot -ItemType Directory -Force | Out-Null
    }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Admin {
    if (-not (Test-IsAdmin)) {
        throw 'This script must be run as Administrator.'
    }
}

function Save-State {
    param(
        [Parameter(Mandatory)]
        [int]$Stage,

        [Parameter(Mandatory)]
        [string]$LastAction
    )

    $obj = [pscustomobject]@{
        Stage             = $Stage
        LastAction        = $LastAction
        UpdatedAt         = (Get-Date).ToString('o')
        ScriptPath        = $ThisScript
        ComputerName      = $env:COMPUTERNAME
        ContinueAfterBoot = $true
    }

    $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
}

function Load-State {
    if (-not (Test-Path $StateFile)) {
        return [pscustomobject]@{
            Stage             = 0
            LastAction        = 'Initial'
            UpdatedAt         = $null
            ScriptPath        = $ThisScript
            ComputerName      = $env:COMPUTERNAME
            ContinueAfterBoot = $false
        }
    }

    return (Get-Content -Path $StateFile -Raw | ConvertFrom-Json)
}

function Remove-State {
    if (Test-Path $StateFile) {
        Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue
    }
}

function Register-Continuation {
    if (-not $ThisScript -or -not (Test-Path $ThisScript)) {
        throw "Cannot register continuation because the script path is not valid: $ThisScript"
    }

    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ThisScript`" -ContinueAfterReboot"

    New-ItemProperty `
        -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce' `
        -Name $RunOnceName `
        -PropertyType String `
        -Value $cmd `
        -Force | Out-Null

    Write-Log "Registered RunOnce continuation: $cmd"
}

function Unregister-Continuation {
    Remove-ItemProperty `
        -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce' `
        -Name $RunOnceName `
        -ErrorAction SilentlyContinue
}

function Restart-Now {
    param(
        [Parameter(Mandatory)]
        [string]$Reason
    )

    Write-Log "Restart requested: $Reason" 'WARN'

    if ($NoReboot) {
        Write-Log "NoReboot specified. Restart skipped." 'WARN'
        return
    }

    Restart-Computer -Force
    exit 0
}

function Get-ServicingState {
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing'

    if (-not (Test-Path $path)) {
        return [pscustomobject]@{
            WindowsUEFICA2023Capable = $null
            UEFICA2023Status         = $null
            UEFICA2023Error          = $null
            UEFICA2023ErrorHex       = $null
        }
    }

    $p = Get-ItemProperty -Path $path

    [pscustomobject]@{
        WindowsUEFICA2023Capable = $p.WindowsUEFICA2023Capable
        UEFICA2023Status         = $p.UEFICA2023Status
        UEFICA2023Error          = $p.UEFICA2023Error
        UEFICA2023ErrorHex       = if ($null -ne $p.UEFICA2023Error) { ('0x{0:X}' -f $p.UEFICA2023Error) } else { $null }
    }
}

function Test-DbContainsCA2023 {
    try {
        $db = Get-SecureBootUEFI -Name db -ErrorAction Stop
        if (-not $db -or -not $db.Bytes) {
            return $false
        }

        $ascii = [System.Text.Encoding]::ASCII.GetString($db.Bytes)
        return ($ascii -match 'Windows UEFI CA 2023')
    }
    catch {
        Write-Log "Failed to read Secure Boot DB: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Test-SecureBootTask {
    try {
        $task = Get-ScheduledTask -TaskPath '\Microsoft\Windows\PI\' -TaskName 'Secure-Boot-Update' -ErrorAction Stop
        return ($null -ne $task)
    }
    catch {
        return $false
    }
}

function Start-SecureBootTask {
    if (-not (Test-SecureBootTask)) {
        throw "Scheduled task $TaskName was not found."
    }

    Write-Log "Starting scheduled task $TaskName"
    Start-ScheduledTask -TaskName $TaskName
}

function Set-AvailableUpdates {
    param(
        [Parameter(Mandatory)]
        [int]$Value
    )

    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot'
    Write-Log ("Setting AvailableUpdates to 0x{0:X}" -f $Value)
    Set-ItemProperty -Path $path -Name 'AvailableUpdates' -Value $Value -Type DWord
}

function Backup-BitLockerInfo {
    Write-Log "Backing up BitLocker protector information to $BitLockerFile"

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("===== BitLocker Backup Info =====")
    $lines.Add("Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add("Computer: $env:COMPUTERNAME")
    $lines.Add("SystemDrive: $env:SystemDrive")
    $lines.Add("")

    $manageBdePaths = @(
        "$env:SystemRoot\System32\manage-bde.exe",
        "$env:SystemRoot\Sysnative\manage-bde.exe"
    )

    $manageBde = $manageBdePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($manageBde) {
        try {
            $lines.Add("===== manage-bde -protectors -get $env:SystemDrive =====")
            $output = & $manageBde -protectors -get $env:SystemDrive 2>&1 | Out-String
            $lines.Add($output.TrimEnd())
            $lines.Add("")
            Write-Log "BitLocker protector information collected with manage-bde."
        }
        catch {
            $lines.Add("manage-bde failed: $($_.Exception.Message)")
            $lines.Add("")
            Write-Log "manage-bde failed: $($_.Exception.Message)" 'WARN'
        }
    }
    else {
        $lines.Add("manage-bde.exe not found on this system.")
        $lines.Add("")
        Write-Log "manage-bde.exe not found on this system." 'WARN'
    }

    try {
        $bitLockerCmdlet = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
        if ($bitLockerCmdlet) {
            $lines.Add("===== Get-BitLockerVolume =====")
            $blv = Get-BitLockerVolume | Format-List * | Out-String
            $lines.Add($blv.TrimEnd())
            $lines.Add("")
            Write-Log "BitLocker volume information collected with Get-BitLockerVolume."
        }
        else {
            $lines.Add("Get-BitLockerVolume cmdlet not available on this system.")
            $lines.Add("")
            Write-Log "Get-BitLockerVolume cmdlet not available on this system." 'WARN'
        }
    }
    catch {
        $lines.Add("Get-BitLockerVolume failed: $($_.Exception.Message)")
        $lines.Add("")
        Write-Log "Get-BitLockerVolume failed: $($_.Exception.Message)" 'WARN'
    }

    $lines | Set-Content -Path $BitLockerFile -Encoding UTF8
}

function Mount-EfiPartition {
    Write-Log "Mounting EFI partition to $EfiMount"
    cmd.exe /c "mountvol $EfiMount /S" | Out-Null
}

function Dismount-EfiPartition {
    Write-Log "Dismounting EFI partition from $EfiMount"
    try {
        cmd.exe /c "mountvol $EfiMount /D" | Out-Null
    }
    catch {
        Write-Log "Failed to dismount EFI partition: $($_.Exception.Message)" 'WARN'
    }
}

function Copy-BootManager {
    $source = Join-Path $EfiMount 'EFI\Microsoft\Boot\bootmgfw.efi'

    if (-not (Test-Path $source)) {
        throw "EFI boot manager not found at $source"
    }

    Write-Log "Copying $source to $BootCopy"
    Copy-Item -Path $source -Destination $BootCopy -Force
}

function Test-BootManagerCertChain {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )

    if (-not (Test-Path $FilePath)) {
        Write-Log "Boot manager copy not found: $FilePath" 'WARN'
        return $false
    }

    try {
        $sig = Get-AuthenticodeSignature -FilePath $FilePath
        if ($sig.Status -ne 'Valid') {
            Write-Log "Authenticode signature status is $($sig.Status) for $FilePath" 'WARN'
        }

        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($FilePath)
        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        [void]$chain.Build($cert)

        $subjects = @($chain.ChainElements | ForEach-Object { $_.Certificate.Subject })
        $joined = $subjects -join ' | '
        Write-Log "Boot manager certificate chain: $joined"

        return ($joined -match 'Windows UEFI CA 2023')
    }
    catch {
        Write-Log "Failed to inspect boot manager certificate chain: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Show-CurrentStatus {
    $state = Get-ServicingState
    Write-Log ("Servicing state: Capable={0}, Status={1}, Error={2}" -f `
        $state.WindowsUEFICA2023Capable,
        $state.UEFICA2023Status,
        $state.UEFICA2023ErrorHex)

    $dbHas2023 = Test-DbContainsCA2023
    Write-Log "Secure Boot DB contains 'Windows UEFI CA 2023': $dbHas2023"
}

function Get-ComplianceState {
    $secureBootEnabled = $false
    $dbHas2023 = $false
    $bootMgrHas2023 = $false
    $taskExists = $false
    $needsUpdate = $true
    $reason = @()

    try {
        $secureBootEnabled = [bool](Confirm-SecureBootUEFI)
    }
    catch {
        $reason += "Secure Boot is not enabled or cannot be queried."
    }

    $taskExists = Test-SecureBootTask
    if (-not $taskExists) {
        $reason += "Scheduled task $TaskName not found."
    }

    $serv = Get-ServicingState
    $dbHas2023 = Test-DbContainsCA2023

    try {
        Mount-EfiPartition
        try {
            Copy-BootManager
        }
        finally {
            Dismount-EfiPartition
        }

        $bootMgrHas2023 = Test-BootManagerCertChain -FilePath $BootCopy
    }
    catch {
        $reason += "Boot manager inspection failed: $($_.Exception.Message)"
    }

    if (-not $secureBootEnabled) {
        $needsUpdate = $false
        $reason += "Host is not eligible because Secure Boot is not enabled."
    }
    elseif ($dbHas2023 -and $bootMgrHas2023) {
        $needsUpdate = $false
        $reason += "DB and boot manager already trust Windows UEFI CA 2023."
    }
    else {
        $needsUpdate = $true

        if (-not $dbHas2023) {
            $reason += "Secure Boot DB does not contain Windows UEFI CA 2023."
        }

        if (-not $bootMgrHas2023) {
            $reason += "Boot manager is not signed through Windows UEFI CA 2023."
        }
    }

    [pscustomobject]@{
        SecureBootEnabled        = $secureBootEnabled
        ScheduledTaskExists      = $taskExists
        WindowsUEFICA2023Capable = $serv.WindowsUEFICA2023Capable
        UEFICA2023Status         = $serv.UEFICA2023Status
        UEFICA2023ErrorHex       = $serv.UEFICA2023ErrorHex
        DbContainsCA2023         = $dbHas2023
        BootManagerHasCA2023     = $bootMgrHas2023
        NeedsUpdate              = $needsUpdate
        Reason                   = ($reason -join ' ')
    }
}

function Get-FinalSummary {
    $serv = Get-ServicingState
    $dbHas2023 = $false
    $bootMgrHas2023 = $false
    $taskExists = $false
    $secureBootEnabled = $false
    $reasons = @()

    try {
        $secureBootEnabled = [bool](Confirm-SecureBootUEFI)
    }
    catch {
        $reasons += "Secure Boot could not be queried."
    }

    try {
        $taskExists = Test-SecureBootTask
    }
    catch {
        $reasons += "Scheduled task status could not be determined."
    }

    try {
        $dbHas2023 = Test-DbContainsCA2023
    }
    catch {
        $reasons += "Secure Boot DB could not be checked."
    }

    try {
        Mount-EfiPartition
        try {
            Copy-BootManager
        }
        finally {
            Dismount-EfiPartition
        }

        $bootMgrHas2023 = Test-BootManagerCertChain -FilePath $BootCopy
    }
    catch {
        $reasons += "Boot manager certificate chain could not be checked: $($_.Exception.Message)"
    }

    $completed = $false
    if ($secureBootEnabled -and $dbHas2023 -and $bootMgrHas2023) {
        $completed = $true
    }

    [pscustomobject]@{
        SecureBootEnabled        = $secureBootEnabled
        ScheduledTaskExists      = $taskExists
        WindowsUEFICA2023Capable = $serv.WindowsUEFICA2023Capable
        UEFICA2023Status         = $serv.UEFICA2023Status
        UEFICA2023ErrorHex       = $serv.UEFICA2023ErrorHex
        DbContainsCA2023         = $dbHas2023
        BootManagerHasCA2023     = $bootMgrHas2023
        Completed                = $completed
        Notes                    = ($reasons -join ' ')
    }
}

function Write-FinalSummary {
    param(
        [Parameter(Mandatory)]
        [psobject]$Summary
    )

    Write-Log "================ FINAL SUMMARY ================"
    Write-Log "SecureBootEnabled        : $($Summary.SecureBootEnabled)"
    Write-Log "ScheduledTaskExists      : $($Summary.ScheduledTaskExists)"
    Write-Log "WindowsUEFICA2023Capable : $($Summary.WindowsUEFICA2023Capable)"
    Write-Log "UEFICA2023Status         : $($Summary.UEFICA2023Status)"
    Write-Log "UEFICA2023ErrorHex       : $($Summary.UEFICA2023ErrorHex)"
    Write-Log "DbContainsCA2023         : $($Summary.DbContainsCA2023)"
    Write-Log "BootManagerHasCA2023     : $($Summary.BootManagerHasCA2023)"
    Write-Log "Completed                : $($Summary.Completed)"

    if ($Summary.Notes) {
        Write-Log "Notes                    : $($Summary.Notes)" 'WARN'
    }

    if ($Summary.Completed) {
        Write-Log "SCRIPT FINISHED SUCCESSFULLY." 'INFO'
    }
    else {
        Write-Log "SCRIPT FINISHED, BUT THE HOST IS NOT FULLY COMPLIANT YET." 'WARN'
    }

    Write-Log "=============================================="
}

function Cleanup-CompletionState {
    Unregister-Continuation
    Remove-State
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
Ensure-StateRoot
Start-Transcript -Path $TranscriptFile -Append | Out-Null

try {
    Require-Admin

    if ($Check) {
        Write-Log "Running in CHECK mode"

        $compliance = Get-ComplianceState

        Write-Log "================ CHECK SUMMARY ================"
        Write-Log "SecureBootEnabled        : $($compliance.SecureBootEnabled)"
        Write-Log "ScheduledTaskExists      : $($compliance.ScheduledTaskExists)"
        Write-Log "WindowsUEFICA2023Capable : $($compliance.WindowsUEFICA2023Capable)"
        Write-Log "UEFICA2023Status         : $($compliance.UEFICA2023Status)"
        Write-Log "UEFICA2023ErrorHex       : $($compliance.UEFICA2023ErrorHex)"
        Write-Log "DbContainsCA2023         : $($compliance.DbContainsCA2023)"
        Write-Log "BootManagerHasCA2023     : $($compliance.BootManagerHasCA2023)"
        Write-Log "NeedsUpdate              : $($compliance.NeedsUpdate)"
        Write-Log "Reason                   : $($compliance.Reason)"
        Write-Log "=============================================="

        if ($compliance.NeedsUpdate) {
            Write-Log "CHECK FINISHED: Host needs update." 'WARN'
            exit 1
        }
        else {
            Write-Log "CHECK FINISHED: Host does not need update." 'INFO'
            exit 0
        }
    }

    Write-Log "Starting Secure Boot CA 2023 automation"
    Write-Log "Script path: $ThisScript"
    Show-CurrentStatus

    $state = Load-State
    $stage = [int]$state.Stage

    switch ($stage) {
        0 {
            Write-Log "Stage 0: Pre-checks and update decision"

            try {
                if (-not (Confirm-SecureBootUEFI)) {
                    throw 'Secure Boot is not enabled on this system.'
                }
            }
            catch {
                throw 'Secure Boot is not enabled on this system or cannot be queried.'
            }

            if (-not (Test-SecureBootTask)) {
                throw "Scheduled task $TaskName does not exist. Aborting."
            }

            Backup-BitLockerInfo

            $dbHas2023 = Test-DbContainsCA2023
            $bootMgrHas2023 = $false

            try {
                Mount-EfiPartition
                try {
                    Copy-BootManager
                }
                finally {
                    Dismount-EfiPartition
                }

                $bootMgrHas2023 = Test-BootManagerCertChain -FilePath $BootCopy
            }
            catch {
                Write-Log "Boot manager pre-check failed: $($_.Exception.Message)" 'WARN'
            }

            if ($dbHas2023 -and $bootMgrHas2023) {
                Write-Log "DB and Boot Manager already trust Windows UEFI CA 2023. No remediation needed."
                $summary = Get-FinalSummary
                Write-FinalSummary -Summary $summary
                Cleanup-CompletionState
                exit 0
            }

            if (-not $dbHas2023) {
                Set-AvailableUpdates -Value 0x40
                Start-SecureBootTask
                Write-Log "Triggered DB update."

                Register-Continuation
                Save-State -Stage 1 -LastAction 'DB update triggered, rebooting to validate'
                Restart-Now -Reason 'Reboot 1 after DB update trigger'
            }
            else {
                Write-Log "DB already contains Windows UEFI CA 2023. Skipping DB apply and moving to Boot Manager update."

                Set-AvailableUpdates -Value 0x100
                Start-SecureBootTask
                Write-Log "Triggered Boot Manager update."

                Register-Continuation
                Save-State -Stage 2 -LastAction 'Boot manager update triggered, rebooting to validate'
                Restart-Now -Reason 'Reboot after Boot Manager update trigger'
            }
        }

        1 {
            Write-Log "Stage 1: Validate DB update after reboot"

            $dbHas2023 = Test-DbContainsCA2023
            if (-not $dbHas2023) {
                $serv = Get-ServicingState
                Write-Log ("DB does not yet show CA 2023. Current state: Capable={0}, Status={1}, Error={2}" -f `
                    $serv.WindowsUEFICA2023Capable, $serv.UEFICA2023Status, $serv.UEFICA2023ErrorHex) 'WARN'
                throw 'DB update did not validate after reboot. Review the log before proceeding.'
            }

            Write-Log "DB update validated successfully."

            Set-AvailableUpdates -Value 0x100
            Start-SecureBootTask
            Write-Log "Triggered Boot Manager update."

            Register-Continuation
            Save-State -Stage 2 -LastAction 'Boot manager update triggered, rebooting to validate'
            Restart-Now -Reason 'Reboot after Boot Manager update trigger'
        }

        2 {
            Write-Log "Stage 2: Validate Boot Manager after reboot"

            Mount-EfiPartition
            try {
                Copy-BootManager
            }
            finally {
                Dismount-EfiPartition
            }

            $bootOk = Test-BootManagerCertChain -FilePath $BootCopy
            if (-not $bootOk) {
                throw "Boot Manager certificate chain does not include 'Windows UEFI CA 2023'."
            }

            Write-Log "Boot Manager certificate chain includes 'Windows UEFI CA 2023'."

            Register-Continuation
            Save-State -Stage 3 -LastAction 'Boot manager validated, performing additional confirmation reboot'
            Restart-Now -Reason 'Additional confirmation reboot'
        }

        3 {
            Write-Log "Stage 3: Final post-reboot confirmation"

            $summary = Get-FinalSummary
            Write-FinalSummary -Summary $summary

            if ($summary.Completed) {
                Save-State -Stage 4 -LastAction 'Completed successfully'
                Cleanup-CompletionState
                exit 0
            }
            else {
                throw "Final validation failed. DbContainsCA2023=$($summary.DbContainsCA2023) BootManagerHasCA2023=$($summary.BootManagerHasCA2023)"
            }
        }

        default {
            Write-Log "Unknown or completed stage value: $stage" 'WARN'
            $summary = Get-FinalSummary
            Write-FinalSummary -Summary $summary

            if ($summary.Completed) {
                Cleanup-CompletionState
                exit 0
            }
            else {
                exit 1
            }
        }
    }
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)" 'ERROR'

    try {
        $summary = Get-FinalSummary
        Write-FinalSummary -Summary $summary
    }
    catch {
        Write-Log "Failed to build final summary: $($_.Exception.Message)" 'WARN'
    }

    if ($Check) {
        exit 2
    }

    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
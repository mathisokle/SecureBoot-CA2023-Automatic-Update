#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$ContinueAfterReboot,
    [switch]$NoReboot,
    [switch]$Check,
    [switch]$ResetState,
    [switch]$DebugSecureBootAscii,
    [switch]$ForceRetryKek
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
$RunOnceName       = 'SecureBootCA2023Continue'
$ThisScript        = $MyInvocation.MyCommand.Path
$TempBootCopyRoot  = Join-Path $env:TEMP 'SecureBootCA2023'
$MaxKekRetries     = 2

# Update flags
$UpdateFlagKEK     = 0x0004
$UpdateFlagDB      = 0x0040
$UpdateFlagBootMgr = 0x0100

# Stage map
$StageInitial            = 0
$StageValidateKEK        = 1
$StageValidateDB         = 2
$StageValidateBootMgr    = 3
$StageFinalConfirmation  = 4

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

    if (-not (Test-Path $TempBootCopyRoot)) {
        New-Item -Path $TempBootCopyRoot -ItemType Directory -Force | Out-Null
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
        [string]$LastAction,

        [int]$RetryCount = 0
    )

    $obj = [pscustomobject]@{
        Stage             = $Stage
        LastAction        = $LastAction
        RetryCount        = $RetryCount
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
            Stage             = $StageInitial
            LastAction        = 'Initial'
            RetryCount        = 0
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

function Cleanup-CompletionState {
    Unregister-Continuation
    Remove-State
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

function Get-SecureBootTextRepresentations {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('PK','KEK','db','dbx')]
        [string]$Name
    )

    try {
        $obj = Get-SecureBootUEFI -Name $Name -ErrorAction Stop
        if (-not $obj -or -not $obj.Bytes) {
            return $null
        }

        $bytes = $obj.Bytes

        $ascii   = [System.Text.Encoding]::ASCII.GetString($bytes)
        $unicode = [System.Text.Encoding]::Unicode.GetString($bytes)
        $utf8    = [System.Text.Encoding]::UTF8.GetString($bytes)

        [pscustomobject]@{
            Ascii   = $ascii
            Unicode = $unicode
            Utf8    = $utf8
            Joined  = ($ascii + "`n" + $unicode + "`n" + $utf8)
        }
    }
    catch {
        Write-Log "Failed to read Secure Boot variable '$Name': $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Show-SecureBootAsciiPreview {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('PK','KEK','db','dbx')]
        [string]$Name
    )

    $text = Get-SecureBootTextRepresentations -Name $Name
    if (-not $text) {
        Write-Log "No readable text data found for Secure Boot variable '$Name'." 'WARN'
        return
    }

    $previewLength = 500

    $asciiPreview   = $text.Ascii.Substring(0, [Math]::Min($previewLength, $text.Ascii.Length))
    $unicodePreview = $text.Unicode.Substring(0, [Math]::Min($previewLength, $text.Unicode.Length))
    $utf8Preview    = $text.Utf8.Substring(0, [Math]::Min($previewLength, $text.Utf8.Length))

    Write-Log "ASCII preview for ${Name}: $asciiPreview"
    Write-Log "Unicode preview for ${Name}: $unicodePreview"
    Write-Log "UTF8 preview for ${Name}: $utf8Preview"
}

function Test-KekContainsCA2023 {
    $text = Get-SecureBootTextRepresentations -Name 'KEK'
    if (-not $text) {
        return $false
    }

    if ($DebugSecureBootAscii) {
        $previewLength = 400

        $asciiPreview   = $text.Ascii.Substring(0, [Math]::Min($previewLength, $text.Ascii.Length))
        $unicodePreview = $text.Unicode.Substring(0, [Math]::Min($previewLength, $text.Unicode.Length))
        $utf8Preview    = $text.Utf8.Substring(0, [Math]::Min($previewLength, $text.Utf8.Length))

        Write-Log "Secure Boot KEK ASCII preview: $asciiPreview"
        Write-Log "Secure Boot KEK Unicode preview: $unicodePreview"
        Write-Log "Secure Boot KEK UTF8 preview: $utf8Preview"
    }

    $joined = $text.Joined

    return (
        $joined -match 'Microsoft Corporation KEK\s*2K\s*CA\s*2023' -or
        $joined -match 'KEK\s*2K\s*CA\s*2023' -or
        ($joined -match 'Microsoft' -and $joined -match 'KEK' -and $joined -match '2023')
    )
}

function Test-DbContainsCA2023 {
    $text = Get-SecureBootTextRepresentations -Name 'db'
    if (-not $text) {
        return $false
    }

    if ($DebugSecureBootAscii) {
        $previewLength = 400

        $asciiPreview   = $text.Ascii.Substring(0, [Math]::Min($previewLength, $text.Ascii.Length))
        $unicodePreview = $text.Unicode.Substring(0, [Math]::Min($previewLength, $text.Unicode.Length))
        $utf8Preview    = $text.Utf8.Substring(0, [Math]::Min($previewLength, $text.Utf8.Length))

        Write-Log "Secure Boot DB ASCII preview: $asciiPreview"
        Write-Log "Secure Boot DB Unicode preview: $unicodePreview"
        Write-Log "Secure Boot DB UTF8 preview: $utf8Preview"
    }

    return ($text.Joined -match 'Windows UEFI CA 2023')
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

function Get-TempBootCopyPath {
    if (-not (Test-Path $TempBootCopyRoot)) {
        New-Item -Path $TempBootCopyRoot -ItemType Directory -Force | Out-Null
    }

    return (Join-Path $TempBootCopyRoot ("bootmgfw_{0}_{1}.efi" -f $env:COMPUTERNAME, [guid]::NewGuid().ToString('N')))
}

function Copy-BootManager {
    $source = Join-Path $EfiMount 'EFI\Microsoft\Boot\bootmgfw.efi'

    if (-not (Test-Path $source)) {
        throw "EFI boot manager not found at $source"
    }

    $destination = Get-TempBootCopyPath
    Write-Log "Copying $source to $destination"
    Copy-Item -Path $source -Destination $destination -Force

    return $destination
}

function Remove-BootManagerCopy {
    param(
        [string]$FilePath
    )

    if ($FilePath -and (Test-Path $FilePath)) {
        Remove-Item -Path $FilePath -Force -ErrorAction SilentlyContinue
    }
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

function Get-BootManagerHasCA2023 {
    $bootCopy = $null
    try {
        Mount-EfiPartition
        try {
            $bootCopy = Copy-BootManager
        }
        finally {
            Dismount-EfiPartition
        }

        return (Test-BootManagerCertChain -FilePath $bootCopy)
    }
    finally {
        Remove-BootManagerCopy -FilePath $bootCopy
    }
}

function Show-CurrentStatus {
    $state = Get-ServicingState
    Write-Log ("Servicing state: Capable={0}, Status={1}, Error={2}" -f `
        $state.WindowsUEFICA2023Capable,
        $state.UEFICA2023Status,
        $state.UEFICA2023ErrorHex)

    $kekHas2023 = Test-KekContainsCA2023
    $dbHas2023  = Test-DbContainsCA2023

    Write-Log "Secure Boot KEK contains 2023 CA: $kekHas2023"
    Write-Log "Secure Boot DB contains 'Windows UEFI CA 2023': $dbHas2023"
}

function Test-IsKekStuck {
    $serv = Get-ServicingState

    return (
        -not (Test-KekContainsCA2023) -and
        $serv.UEFICA2023Status -eq 'InProgress' -and
        (
            $serv.UEFICA2023ErrorHex -eq '0x800703E6' -or
            $serv.UEFICA2023ErrorHex -eq '0x8007015E'
        )
    )
}

function Get-ComplianceState {
    $secureBootEnabled = $false
    $kekHas2023 = $false
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
    $kekHas2023 = Test-KekContainsCA2023
    $dbHas2023  = Test-DbContainsCA2023

    try {
        $bootMgrHas2023 = Get-BootManagerHasCA2023
    }
    catch {
        $reason += "Boot manager inspection failed: $($_.Exception.Message)"
    }

    if (-not $secureBootEnabled) {
        $needsUpdate = $false
        $reason += "Host is not eligible because Secure Boot is not enabled."
    }
    elseif ($kekHas2023 -and $dbHas2023 -and $bootMgrHas2023) {
        $needsUpdate = $false
        $reason += "KEK, DB, and boot manager already trust Windows UEFI CA 2023."
    }
    else {
        $needsUpdate = $true

        if (-not $kekHas2023) {
            $reason += "Secure Boot KEK does not contain 2023 CA."
        }

        if (-not $dbHas2023) {
            $reason += "Secure Boot DB does not contain Windows UEFI CA 2023."
        }

        if (-not $bootMgrHas2023) {
            $reason += "Boot manager is not signed through Windows UEFI CA 2023."
        }

        if (Test-IsKekStuck) {
            $reason += "KEK update appears stuck in firmware/platform state."
        }
    }

    [pscustomobject]@{
        SecureBootEnabled        = $secureBootEnabled
        ScheduledTaskExists      = $taskExists
        WindowsUEFICA2023Capable = $serv.WindowsUEFICA2023Capable
        UEFICA2023Status         = $serv.UEFICA2023Status
        UEFICA2023ErrorHex       = $serv.UEFICA2023ErrorHex
        KekContainsCA2023        = $kekHas2023
        DbContainsCA2023         = $dbHas2023
        BootManagerHasCA2023     = $bootMgrHas2023
        NeedsUpdate              = $needsUpdate
        Reason                   = ($reason -join ' ')
    }
}

function Get-FinalSummary {
    $serv = Get-ServicingState
    $kekHas2023 = $false
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
        $kekHas2023 = Test-KekContainsCA2023
    }
    catch {
        $reasons += "Secure Boot KEK could not be checked."
    }

    try {
        $dbHas2023 = Test-DbContainsCA2023
    }
    catch {
        $reasons += "Secure Boot DB could not be checked."
    }

    try {
        $bootMgrHas2023 = Get-BootManagerHasCA2023
    }
    catch {
        $reasons += "Boot manager certificate chain could not be checked: $($_.Exception.Message)"
    }

    if (Test-IsKekStuck) {
        $reasons += "KEK update appears stuck in firmware/platform state."
    }

    $completed = $false
    if ($secureBootEnabled -and $kekHas2023 -and $dbHas2023 -and $bootMgrHas2023) {
        $completed = $true
    }

    [pscustomobject]@{
        SecureBootEnabled        = $secureBootEnabled
        ScheduledTaskExists      = $taskExists
        WindowsUEFICA2023Capable = $serv.WindowsUEFICA2023Capable
        UEFICA2023Status         = $serv.UEFICA2023Status
        UEFICA2023ErrorHex       = $serv.UEFICA2023ErrorHex
        KekContainsCA2023        = $kekHas2023
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
    Write-Log "KekContainsCA2023        : $($Summary.KekContainsCA2023)"
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

function Invoke-UpdatePhase {
    param(
        [Parameter(Mandatory)]
        [int]$Flag,

        [Parameter(Mandatory)]
        [int]$NextStage,

        [Parameter(Mandatory)]
        [string]$ActionMessage,

        [Parameter(Mandatory)]
        [string]$RebootReason
    )

    Set-AvailableUpdates -Value $Flag
    Start-SecureBootTask
    Write-Log $ActionMessage

    Register-Continuation
    Save-State -Stage $NextStage -LastAction $ActionMessage -RetryCount 0

    if ($NoReboot) {
        Write-Log "NoReboot specified. Workflow paused after staging update. Re-run with -ContinueAfterReboot after a manual reboot." 'WARN'
        exit 0
    }

    Restart-Now -Reason $RebootReason
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
Ensure-StateRoot
$transcriptStarted = $false

try {
    Start-Transcript -Path $TranscriptFile -Append | Out-Null
    $transcriptStarted = $true
}
catch {
    Write-Host "Transcript could not be started: $($_.Exception.Message)"
}

try {
    Require-Admin

    if ($ResetState) {
        Write-Log "ResetState specified. Clearing saved workflow state."
        Cleanup-CompletionState
    }

    if ($DebugSecureBootAscii) {
        Write-Log "DebugSecureBootAscii specified. Showing Secure Boot variable previews."
        Show-SecureBootAsciiPreview -Name 'KEK'
        Show-SecureBootAsciiPreview -Name 'db'
    }

    if ($Check) {
        Write-Log "Running in CHECK mode"

        $compliance = Get-ComplianceState

        Write-Log "================ CHECK SUMMARY ================"
        Write-Log "SecureBootEnabled        : $($compliance.SecureBootEnabled)"
        Write-Log "ScheduledTaskExists      : $($compliance.ScheduledTaskExists)"
        Write-Log "WindowsUEFICA2023Capable : $($compliance.WindowsUEFICA2023Capable)"
        Write-Log "UEFICA2023Status         : $($compliance.UEFICA2023Status)"
        Write-Log "UEFICA2023ErrorHex       : $($compliance.UEFICA2023ErrorHex)"
        Write-Log "KekContainsCA2023        : $($compliance.KekContainsCA2023)"
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

    if ($ContinueAfterReboot) {
        $state = Load-State
        $stage = [int]$state.Stage
        Write-Log "Continuation mode detected. Resuming at stage $stage."
    }
    else {
        $stage = $StageInitial
        Write-Log "Fresh run detected. Starting at stage 0."
    }

    switch ($stage) {
        $StageInitial {
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

            $kekHas2023 = Test-KekContainsCA2023
            $dbHas2023 = Test-DbContainsCA2023
            $bootMgrHas2023 = $false

            try {
                $bootMgrHas2023 = Get-BootManagerHasCA2023
            }
            catch {
                Write-Log "Boot manager pre-check failed: $($_.Exception.Message)" 'WARN'
            }

            if ($kekHas2023 -and $dbHas2023 -and $bootMgrHas2023) {
                Write-Log "KEK, DB and Boot Manager already trust Windows UEFI CA 2023. No remediation needed."
                $summary = Get-FinalSummary
                Write-FinalSummary -Summary $summary
                Cleanup-CompletionState
                exit 0
            }

            if (-not $kekHas2023) {
                if ((Test-IsKekStuck) -and (-not $ForceRetryKek)) {
                    Cleanup-CompletionState
                    throw 'KEK update is still InProgress with firmware/platform error state. Not retriggering KEK to avoid a reboot loop. Use -ForceRetryKek only if you explicitly want to try again anyway.'
                }

                Invoke-UpdatePhase `
                    -Flag $UpdateFlagKEK `
                    -NextStage $StageValidateKEK `
                    -ActionMessage 'Triggered KEK update.' `
                    -RebootReason 'Reboot after KEK update trigger'
            }

            if (-not $dbHas2023) {
                Invoke-UpdatePhase `
                    -Flag $UpdateFlagDB `
                    -NextStage $StageValidateDB `
                    -ActionMessage 'Triggered DB update.' `
                    -RebootReason 'Reboot after DB update trigger'
            }

            if (-not $bootMgrHas2023) {
                Invoke-UpdatePhase `
                    -Flag $UpdateFlagBootMgr `
                    -NextStage $StageValidateBootMgr `
                    -ActionMessage 'Triggered Boot Manager update.' `
                    -RebootReason 'Reboot after Boot Manager update trigger'
            }

            $summary = Get-FinalSummary
            Write-FinalSummary -Summary $summary

            if ($summary.Completed) {
                Cleanup-CompletionState
                exit 0
            }
            else {
                Cleanup-CompletionState
                throw 'No update stage was triggered, but host is still not compliant.'
            }
        }

        $StageValidateKEK {
            Write-Log "Stage 1: Validate KEK update after reboot"

            $currentState = Load-State
            $retryCount = 0
            if ($currentState.PSObject.Properties.Name -contains 'RetryCount') {
                $retryCount = [int]$currentState.RetryCount
            }

            $kekHas2023 = Test-KekContainsCA2023
            $serv = Get-ServicingState

            if ($kekHas2023) {
                Write-Log "KEK update validated successfully."

                $dbHas2023 = Test-DbContainsCA2023
                if (-not $dbHas2023) {
                    Invoke-UpdatePhase `
                        -Flag $UpdateFlagDB `
                        -NextStage $StageValidateDB `
                        -ActionMessage 'Triggered DB update.' `
                        -RebootReason 'Reboot after DB update trigger'
                }

                $bootMgrHas2023 = $false
                try {
                    $bootMgrHas2023 = Get-BootManagerHasCA2023
                }
                catch {
                    Write-Log "Boot manager validation pre-check failed: $($_.Exception.Message)" 'WARN'
                }

                if (-not $bootMgrHas2023) {
                    Invoke-UpdatePhase `
                        -Flag $UpdateFlagBootMgr `
                        -NextStage $StageValidateBootMgr `
                        -ActionMessage 'Triggered Boot Manager update.' `
                        -RebootReason 'Reboot after Boot Manager update trigger'
                }

                Register-Continuation
                Save-State -Stage $StageFinalConfirmation -LastAction 'KEK validated; proceeding to final confirmation' -RetryCount 0

                if ($NoReboot) {
                    Write-Log "NoReboot specified. Workflow paused before final confirmation reboot." 'WARN'
                    exit 0
                }

                Restart-Now -Reason 'Additional confirmation reboot after KEK validation'
            }

            Write-Log ("KEK still not detected. Current state: Capable={0}, Status={1}, Error={2}, RetryCount={3}" -f `
                $serv.WindowsUEFICA2023Capable, $serv.UEFICA2023Status, $serv.UEFICA2023ErrorHex, $retryCount) 'WARN'

            if ($serv.UEFICA2023Status -eq 'InProgress' -and $retryCount -lt $MaxKekRetries) {
                Write-Log "KEK stage still appears to be in progress. Scheduling another confirmation reboot instead of failing immediately." 'WARN'

                Register-Continuation
                Save-State -Stage $StageValidateKEK -LastAction 'Waiting for KEK update to finalize' -RetryCount ($retryCount + 1)

                if ($NoReboot) {
                    Write-Log "NoReboot specified. Workflow paused while waiting for KEK finalization. Re-run with -ContinueAfterReboot after a manual reboot." 'WARN'
                    exit 0
                }

                Restart-Now -Reason 'Additional reboot while waiting for KEK update to finalize'
            }

            Cleanup-CompletionState
            throw 'KEK update did not validate after allowed retries. This likely indicates OEM/firmware support is missing for the new Microsoft KEK on this device.'
        }

        $StageValidateDB {
            Write-Log "Stage 2: Validate DB update after reboot"

            $dbHas2023 = Test-DbContainsCA2023
            if (-not $dbHas2023) {
                $serv = Get-ServicingState
                Cleanup-CompletionState
                Write-Log ("DB does not yet show CA 2023. Current state: Capable={0}, Status={1}, Error={2}" -f `
                    $serv.WindowsUEFICA2023Capable, $serv.UEFICA2023Status, $serv.UEFICA2023ErrorHex) 'WARN'
                throw 'DB update did not validate after reboot. Workflow stopped.'
            }

            Write-Log "DB update validated successfully."

            $bootMgrHas2023 = $false
            try {
                $bootMgrHas2023 = Get-BootManagerHasCA2023
            }
            catch {
                Write-Log "Boot manager validation pre-check failed: $($_.Exception.Message)" 'WARN'
            }

            if (-not $bootMgrHas2023) {
                Invoke-UpdatePhase `
                    -Flag $UpdateFlagBootMgr `
                    -NextStage $StageValidateBootMgr `
                    -ActionMessage 'Triggered Boot Manager update.' `
                    -RebootReason 'Reboot after Boot Manager update trigger'
            }

            Register-Continuation
            Save-State -Stage $StageFinalConfirmation -LastAction 'DB validated; proceeding to final confirmation' -RetryCount 0

            if ($NoReboot) {
                Write-Log "NoReboot specified. Workflow paused before final confirmation reboot." 'WARN'
                exit 0
            }

            Restart-Now -Reason 'Additional confirmation reboot after DB validation'
        }

        $StageValidateBootMgr {
            Write-Log "Stage 3: Validate Boot Manager after reboot"

            $bootOk = Get-BootManagerHasCA2023
            if (-not $bootOk) {
                Cleanup-CompletionState
                throw "Boot Manager certificate chain does not include 'Windows UEFI CA 2023'. Workflow stopped."
            }

            Write-Log "Boot Manager certificate chain includes 'Windows UEFI CA 2023'."

            Register-Continuation
            Save-State -Stage $StageFinalConfirmation -LastAction 'Boot manager validated; performing additional confirmation reboot' -RetryCount 0

            if ($NoReboot) {
                Write-Log "NoReboot specified. Workflow paused before final confirmation reboot." 'WARN'
                exit 0
            }

            Restart-Now -Reason 'Additional confirmation reboot'
        }

        $StageFinalConfirmation {
            Write-Log "Stage 4: Final post-reboot confirmation"

            $summary = Get-FinalSummary
            Write-FinalSummary -Summary $summary

            if ($summary.Completed) {
                Save-State -Stage 99 -LastAction 'Completed successfully' -RetryCount 0
                Cleanup-CompletionState
                exit 0
            }
            else {
                Cleanup-CompletionState
                throw "Final validation failed. KekContainsCA2023=$($summary.KekContainsCA2023) DbContainsCA2023=$($summary.DbContainsCA2023) BootManagerHasCA2023=$($summary.BootManagerHasCA2023). Workflow stopped to prevent a loop."
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
                Cleanup-CompletionState
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

    Cleanup-CompletionState

    if ($Check) {
        exit 2
    }

    exit 1
}
finally {
    if ($transcriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
        }
    }
}

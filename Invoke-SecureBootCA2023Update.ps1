#Requires -RunAsAdministrator
[CmdletBinding(DefaultParameterSetName='Check')]
param(
    [Parameter(ParameterSetName='Check')]
    [switch]$Check,

    [Parameter(ParameterSetName='Apply')]
    [switch]$Apply,

    [switch]$ContinueAfterReboot,
    [switch]$NoReboot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------
# Paths / constants
# -----------------------------
$RegistryBase      = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot'
$RegistryServicing = Join-Path $RegistryBase 'Servicing'
$RunOncePath       = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$TaskPath          = '\Microsoft\Windows\PI\Secure-Boot-Update'
$WorkRoot          = Join-Path $env:ProgramData 'SecureBootCA2023'
$StateFile         = Join-Path $WorkRoot 'state.json'
$LogFile           = Join-Path $WorkRoot 'Invoke-SecureBootCA2023Update.log'

$BitAllSupported   = 0x5944
$BitBootMgrOnly    = 0x0100

# -----------------------------
# Logging
# -----------------------------
function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )

    if (-not (Test-Path -LiteralPath $WorkRoot)) {
        New-Item -Path $WorkRoot -ItemType Directory -Force | Out-Null
    }

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line
}

# -----------------------------
# Helpers
# -----------------------------
function Get-ScriptPath {
    if ($PSCommandPath) { return $PSCommandPath }
    if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
        return $MyInvocation.MyCommand.Path
    }
    return $null
}

function Get-RegValue {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name,
        $Default = $null
    )

    try {
        $item = Get-ItemProperty -Path $Path -ErrorAction Stop
        $prop = $item.PSObject.Properties[$Name]
        if ($null -ne $prop) { return $prop.Value }
        return $Default
    }
    catch {
        return $Default
    }
}

function Set-RegDword {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][UInt32]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Set-RegString {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

function Save-State {
    param([hashtable]$State)

    if (-not (Test-Path -LiteralPath $WorkRoot)) {
        New-Item -Path $WorkRoot -ItemType Directory -Force | Out-Null
    }

    $json = $State | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $StateFile -Value $json -Encoding UTF8
}

function Load-State {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }

    try {
        return (Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        Write-Log "State file is corrupt. Ignoring it." 'WARN'
        return $null
    }
}

function Remove-State {
    if (Test-Path -LiteralPath $StateFile) {
        Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-SecureBootEnabled {
    try {
        return [bool](Confirm-SecureBootUEFI)
    }
    catch {
        return $false
    }
}

function Get-SecureBootAscii {
    param([Parameter(Mandatory=$true)][ValidateSet('PK','KEK','db','dbx')][string]$Name)

    try {
        $obj = Get-SecureBootUEFI -Name $Name -ErrorAction Stop
        return [System.Text.Encoding]::ASCII.GetString($obj.Bytes)
    }
    catch {
        return $null
    }
}

function Test-KekContains2023 {
    $ascii = Get-SecureBootAscii -Name 'KEK'
    if ([string]::IsNullOrWhiteSpace($ascii)) { return $false }

    return (
        $ascii -match 'Microsoft Corporation KEK 2K CA 2023' -or
        $ascii -match 'Microsoft Corporation KEK CA 2023'
    )
}

function Test-DbContains2023 {
    $ascii = Get-SecureBootAscii -Name 'db'
    if ([string]::IsNullOrWhiteSpace($ascii)) { return $false }

    return (
        $ascii -match 'Windows UEFI CA 2023' -or
        $ascii -match 'Microsoft UEFI CA 2023' -or
        $ascii -match 'Microsoft Option ROM UEFI CA 2023'
    )
}

function Test-DbxContainsPCA2011Revocation {
    $ascii = Get-SecureBootAscii -Name 'dbx'
    if ([string]::IsNullOrWhiteSpace($ascii)) { return $false }

    return ($ascii -match 'Microsoft Windows Production PCA 2011')
}

function Get-TaskExists {
    try {
        $null = Get-ScheduledTask -TaskPath '\Microsoft\Windows\PI\' -TaskName 'Secure-Boot-Update' -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Mount-EfiPartition {
    param([string]$DriveLetter = 'S')

    $driveRoot = ('{0}:' -f $DriveLetter)

    if (-not (Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue)) {
        Write-Log ("Mounting EFI partition to {0}" -f $driveRoot)
        & mountvol $driveRoot /S | Out-Null
        Start-Sleep -Seconds 2
    }

    if (-not (Test-Path -LiteralPath $driveRoot)) {
        throw ("Failed to mount EFI partition to {0}" -f $driveRoot)
    }

    return $driveRoot
}

function Dismount-EfiPartition {
    param([string]$DriveLetter = 'S')

    $driveRoot = ('{0}:' -f $DriveLetter)

    try {
        if (Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue) {
            Write-Log ("Dismounting EFI partition from {0}" -f $driveRoot)
            & mountvol $driveRoot /D | Out-Null
        }
    }
    catch {
        Write-Log ("Failed to dismount EFI partition {0}: {1}" -f $driveRoot, $_.Exception.Message) 'WARN'
    }
}

function Get-BootManagerTempCopy {
    param([string]$DriveLetter = 'S')

    $efiMount = Mount-EfiPartition -DriveLetter $DriveLetter
    try {
        $src = '{0}\EFI\Microsoft\Boot\bootmgfw.efi' -f $efiMount
        if (-not (Test-Path -LiteralPath $src)) {
            throw ("Boot manager not found at {0}" -f $src)
        }

        $tempDir = Join-Path $env:TEMP 'SecureBootCA2023'
        if (-not (Test-Path -LiteralPath $tempDir)) {
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
        }

        $dest = Join-Path $tempDir ('bootmgfw_{0}_{1}.efi' -f $env:COMPUTERNAME, ([guid]::NewGuid().ToString('N')))
        Write-Log ("Copying {0} to {1}" -f $src, $dest)
        Copy-Item -LiteralPath $src -Destination $dest -Force
        return $dest
    }
    finally {
        Dismount-EfiPartition -DriveLetter $DriveLetter
    }
}

function Get-BootManagerEvidence {
    $result = [ordered]@{
        BootManagerHasCA2023 = $false
        Evidence             = @()
        Chain                = $null
        Signer               = $null
        CertUtilRaw          = $null
        FilePath             = $null
    }

    $file = $null

    try {
        $file = Get-BootManagerTempCopy
        $result.FilePath = $file

        # 1) certutil is the strongest check here
        $certutil = Get-Command certutil.exe -ErrorAction SilentlyContinue
        if ($certutil) {
            $raw = & certutil.exe -dump $file 2>&1 | Out-String
            $result.CertUtilRaw = $raw

            $chainParts = New-Object System.Collections.Generic.List[string]

            foreach ($line in ($raw -split "`r?`n")) {
                if ($line -match '^\s*Issuer:\s*(.+)$') {
                    $chainParts.Add(("Issuer: {0}" -f $Matches[1].Trim()))
                }
                elseif ($line -match '^\s*Subject:\s*(.+)$') {
                    $chainParts.Add(("Subject: {0}" -f $Matches[1].Trim()))
                }
            }

            if ($chainParts.Count -gt 0) {
                $result.Chain = ($chainParts -join ' | ')
                Write-Log ("Boot manager certificate chain: {0}" -f $result.Chain)
            }

            if ($raw -match 'Windows UEFI CA 2023') {
                $result.BootManagerHasCA2023 = $true
                $result.Evidence += 'certutil-chain'
            }
        }

        # 2) fallback signer info
        try {
            $sig = Get-AuthenticodeSignature -FilePath $file -ErrorAction Stop
            if ($sig.SignerCertificate) {
                $result.Signer = $sig.SignerCertificate.Subject
            }
        }
        catch {
        }

        # 3) event 1799 is supporting evidence, not sole proof
        $event1799 = Get-LatestSecureBootEvent -Ids 1799 -MaxEvents 1
        if ($event1799) {
            $msg = $event1799.Message
            if ($msg -match 'Boot Manager signed with Windows UEFI CA 2023 was installed successfully') {
                if (-not $result.BootManagerHasCA2023) {
                    # only supporting evidence if certutil was not available / inconclusive
                    $result.BootManagerHasCA2023 = $true
                }
                $result.Evidence += 'event1799'
            }
        }

        return [pscustomobject]$result
    }
    finally {
        if ($file -and (Test-Path -LiteralPath $file)) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-LatestSecureBootEvent {
    param(
        [int[]]$Ids,
        [int]$MaxEvents = 20
    )

    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            Id      = $Ids
        } -ErrorAction Stop | Sort-Object TimeCreated -Descending

        if ($MaxEvents -eq 1) {
            return $events | Select-Object -First 1
        }

        return $events | Select-Object -First $MaxEvents
    }
    catch {
        return @()
    }
}

function Get-SecureBootStatus {
    $statusText  = [string](Get-RegValue -Path $RegistryServicing -Name 'UEFICA2023Status' -Default '')
    $errorCode   = Get-RegValue -Path $RegistryServicing -Name 'UEFICA2023Error' -Default $null
    $errorEvent  = Get-RegValue -Path $RegistryServicing -Name 'UEFICA2023ErrorEvent' -Default $null
    $capable     = Get-RegValue -Path $RegistryServicing -Name 'WindowsUEFICA2023Capable' -Default $null
    $avail       = Get-RegValue -Path $RegistryBase      -Name 'AvailableUpdates' -Default 0
    $managedOpt  = Get-RegValue -Path $RegistryBase      -Name 'MicrosoftUpdateManagedOptIn' -Default 0

    $boot = Get-BootManagerEvidence

    $events = Get-LatestSecureBootEvent -Ids @(1795,1796,1799,1801,1803,1808,1032,1033,1034,1035,1036,1037) -MaxEvents 50

    $last1795 = $events | Where-Object { $_.Id -eq 1795 } | Select-Object -First 1
    $last1796 = $events | Where-Object { $_.Id -eq 1796 } | Select-Object -First 1
    $last1799 = $events | Where-Object { $_.Id -eq 1799 } | Select-Object -First 1
    $last1801 = $events | Where-Object { $_.Id -eq 1801 } | Select-Object -First 1
    $last1803 = $events | Where-Object { $_.Id -eq 1803 } | Select-Object -First 1
    $last1808 = $events | Where-Object { $_.Id -eq 1808 } | Select-Object -First 1

    $secureBootEnabled = Test-SecureBootEnabled
    $taskExists        = Get-TaskExists
    $kek2023           = Test-KekContains2023
    $db2023            = Test-DbContains2023

    $completed = $false
    $needsUpdate = $true
    $reason = $null

    if (-not $secureBootEnabled) {
        $completed = $false
        $needsUpdate = $true
        $reason = 'Secure Boot is not enabled.'
    }
    elseif (-not $taskExists) {
        $completed = $false
        $needsUpdate = $true
        $reason = 'Scheduled task \Microsoft\Windows\PI\Secure-Boot-Update does not exist.'
    }
    elseif ($last1803) {
        $completed = $false
        $needsUpdate = $true
        $reason = 'KEK update cannot proceed because no OEM PK-signed KEK is available for this device (Event 1803).'
    }
    elseif ($last1795) {
        $completed = $false
        $needsUpdate = $true
        $reason = 'Firmware returned an error while applying a Secure Boot variable update (Event 1795).'
    }
    elseif ($last1796 -and -not $kek2023) {
        $completed = $false
        $needsUpdate = $true
        $reason = 'Secure Boot variable update failed with Event 1796 and KEK is still not updated.'
    }
    elseif ($kek2023 -and $db2023 -and $boot.BootManagerHasCA2023) {
        $completed = $true
        $needsUpdate = $false
        $reason = 'Compliant.'
    }
    elseif (-not $db2023) {
        $reason = 'Secure Boot DB does not contain the 2023 CA(s).'
    }
    elseif (-not $kek2023) {
        $reason = 'Secure Boot KEK does not contain the 2023 CA.'
    }
    elseif (-not $boot.BootManagerHasCA2023) {
        $reason = 'Boot manager is not yet confirmed as 2023-signed.'
    }
    else {
        $reason = 'Device is not yet fully compliant.'
    }

    [pscustomobject]@{
        SecureBootEnabled        = $secureBootEnabled
        ScheduledTaskExists      = $taskExists
        AvailableUpdates         = [uint32]$avail
        MicrosoftUpdateManagedOptIn = [uint32]$managedOpt
        WindowsUEFICA2023Capable = $capable
        UEFICA2023Status         = $statusText
        UEFICA2023Error          = $errorCode
        UEFICA2023ErrorEvent     = $errorEvent
        KekContainsCA2023        = $kek2023
        DbContainsCA2023         = $db2023
        BootManagerHasCA2023     = [bool]$boot.BootManagerHasCA2023
        BootManagerEvidence      = ($boot.Evidence -join ',')
        BootManagerChain         = $boot.Chain
        BootManagerSigner        = $boot.Signer
        LastEvent1795Time        = if ($last1795) { $last1795.TimeCreated } else { $null }
        LastEvent1796Time        = if ($last1796) { $last1796.TimeCreated } else { $null }
        LastEvent1799Time        = if ($last1799) { $last1799.TimeCreated } else { $null }
        LastEvent1801Time        = if ($last1801) { $last1801.TimeCreated } else { $null }
        LastEvent1803Time        = if ($last1803) { $last1803.TimeCreated } else { $null }
        LastEvent1808Time        = if ($last1808) { $last1808.TimeCreated } else { $null }
        Completed                = $completed
        NeedsUpdate              = $needsUpdate
        Reason                   = $reason
    }
}

function Write-StatusSummary {
    param(
        [Parameter(Mandatory=$true)]$Status,
        [string]$Title = 'FINAL SUMMARY'
    )

    Write-Log ("================ {0} ================" -f $Title)
    Write-Log ("SecureBootEnabled        : {0}" -f $Status.SecureBootEnabled)
    Write-Log ("ScheduledTaskExists      : {0}" -f $Status.ScheduledTaskExists)
    Write-Log ("AvailableUpdates         : {0}" -f $Status.AvailableUpdates)
    Write-Log ("MicrosoftUpdateManagedOptIn : {0}" -f $Status.MicrosoftUpdateManagedOptIn)
    Write-Log ("WindowsUEFICA2023Capable : {0}" -f $Status.WindowsUEFICA2023Capable)
    Write-Log ("UEFICA2023Status         : {0}" -f $Status.UEFICA2023Status)
    Write-Log ("UEFICA2023ErrorHex       : {0}" -f $(if ($null -ne $Status.UEFICA2023Error) { ('0x{0:X}' -f [uint32]$Status.UEFICA2023Error) } else { '' }))
    Write-Log ("UEFICA2023ErrorEvent     : {0}" -f $Status.UEFICA2023ErrorEvent)
    Write-Log ("KekContainsCA2023        : {0}" -f $Status.KekContainsCA2023)
    Write-Log ("DbContainsCA2023         : {0}" -f $Status.DbContainsCA2023)
    Write-Log ("BootManagerHasCA2023     : {0}" -f $Status.BootManagerHasCA2023)
    if ($Status.BootManagerEvidence) {
        Write-Log ("BootManagerEvidence      : {0}" -f $Status.BootManagerEvidence)
    }
    if ($Status.BootManagerChain) {
        Write-Log ("BootManagerChain         : {0}" -f $Status.BootManagerChain)
    }
    if ($Status.BootManagerSigner) {
        Write-Log ("BootManagerSigner        : {0}" -f $Status.BootManagerSigner)
    }
    if ($Status.LastEvent1799Time) {
        Write-Log ("LastEvent1799Time        : {0}" -f $Status.LastEvent1799Time)
    }
    if ($Status.LastEvent1803Time) {
        Write-Log ("LastEvent1803Time        : {0}" -f $Status.LastEvent1803Time)
    }
    if ($Status.LastEvent1808Time) {
        Write-Log ("LastEvent1808Time        : {0}" -f $Status.LastEvent1808Time)
    }
    Write-Log ("Completed                : {0}" -f $Status.Completed)
    Write-Log ("NeedsUpdate              : {0}" -f $Status.NeedsUpdate)
    Write-Log ("Reason                   : {0}" -f $Status.Reason)
    Write-Log "=============================================="
}

function Start-SecureBootUpdateTask {
    Write-Log ("Starting scheduled task {0}" -f $TaskPath)
    Start-ScheduledTask -TaskPath '\Microsoft\Windows\PI\' -TaskName 'Secure-Boot-Update'
}

function Register-Continuation {
    $scriptPath = Get-ScriptPath
    if (-not $scriptPath) {
        throw 'Cannot determine script path for continuation.'
    }

    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Apply -ContinueAfterReboot' -f $scriptPath
    Set-RegString -Path $RunOncePath -Name 'SecureBootCA2023Continue' -Value $cmd
    Write-Log ("Registered RunOnce continuation: {0}" -f $cmd)
}

function Clear-Continuation {
    try {
        Remove-ItemProperty -Path $RunOncePath -Name 'SecureBootCA2023Continue' -ErrorAction SilentlyContinue
    }
    catch {
    }
}

function Wait-ForAvailableUpdatesChange {
    param(
        [uint32]$InitialValue,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 5
        $current = [uint32](Get-RegValue -Path $RegistryBase -Name 'AvailableUpdates' -Default $InitialValue)
        if ($current -ne $InitialValue) {
            return $current
        }
    } while ((Get-Date) -lt $deadline)

    return [uint32](Get-RegValue -Path $RegistryBase -Name 'AvailableUpdates' -Default $InitialValue)
}

function Invoke-CheckMode {
    Write-Log "Running in CHECK mode"
    $status = Get-SecureBootStatus
    Write-StatusSummary -Status $status -Title 'CHECK SUMMARY'

    if ($status.Completed) {
        Write-Log "CHECK FINISHED: Host is compliant."
        exit 0
    }
    else {
        Write-Log "CHECK FINISHED: Host needs update." 'WARN'
        exit 1
    }
}

function Invoke-ApplyMode {
    $scriptPath = Get-ScriptPath
    Write-Log "Starting Secure Boot CA 2023 automation"
    Write-Log ("Script path: {0}" -f $(if ($scriptPath) { $scriptPath } else { '<unknown>' }))

    $status = Get-SecureBootStatus
    Write-Log ("Servicing state: Capable={0}, Status={1}, Error={2}" -f $status.WindowsUEFICA2023Capable, $status.UEFICA2023Status, $status.UEFICA2023Error)
    Write-Log ("Secure Boot KEK contains 2023 CA: {0}" -f $status.KekContainsCA2023)
    Write-Log ("Secure Boot DB contains 2023 CA: {0}" -f $status.DbContainsCA2023)

    if (-not $status.SecureBootEnabled) {
        throw 'Secure Boot is not enabled.'
    }

    if (-not $status.ScheduledTaskExists) {
        throw 'Scheduled task \Microsoft\Windows\PI\Secure-Boot-Update is missing.'
    }

    if ($status.Completed) {
        Write-Log 'System is already compliant.'
        Write-StatusSummary -Status $status -Title 'FINAL SUMMARY'
        Remove-State
        Clear-Continuation
        exit 0
    }

    if ($status.LastEvent1803Time) {
        throw 'KEK update is blocked by missing OEM PK-signed KEK (Event 1803). This cannot be forced by script.'
    }

    if ($status.LastEvent1795Time) {
        throw 'Firmware returned Event 1795 while updating a Secure Boot variable. This is a firmware/OEM issue, not a script issue.'
    }

    # continuation path after reboot
    if ($ContinueAfterReboot) {
        Write-Log 'Continuation mode detected. Resuming after reboot.'
        Start-SecureBootUpdateTask
        Start-Sleep -Seconds 15

        $after = Get-SecureBootStatus
        Write-StatusSummary -Status $after -Title 'POST-REBOOT SUMMARY'

        if ($after.Completed) {
            Write-Log 'SUCCESS: Host is fully compliant.'
            Remove-State
            Clear-Continuation
            exit 0
        }

        if ($after.LastEvent1803Time) {
            throw 'Post-reboot failure: KEK update is blocked by missing OEM PK-signed KEK (Event 1803).'
        }

        if ($after.LastEvent1795Time) {
            throw 'Post-reboot failure: Firmware returned Event 1795.'
        }

        if ($after.LastEvent1796Time -and -not $after.KekContainsCA2023) {
            throw 'Post-reboot failure: Event 1796 persists and KEK is still not updated.'
        }

        if (-not $after.BootManagerHasCA2023) {
            throw 'Post-reboot failure: Boot Manager is still not confirmed as Windows UEFI CA 2023 signed.'
        }

        throw ("Post-reboot failure: {0}" -f $after.Reason)
    }

    Write-Log 'Fresh run detected. Starting at stage 0.'
    Write-Log 'Stage 0: Apply official Microsoft trigger values'

    # Opt-in to Microsoft managed update path
    Set-RegDword -Path $RegistryBase -Name 'MicrosoftUpdateManagedOptIn' -Value 1
    Write-Log 'Set MicrosoftUpdateManagedOptIn = 1'

    # Full official bitfield for IT-managed updates
    Set-RegDword -Path $RegistryBase -Name 'AvailableUpdates' -Value ([uint32]$BitAllSupported)
    Write-Log ('Set AvailableUpdates = 0x{0:X}' -f $BitAllSupported)

    Start-SecureBootUpdateTask

    $changed = Wait-ForAvailableUpdatesChange -InitialValue ([uint32]$BitAllSupported) -TimeoutSeconds 180
    Write-Log ('AvailableUpdates after task start: 0x{0:X}' -f $changed)

    $current = Get-SecureBootStatus

    if ($current.Completed) {
        Write-Log 'SUCCESS: Host became compliant without requiring an additional reboot.'
        Write-StatusSummary -Status $current -Title 'FINAL SUMMARY'
        Remove-State
        Clear-Continuation
        exit 0
    }

    if ($current.LastEvent1803Time) {
        throw 'KEK update is blocked by missing OEM PK-signed KEK (Event 1803). This cannot be forced by script.'
    }

    if ($current.LastEvent1795Time) {
        throw 'Firmware returned Event 1795 while updating a Secure Boot variable. This is a firmware/OEM issue.'
    }

    if ($current.LastEvent1796Time -and -not $current.KekContainsCA2023) {
        throw 'Event 1796 occurred and KEK is still not updated. This device cannot be forced by script.'
    }

    # Official expected handoff point before reboot for boot manager phase
    if ($current.AvailableUpdates -eq 0x4100 -or ($current.KekContainsCA2023 -and -not $current.BootManagerHasCA2023)) {
        Register-Continuation
        Save-State @{
            ComputerName = $env:COMPUTERNAME
            Timestamp    = (Get-Date).ToString('o')
            Phase        = 'RebootPendingForBootManager'
        }

        if ($NoReboot) {
            Write-Log 'Reboot required to continue Boot Manager update. Run the script again with -Apply after reboot.' 'WARN'
            Write-StatusSummary -Status $current -Title 'FINAL SUMMARY'
            exit 2
        }

        Write-Log 'Restart requested: Reboot after KEK/DB processing so Boot Manager can be updated.' 'WARN'
        Restart-Computer -Force
        exit 0
    }

    # If task already reached 0x4000, just summarize and exit
    if ($current.AvailableUpdates -eq 0x4000 -and $current.BootManagerHasCA2023) {
        Write-Log 'SUCCESS: AvailableUpdates reached 0x4000 and Boot Manager is 2023-signed.'
        Write-StatusSummary -Status $current -Title 'FINAL SUMMARY'
        Remove-State
        Clear-Continuation
        exit 0
    }

    Write-StatusSummary -Status $current -Title 'FINAL SUMMARY'
    throw ("Device did not reach the expected next stage. Current reason: {0}" -f $current.Reason)
}

# -----------------------------
# Main
# -----------------------------
try {
    if (-not (Test-Path -LiteralPath $WorkRoot)) {
        New-Item -Path $WorkRoot -ItemType Directory -Force | Out-Null
    }

    if (-not $Check -and -not $Apply) {
        $Check = $true
    }

    if ($Check) {
        $scriptPath = Get-ScriptPath
        Write-Log "Starting Secure Boot CA 2023 automation"
        Write-Log ("Script path: {0}" -f $(if ($scriptPath) { $scriptPath } else { '<unknown>' }))
        Invoke-CheckMode
    }

    if ($Apply) {
        Invoke-ApplyMode
    }
}
catch {
    $message = $_.Exception.Message
    Write-Log ("FAILED: {0}" -f $message) 'ERROR'

    try {
        $status = Get-SecureBootStatus
        Write-StatusSummary -Status $status -Title 'FINAL SUMMARY'
    }
    catch {
        Write-Log ("Failed to build final summary: {0}" -f $_.Exception.Message) 'ERROR'
    }

    exit 99
}

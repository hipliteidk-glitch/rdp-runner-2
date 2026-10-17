<#
.SYNOPSIS
    Rebuilds a PC from a backup created by Backup-PC.ps1.

.DESCRIPTION
    Reads a Backup_<timestamp> folder and:
      * reinstalls WinGet packages (winget import)
      * reports classic programs that are no longer installed
      * re-enables optional Windows features that were enabled before
      * resets the start type of automatic services
      * re-registers your scheduled tasks
      * restores environment variables, timezone, power plan, RDP and firewall rules
      * copies personal folders back (unless -SkipFiles)

    Run this elevated (Administrator) on a freshly installed Windows.

.PARAMETER BackupPath
    The Backup_<timestamp> folder to restore from. Defaults to the most recent
    backup under D:\PCRestore or .\Backups.

.PARAMETER SkipApps
    Do not run winget import.

.PARAMETER SkipFiles
    Do not copy personal folders back.

.EXAMPLE
    .\Restore-PC.ps1

.EXAMPLE
    .\Restore-PC.ps1 -BackupPath D:\PCRestore\Backup_20261017_143000 -SkipFiles
#>
[CmdletBinding()]
param(
    [string]$BackupPath,
    [switch]$SkipApps,
    [switch]$SkipFiles
)

$ErrorActionPreference = 'Continue'

# ------------------------------------------------------------------
# helpers
# ------------------------------------------------------------------
$script:LogFile = $null

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $line = '[{0}] {1,-5} {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line }
}

function Test-IsAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Json {
    param([Parameter(Mandatory = $true)][string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

function Invoke-CopyBack {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Dest, [Parameter(Mandatory = $true)][string]$Label)
    # /XO keeps files that are newer on this machine, so a restore never
    # overwrites work done after the backup was taken.
    $null = & robocopy.exe $Source $Dest /E /XO /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NP 2>&1
    $code = $LASTEXITCODE
    if ($code -lt 8) {
        Write-Log "$Label restored (robocopy code $code)" 'OK'
        return $true
    }
    Write-Log "$Label restore FAILED (robocopy code $code)" 'ERROR'
    return $false
}

# ------------------------------------------------------------------
# locate the backup
# ------------------------------------------------------------------
if (-not $BackupPath) {
    $roots = @('D:\PCRestore', (Join-Path $PSScriptRoot 'Backups'))
    $candidates = foreach ($root in $roots) {
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -Directory -Filter 'Backup_*' -ErrorAction SilentlyContinue
        }
    }
    $latest = $candidates | Sort-Object Name -Descending | Select-Object -First 1
    if ($latest) { $BackupPath = $latest.FullName }
}

if (-not $BackupPath -or -not (Test-Path -LiteralPath $BackupPath)) {
    Write-Host "No backup folder found. Pass one with -BackupPath." -ForegroundColor Red
    exit 1
}
$BackupPath = (Resolve-Path -LiteralPath $BackupPath).Path
$script:LogFile = Join-Path $BackupPath 'restore.log'

$isAdmin = Test-IsAdmin
$summary = New-Object System.Collections.ArrayList

Write-Log 'Restore started'
Write-Log "Backup: $BackupPath"
Write-Log "Running as administrator: $isAdmin"
if (-not $isAdmin) {
    Write-Log 'Not elevated: Windows features, scheduled tasks, RDP and machine settings will be skipped.' 'WARN'
}

$AppsDir   = Join-Path $BackupPath 'Apps'
$SystemDir = Join-Path $BackupPath 'System'
$TaskDir   = Join-Path $BackupPath 'ScheduledTasks'

if (Test-Path -LiteralPath (Join-Path $BackupPath 'manifest.json')) {
    try {
        $manifest = Get-Json -Path (Join-Path $BackupPath 'manifest.json')
        Write-Log "Backup created $($manifest.CreatedAt) on $($manifest.ComputerName)" 'OK'
    }
    catch {
        Write-Log "Could not read manifest.json: $($_.Exception.Message)" 'WARN'
    }
}

# ------------------------------------------------------------------
# 1. applications - winget import
# ------------------------------------------------------------------
if (-not $SkipApps) {
    $wingetJson = Join-Path $AppsDir 'winget-packages.json'
    if (Test-Path -LiteralPath $wingetJson) {
        $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Log 'Installing WinGet packages (this can take a while)...'
            $null = & $winget.Source import -i $wingetJson --accept-source-agreements --accept-package-agreements 2>&1
            $code = $LASTEXITCODE
            if ($code -eq 0) { Write-Log 'WinGet packages installed' 'OK' }
            else { Write-Log "winget import finished with exit code $code - some packages may need manual install" 'WARN' }
        }
        else {
            Write-Log 'winget.exe not found. Install "App Installer" from the Microsoft Store, then re-run this script.' 'ERROR'
            [void]$summary.Add('Install App Installer (winget), then re-run Restore-PC.ps1 for app installs.')
        }
    }
    else {
        Write-Log 'No winget-packages.json in this backup' 'WARN'
    }
}

# classic programs that no longer exist (reported even when apps are skipped)
$programsCsv = Join-Path $AppsDir 'programs.csv'
if (Test-Path -LiteralPath $programsCsv) {
    try {
        $backupPrograms = Import-Csv -LiteralPath $programsCsv
        $uninstallRoots = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $current = foreach ($root in $uninstallRoots) {
            Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName } |
                Select-Object -ExpandProperty DisplayName
        }
        $current = @($current)
        $missing = @($backupPrograms | Where-Object { $current -notcontains $_.DisplayName })
        if ($missing.Count -gt 0) {
            $missingPath = Join-Path $BackupPath 'programs-still-missing.csv'
            $missing | Export-Csv -LiteralPath $missingPath -NoTypeInformation -Encoding UTF8
            Write-Log "$($missing.Count) classic programs are not installed; list written to $missingPath" 'WARN'
            [void]$summary.Add("Install the $($missing.Count) programs listed in programs-still-missing.csv (manual installers run by you).")
        }
        else {
            Write-Log 'Every classic program from the backup is present' 'OK'
        }
    }
    catch {
        Write-Log "Comparing installed programs failed: $($_.Exception.Message)" 'WARN'
    }
}

# ------------------------------------------------------------------
# 2. optional Windows features
# ------------------------------------------------------------------
$featuresCsv = Join-Path $SystemDir 'optional-features.csv'
if (Test-Path -LiteralPath $featuresCsv) {
    if ($isAdmin) {
        try {
            $wanted = @(Import-Csv -LiteralPath $featuresCsv | Where-Object { $_.State -eq 'Enabled' })
            Write-Log "Re-enabling $($wanted.Count) optional features..."
            foreach ($row in $wanted) {
                try {
                    $state = (Get-WindowsOptionalFeature -Online -FeatureName $row.FeatureName -ErrorAction Stop).State
                    if ($state -ne 'Enabled') {
                        $null = Enable-WindowsOptionalFeature -Online -FeatureName $row.FeatureName -NoRestart -ErrorAction Stop
                        Write-Log "Enabled feature: $($row.FeatureName)" 'OK'
                    }
                }
                catch {
                    Write-Log "Feature $($row.FeatureName) could not be enabled: $($_.Exception.Message)" 'WARN'
                    [void]$summary.Add("Enable Windows feature $($row.FeatureName) manually (e.g. RDP, Hyper-V, .NET 3.5).")
                }
            }
        }
        catch {
            Write-Log "Feature restore failed: $($_.Exception.Message)" 'WARN'
        }
    }
    else {
        Write-Log 'Skipping Windows features (needs Administrator)' 'WARN'
    }
}

# ------------------------------------------------------------------
# 3. services
# ------------------------------------------------------------------
$servicesCsv = Join-Path $SystemDir 'services.csv'
if (Test-Path -LiteralPath $servicesCsv) {
    try {
        $rows = @(Import-Csv -LiteralPath $servicesCsv | Where-Object { $_.StartType -eq 'Automatic' })
        $changed = 0
        foreach ($row in $rows) {
            try {
                $svc = Get-Service -Name $row.Name -ErrorAction Stop
                if ($svc.StartType -ne 'Automatic') {
                    Set-Service -Name $row.Name -StartupType Automatic -ErrorAction Stop
                    $changed++
                }
            }
            catch {
                # Service does not exist on this install - normal for leftover entries
            }
        }
        Write-Log "Services set back to Automatic: $changed" 'OK'
    }
    catch {
        Write-Log "Service restore failed: $($_.Exception.Message)" 'WARN'
    }
}

# ------------------------------------------------------------------
# 4. scheduled tasks
# ------------------------------------------------------------------
$tasksCsv = Join-Path $SystemDir 'scheduled-tasks.csv'
if (Test-Path -LiteralPath $tasksCsv) {
    if ($isAdmin) {
        try {
            $rows = @(Import-Csv -LiteralPath $tasksCsv)
            $restored = 0
            foreach ($row in $rows) {
                $xmlPath = Join-Path $TaskDir $row.File
                if (-not (Test-Path -LiteralPath $xmlPath)) { continue }
                try {
                    $xml = Get-Content -LiteralPath $xmlPath -Raw
                    $null = Register-ScheduledTask -Xml $xml -TaskName $row.TaskName -TaskPath $row.TaskPath -Force -ErrorAction Stop
                    $restored++
                }
                catch {
                    Write-Log "Task $($row.TaskPath)$($row.TaskName) not restored: $($_.Exception.Message)" 'WARN'
                }
            }
            Write-Log "Scheduled tasks restored: $restored of $($rows.Count)" 'OK'
        }
        catch {
            Write-Log "Scheduled task restore failed: $($_.Exception.Message)" 'WARN'
        }
    }
    else {
        Write-Log 'Skipping scheduled tasks (needs Administrator)' 'WARN'
    }
}

# ------------------------------------------------------------------
# 5. environment variables
# ------------------------------------------------------------------
$skipEnv = @(
    'COMPUTERNAME', 'USERNAME', 'USERDOMAIN', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA',
    'TEMP', 'TMP', 'HOMEPATH', 'HOMEDRIVE', 'SYSTEMROOT', 'WINDIR', 'SystemDrive', 'SystemRoot',
    'PATHEXT', 'PROGRAMDATA', 'PROGRAMFILES', 'PROGRAMFILES(X86)', 'COMMONPROGRAMFILES',
    'LOGONSERVER', 'SESSIONNAME', 'NUMBER_OF_PROCESSORS', 'OS', 'PUBLIC', 'PSModulePath',
    'PROCESSOR_ARCHITECTURE', 'PROCESSOR_IDENTIFIER', 'PROCESSOR_LEVEL', 'PROCESSOR_REVISION'
)

$userEnvFile = Join-Path $SystemDir 'env-user.json'
if (Test-Path -LiteralPath $userEnvFile) {
    try {
        $envVars = Get-Json -Path $userEnvFile
        $count = 0
        foreach ($prop in $envVars.PSObject.Properties) {
            if ($skipEnv -contains $prop.Name.ToUpper()) { continue }
            [Environment]::SetEnvironmentVariable($prop.Name, [string]$prop.Value, 'User')
            $count++
        }
        Write-Log "User environment variables restored: $count" 'OK'
    }
    catch {
        Write-Log "User environment restore failed: $($_.Exception.Message)" 'WARN'
    }
}

$machineEnvFile = Join-Path $SystemDir 'env-machine.json'
if ($isAdmin -and (Test-Path -LiteralPath $machineEnvFile)) {
    try {
        $envVars = Get-Json -Path $machineEnvFile
        $count = 0
        foreach ($prop in $envVars.PSObject.Properties) {
            if ($skipEnv -contains $prop.Name.ToUpper()) { continue }
            [Environment]::SetEnvironmentVariable($prop.Name, [string]$prop.Value, 'Machine')
            $count++
        }
        Write-Log "Machine environment variables restored: $count" 'OK'
    }
    catch {
        Write-Log "Machine environment restore failed: $($_.Exception.Message)" 'WARN'
    }
}

# ------------------------------------------------------------------
# 6. settings: timezone, power plan, RDP
# ------------------------------------------------------------------
$settingsFile = Join-Path $SystemDir 'settings.json'
if (Test-Path -LiteralPath $settingsFile) {
    try {
        $settings = Get-Json -Path $settingsFile

        if ($settings.TimeZone) {
            try {
                $currentTz = (Get-TimeZone).Id
                if ($currentTz -ne $settings.TimeZone) {
                    Set-TimeZone -Id $settings.TimeZone -ErrorAction Stop
                    Write-Log "Timezone set to $($settings.TimeZone)" 'OK'
                }
                else {
                    Write-Log "Timezone already $($settings.TimeZone)"
                }
            }
            catch {
                Write-Log "Timezone could not be set to $($settings.TimeZone): $($_.Exception.Message)" 'WARN'
            }
        }

        if ($settings.PowerPlan) {
            $null = & powercfg.exe /setactive $settings.PowerPlan 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Log "Power plan set to $($settings.PowerPlan)" 'OK' }
            else { Write-Log "Power plan could not be set to $($settings.PowerPlan)" 'WARN' }
        }

        if ($settings.RDPEnabled -eq $true) {
            if ($isAdmin) {
                try {
                    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0 -ErrorAction Stop
                    Write-Log 'Remote Desktop re-enabled' 'OK'
                    try {
                        $null = & netsh.exe advfirewall firewall set rule group="Remote Desktop" new enable=Yes 2>&1
                        if ($LASTEXITCODE -eq 0) { Write-Log 'Remote Desktop firewall rules enabled' 'OK' }
                        else { Write-Log 'Remote Desktop firewall rules were not updated (localized rule group name?)' 'WARN' }
                    }
                    catch {
                        Write-Log "Firewall rule update failed: $($_.Exception.Message)" 'WARN'
                    }
                    Write-Log 'RDP needs an account password and, on Server, a restart: net stop TermService / net start TermService' 'INFO'
                }
                catch {
                    Write-Log "RDP could not be re-enabled: $($_.Exception.Message)" 'WARN'
                }
            }
            else {
                Write-Log 'RDP was enabled before - re-run elevated to re-enable it' 'WARN'
                [void]$summary.Add('Enable Remote Desktop manually (Settings > System > Remote Desktop) or re-run this script as Administrator.')
            }
        }
    }
    catch {
        Write-Log "Settings restore failed: $($_.Exception.Message)" 'WARN'
    }
}

# ------------------------------------------------------------------
# 7. personal files
# ------------------------------------------------------------------
$filesMapFile = Join-Path $SystemDir 'files-map.json'
if (-not $SkipFiles -and (Test-Path -LiteralPath $filesMapFile)) {
    try {
        $entries = @(Get-Json -Path $filesMapFile)
        foreach ($entry in $entries) {
            if (-not (Test-Path -LiteralPath $entry.BackupFolder)) {
                Write-Log "Backup folder missing, skipped: $($entry.BackupFolder)" 'WARN'
                continue
            }
            $target = $entry.Source
            if (-not (Test-Path -LiteralPath $target)) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
            }
            $null = Invoke-CopyBack -Source $entry.BackupFolder -Dest $target -Label "Files -> $target"
        }
    }
    catch {
        Write-Log "File restore failed: $($_.Exception.Message)" 'WARN'
    }
}
elseif ($SkipFiles) {
    Write-Log 'Personal files skipped (-SkipFiles)'
}
else {
    Write-Log 'This backup contains no personal files'
}

# ------------------------------------------------------------------
# 8. wrap up
# ------------------------------------------------------------------
Write-Log 'Restore finished' 'OK'
Write-Host ''
Write-Host 'Manual follow-ups' -ForegroundColor Cyan
Write-Host '-----------------'
foreach ($item in @(
    'Store apps that winget could not install: open the Store > Library > Get updates.',
    'Classic installers: check programs-still-missing.csv and reinstall them yourself.',
    'Programs that need a licence or login (Office, Adobe, Steam, browsers) must be signed in again.',
    'Computer name is not changed automatically - rename the PC if needed, then reboot.',
    'Windows activation and any OEM drivers are not covered by this backup.'
)) {
    Write-Host "  - $item"
}
if ($summary.Count -gt 0) {
    Write-Host ''
    Write-Host 'Items specific to this restore' -ForegroundColor Cyan
    foreach ($item in $summary) { Write-Host "  - $item" }
}
Write-Host ''
Write-Log "Log written to $script:LogFile"

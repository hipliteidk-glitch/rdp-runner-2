<#
.SYNOPSIS
    Captures a restorable snapshot of this PC so it can be rebuilt after a
    Windows reinstall.

.DESCRIPTION
    Collects:
      * installed applications (winget export + classic registry programs + Store/Appx packages)
      * optional Windows features
      * services and their start types
      * scheduled tasks (non-Microsoft)
      * user/machine environment variables
      * settings: timezone, power plan, Remote Desktop (RDP) state
      * optionally your personal folders (Desktop, Documents, Downloads, Music, Pictures, Videos)
    Everything is written into one timestamped folder plus a backup.log.

.PARAMETER Destination
    Root folder that will contain the Backup_<timestamp> folder. Defaults to
    D:\PCRestore when drive D: exists, otherwise .\Backups next to this script.

.PARAMETER IncludeFiles
    Also copy your personal folders into the backup.

.PARAMETER ExtraPaths
    Extra folders to copy when -IncludeFiles is used.

.PARAMETER UserProfile
    Profile folder to read personal files from. Defaults to the current user.

.EXAMPLE
    .\Backup-PC.ps1

.EXAMPLE
    .\Backup-PC.ps1 -IncludeFiles -Destination E:\PCRestore
#>
[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$IncludeFiles,
    [string[]]$ExtraPaths = @(),
    [string]$UserProfile = $env:USERPROFILE
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

function Invoke-Robocopy {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Dest,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $null = & robocopy.exe $Source $Dest /E /R:1 /W:1 /XJ /XD node_modules .cache /NFL /NDL /NJH /NJS /NP 2>&1
    $code = $LASTEXITCODE
    if ($code -lt 8) {
        Write-Log "$Label copied (robocopy code $code)" 'OK'
        return $true
    }
    Write-Log "$Label FAILED (robocopy code $code)" 'ERROR'
    return $false
}

function Save-Json {
    param([Parameter(Mandatory = $true)]$Object, [Parameter(Mandatory = $true)][string]$Path)
    $Object | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

# ------------------------------------------------------------------
# location setup
# ------------------------------------------------------------------
$script:IsAdmin = Test-IsAdmin
if (-not $Destination) {
    if (Test-Path -LiteralPath 'D:\') { $Destination = 'D:\PCRestore' }
    else { $Destination = Join-Path $PSScriptRoot 'Backups' }
}

$stamp     = Get-Date -Format 'yyyyMMdd_HHmmss'
$BackupDir = Join-Path $Destination "Backup_$stamp"
$AppsDir   = Join-Path $BackupDir 'Apps'
$SystemDir = Join-Path $BackupDir 'System'
$TaskDir   = Join-Path $BackupDir 'ScheduledTasks'
$FilesDir  = Join-Path $BackupDir 'Files'

foreach ($dir in @($BackupDir, $AppsDir, $SystemDir, $TaskDir, $FilesDir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
$script:LogFile = Join-Path $BackupDir 'backup.log'

Write-Log "Backup started"
Write-Log "Running as administrator: $script:IsAdmin"
Write-Log "Destination: $BackupDir"
if (-not $script:IsAdmin) {
    Write-Log 'Not elevated: Windows features, machine environment variables and some scheduled tasks will be skipped. Re-run elevated for a complete backup.' 'WARN'
}

# ------------------------------------------------------------------
# 1. machine information
# ------------------------------------------------------------------
try {
    # Get-WmiObject first: Get-CimInstance hangs on some machines (broken CIM/DCOM layer)
    $os = $null
    $cs = $null
    if (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
        # Windows PowerShell 5.1: Get-WmiObject is the fast, reliable path
        try {
            $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
            $cs = Get-WmiObject Win32_ComputerSystem -ErrorAction Stop
        }
        catch {
            Write-Log "Get-WmiObject failed: $($_.Exception.Message)" 'WARN'
        }
    }
    if (-not $os) {
        # PowerShell 7 (no Get-WmiObject): Get-CimInstance with a timeout, so a
        # broken CIM layer cannot hang the whole backup
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop -OperationTimeoutSec 30
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop -OperationTimeoutSec 30
    }
    $machine = [ordered]@{
        CapturedAt    = (Get-Date).ToString('o')
        ComputerName  = $env:COMPUTERNAME
        User          = "$env:USERDOMAIN\$env:USERNAME"
        OS            = $os.Caption
        OSVersion     = $os.Version
        Build         = $os.BuildNumber
        Architecture  = $os.OSArchitecture
        Manufacturer  = $cs.Manufacturer
        Model         = $cs.Model
        TotalRAMGB    = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        IsAdmin       = $script:IsAdmin
        PowerShell    = $PSVersionTable.PSVersion.ToString()
    }
    Save-Json -Object $machine -Path (Join-Path $SystemDir 'machine.json')
    Write-Log ("Machine: {0} / {1} {2}" -f $os.Caption, $cs.Manufacturer, $cs.Model) 'OK'
}
catch {
    Write-Log "Machine information failed: $($_.Exception.Message)" 'WARN'
}

# ------------------------------------------------------------------
# 2. applications
# ------------------------------------------------------------------
$wingetJson = Join-Path $AppsDir 'winget-packages.json'
try {
    $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if ($winget) {
        $null = & $winget.Source export -o $wingetJson --accept-source-agreements 2>&1
        if ((Test-Path -LiteralPath $wingetJson) -and (Get-Item -LiteralPath $wingetJson).Length -gt 0) {
            Write-Log 'winget package list exported' 'OK'
        }
        else {
            Write-Log "winget export produced no file (exit code $LASTEXITCODE)" 'WARN'
        }
    }
    else {
        Write-Log 'winget.exe not found - Store/WinGet apps cannot be restored automatically' 'WARN'
    }
}
catch {
    Write-Log "winget export failed: $($_.Exception.Message)" 'WARN'
}

try {
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $programs = foreach ($root in $uninstallRoots) {
        Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName } |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, InstallLocation, UninstallString, QuietUninstallString
    }
    $programs = $programs | Sort-Object DisplayName, DisplayVersion -Unique
    $programs | Export-Csv -LiteralPath (Join-Path $AppsDir 'programs.csv') -NoTypeInformation -Encoding UTF8
    Write-Log "Classic programs recorded: $($programs.Count)" 'OK'
}
catch {
    Write-Log "Program inventory failed: $($_.Exception.Message)" 'WARN'
}

try {
    $appx = Get-AppxPackage -ErrorAction Stop | Select-Object Name, PackageFullName, Version, Publisher
    $appx | Export-Csv -LiteralPath (Join-Path $AppsDir 'store-packages.csv') -NoTypeInformation -Encoding UTF8
    Write-Log "Store/Appx packages recorded: $($appx.Count)" 'OK'
}
catch {
    Write-Log "Appx inventory failed: $($_.Exception.Message)" 'WARN'
}

# ------------------------------------------------------------------
# 3. optional Windows features
# ------------------------------------------------------------------
try {
    $features = Get-WindowsOptionalFeature -Online -ErrorAction Stop
    $features | Select-Object FeatureName, State | Export-Csv -LiteralPath (Join-Path $SystemDir 'optional-features.csv') -NoTypeInformation -Encoding UTF8
    $enabledCount = @($features | Where-Object { $_.State -eq 'Enabled' }).Count
    Write-Log "Optional features recorded ($enabledCount enabled)" 'OK'
}
catch {
    Write-Log "Get-WindowsOptionalFeature failed: $($_.Exception.Message.Trim())" 'WARN'
    $dismOutput = & dism.exe /Online /Get-Features /Format:Table 2>&1
    if ($LASTEXITCODE -eq 0) {
        $dismOutput | Set-Content -LiteralPath (Join-Path $SystemDir 'optional-features-dism.txt') -Encoding UTF8
        Write-Log 'Features captured with dism (raw output)' 'OK'
    }
    else {
        Write-Log 'Feature capture needs an elevated PowerShell session' 'WARN'
    }
}

# ------------------------------------------------------------------
# 4. services
# ------------------------------------------------------------------
try {
    $services = Get-Service | Select-Object Name, DisplayName, StartType, Status | Sort-Object Name
    $services | Export-Csv -LiteralPath (Join-Path $SystemDir 'services.csv') -NoTypeInformation -Encoding UTF8
    Write-Log "Services recorded: $($services.Count)" 'OK'
}
catch {
    Write-Log "Service inventory failed: $($_.Exception.Message)" 'WARN'
}

# ------------------------------------------------------------------
# 5. scheduled tasks (skip the built-in Microsoft folder)
# ------------------------------------------------------------------
try {
    # Task Scheduler COM API instead of Get-ScheduledTask: the module goes
    # through CIM, which is slow or unavailable on some machines.
    $taskService = New-Object -ComObject Schedule.Service
    $taskService.Connect()

    $taskRows = @()
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($taskService.GetFolder('\'))
    while ($queue.Count -gt 0) {
        $folder = $queue.Dequeue()
        foreach ($task in @($folder.GetTasks(1))) {
            if ($task.Path -like '\Microsoft\*') { continue }
            $flat = ($task.Path -replace '[\\/:*?"<>|]', '_').TrimStart('_')
            $file = "$flat.xml"
            try {
                [System.IO.File]::WriteAllText((Join-Path $TaskDir $file), $task.Xml, (New-Object System.Text.UTF8Encoding($false)))
                $parent = $task.Path.Substring(0, $task.Path.LastIndexOf('\') + 1)
                $taskRows += [pscustomobject]@{ TaskName = $task.Name; TaskPath = $parent; File = $file }
            }
            catch {
                Write-Log "Could not export task $($task.Path): $($_.Exception.Message)" 'WARN'
            }
        }
        foreach ($sub in @($folder.GetFolders(0))) { $queue.Enqueue($sub) }
    }
    if ($taskRows.Count -gt 0) {
        $taskRows | Export-Csv -LiteralPath (Join-Path $SystemDir 'scheduled-tasks.csv') -NoTypeInformation -Encoding UTF8
    }
    Write-Log "Scheduled tasks recorded: $($taskRows.Count)" 'OK'
}
catch {
    Write-Log "Scheduled task inventory failed: $($_.Exception.Message)" 'WARN'
}

# ------------------------------------------------------------------
# 6. environment variables
# ------------------------------------------------------------------
try {
    $userEnv = [Environment]::GetEnvironmentVariables('User')
    Save-Json -Object $userEnv -Path (Join-Path $SystemDir 'env-user.json')
    Write-Log "User environment variables recorded: $($userEnv.Count)" 'OK'
}
catch {
    Write-Log "User environment variables failed: $($_.Exception.Message)" 'WARN'
}

if ($script:IsAdmin) {
    try {
        $machineEnv = [Environment]::GetEnvironmentVariables('Machine')
        Save-Json -Object $machineEnv -Path (Join-Path $SystemDir 'env-machine.json')
        Write-Log "Machine environment variables recorded: $($machineEnv.Count)" 'OK'
    }
    catch {
        Write-Log "Machine environment variables failed: $($_.Exception.Message)" 'WARN'
    }
}

# ------------------------------------------------------------------
# 7. settings
# ------------------------------------------------------------------
try {
    $settings = [ordered]@{
        CapturedAt     = (Get-Date).ToString('o')
        ComputerName   = $env:COMPUTERNAME
        TimeZone       = (Get-TimeZone).Id
        PowerPlan      = $null
        RDPEnabled     = $null
        UserProfile    = $UserProfile
    }
    $planOutput = (& powercfg.exe /getactivescheme) -join ' '
    $guidMatch = [regex]::Match($planOutput, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($guidMatch.Success) { $settings.PowerPlan = $guidMatch.Value }

    try {
        $rdpKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        $deny = (Get-ItemProperty -Path $rdpKey -Name fDenyTSConnections -ErrorAction Stop).fDenyTSConnections
        $settings.RDPEnabled = ($deny -eq 0)
    }
    catch {
        Write-Log "Reading RDP state failed: $($_.Exception.Message)" 'WARN'
    }

    Save-Json -Object $settings -Path (Join-Path $SystemDir 'settings.json')
    Write-Log "Settings recorded (timezone $($settings.TimeZone), RDP enabled: $($settings.RDPEnabled))" 'OK'
}
catch {
    Write-Log "Settings capture failed: $($_.Exception.Message)" 'WARN'
}

# ------------------------------------------------------------------
# 8. personal files (optional)
# ------------------------------------------------------------------
$filesMap = @()
if ($IncludeFiles) {
    $folders = @('Desktop', 'Documents', 'Downloads', 'Music', 'Pictures', 'Videos')
    foreach ($folder in $folders) {
        $candidates = @(
            (Join-Path $UserProfile $folder),
            (Join-Path $UserProfile "OneDrive\$folder")
        )
        foreach ($source in $candidates) {
            if (Test-Path -LiteralPath $source -PathType Container) {
                $label = $folder
                if ($source -like '*OneDrive*') { $label = "OneDrive_$folder" }
                $dest = Join-Path $FilesDir $label
                if (Invoke-Robocopy -Source $source -Dest $dest -Label "Files/$label") {
                    $filesMap += [pscustomobject]@{ Source = $source; BackupFolder = $dest }
                }
            }
        }
    }

    foreach ($extra in $ExtraPaths) {
        if (Test-Path -LiteralPath $extra -PathType Container) {
            $label = "Extra_" + ((Split-Path -Leaf $extra) -replace '[^\w\-]', '_')
            $dest = Join-Path $FilesDir $label
            if (Invoke-Robocopy -Source $extra -Dest $dest -Label "Files/$label") {
                $filesMap += [pscustomobject]@{ Source = $extra; BackupFolder = $dest }
            }
        }
        else {
            Write-Log "Extra path not found: $extra" 'WARN'
        }
    }

    if ($filesMap.Count -gt 0) {
        $filesMap | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $SystemDir 'files-map.json') -Encoding UTF8
    }
    Write-Log "Personal folders copied: $($filesMap.Count)" 'OK'
}
else {
    Write-Log 'Personal files not copied (use -IncludeFiles to include them)'
}

# ------------------------------------------------------------------
# 9. manifest
# ------------------------------------------------------------------
$manifest = [ordered]@{
    CreatedAt        = (Get-Date).ToString('o')
    Creator          = "$env:USERDOMAIN\$env:USERNAME"
    ComputerName     = $env:COMPUTERNAME
    IsAdmin          = $script:IsAdmin
    HasWingetExport  = Test-Path -LiteralPath $wingetJson
    HasPrograms      = Test-Path -LiteralPath (Join-Path $AppsDir 'programs.csv')
    HasFeatures      = (Test-Path -LiteralPath (Join-Path $SystemDir 'optional-features.csv')) -or (Test-Path -LiteralPath (Join-Path $SystemDir 'optional-features-dism.txt'))
    HasTasks         = Test-Path -LiteralPath (Join-Path $SystemDir 'scheduled-tasks.csv')
    HasFiles         = ($filesMap.Count -gt 0)
    FileFolders      = @($filesMap | ForEach-Object { Split-Path -Leaf $_.BackupFolder })
}
Save-Json -Object $manifest -Path (Join-Path $BackupDir 'manifest.json')

$sizeGB = [math]::Round((Get-ChildItem -LiteralPath $BackupDir -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1GB, 2)
Write-Log "Backup complete: $BackupDir ($sizeGB GB)" 'OK'
Write-Log 'To restore, run: .\Restore-PC.ps1 -BackupPath "<folder above>"'

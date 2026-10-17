<#
.SYNOPSIS
    Turns on Remote Desktop and prepares a local account for it, in one shot.

.DESCRIPTION
    Designed for machines that must be reachable over RDP with as little manual
    work as possible - fresh Windows installs, CI/build runner VMs, lab boxes.

    It will:
      * create the local user if it does not exist (and enable it if it does)
      * optionally put the user in the Administrators group
      * enable Remote Desktop (fDenyTSConnections = 0)
      * move RDP to another port if you ask for one
      * enable or disable Network Level Authentication
      * create a firewall rule for the RDP port (works on any Windows language)
      * start the Remote Desktop service
      * remove idle/disconnect timeouts and power timeouts so a session stays up
      * print the address to connect to

    Everything is applied with -WhatIf support: run with -WhatIf first to see
    exactly what would change.

.PARAMETER User
    Local account to prepare. Default: the name of the account running the script.

.PARAMETER Password
    Password for that account. Only needed when the account has to be created,
    or when you want to reset an existing password.

.PARAMETER GeneratePassword
    Create a strong random password instead of passing one in. It is printed at
    the end so you can copy it.

.PARAMETER Administrators
    Add the account to the local Administrators group.

.PARAMETER Port
    TCP port for RDP. Default 3389.

.PARAMETER RequireNla
    Require Network Level Authentication. Default is off, which is friendlier for
    scripted/automated access but less strict.

.PARAMETER SecurityLayer
    RDP security layer: 0 = RDP (legacy clients), 1 = negotiate, 2 = TLS only.
    Leave out to not touch this setting.

.PARAMETER FirewallRuleName
    Name for the firewall rule that opens the RDP port. Default: RDP-<port>.

.PARAMETER RecreateUser
    Delete the local account first and create it fresh. Needs -Password or
    -GeneratePassword.

.PARAMETER KeepTimeouts
    Leave the RDP idle/disconnect timeouts and the power timeouts alone.

.PARAMETER NoElevate
    Do not try to relaunch the script as Administrator.

.PARAMETER RestartService
    Restart the Remote Desktop service after changing the port or NLA.
    Warning: this drops existing RDP sessions, including the one you are on.

.EXAMPLE
    .\Enable-RDP.ps1 -WhatIf

.EXAMPLE
    .\Enable-RDP.ps1 -User RDP -GeneratePassword -Administrators

.EXAMPLE
    .\Enable-RDP.ps1 -User ci -Password 'Str0ng!Passw0rd' -Port 3390 -RestartService
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$User = $env:USERNAME,
    [string]$Password,
    [switch]$GeneratePassword,
    [switch]$Administrators,
    [int]$Port = 3389,
    [switch]$RequireNla,
    [int]$SecurityLayer = -1,
    [string]$FirewallRuleName,
    [switch]$RecreateUser,
    [switch]$KeepTimeouts,
    [switch]$NoElevate,
    [switch]$RestartService
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
    $prefix = if ($WhatIfPreference) { '[what-if] ' } else { '' }
    $line = '[{0}] {1,-5} {2}{3}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $prefix, $Message
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}

function Test-IsAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RandomIndex {
    param([Parameter(Mandatory = $true)][int]$Max)
    $bytes = New-Object byte[] 4
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    return [int]([BitConverter]::ToUInt32($bytes, 0) % [uint32]$Max)
}

function New-RandomPassword {
    param([int]$Length = 20)
    $upper  = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower  = 'abcdefghijkmnopqrstuvwxyz'
    $digit  = '23456789'
    $symbol = '!@#%*+_=-'
    $all    = $upper + $lower + $digit + $symbol

    $chars = New-Object System.Collections.Generic.List[char]
    foreach ($set in @($upper, $lower, $digit, $symbol)) {
        $chars.Add($set[((Get-RandomIndex -Max $set.Length))])
    }
    while ($chars.Count -lt $Length) {
        $chars.Add($all[((Get-RandomIndex -Max $all.Length))])
    }
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = Get-RandomIndex -Max ($i + 1)
        $tmp = $chars[$i]
        $chars[$i] = $chars[$j]
        $chars[$j] = $tmp
    }
    return -join $chars
}

# ------------------------------------------------------------------
# elevation
# ------------------------------------------------------------------
$scriptPath = $PSCommandPath
if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
$isAdmin = Test-IsAdmin

if (-not $isAdmin) {
    if ($NoElevate) {
        Write-Log 'Not running as Administrator (-NoElevate given). Registry, service and firewall changes will fail.' 'WARN'
    }
    else {
        Write-Log 'Not running as Administrator - relaunching elevated (accept the UAC prompt)...' 'WARN'
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"")
        foreach ($entry in $PSBoundParameters.GetEnumerator()) {
            if ($entry.Value -is [switch]) {
                if ($entry.Value.IsPresent) { $arguments += "-$($entry.Key)" }
            }
            else {
                $arguments += "-$($entry.Key)"
                $arguments += "`"$($entry.Value)`""
            }
        }
        try {
            $hostExe = (Get-Process -Id $PID).Path
            if (-not $hostExe) { $hostExe = 'powershell.exe' }
            Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList $arguments -Wait
            exit 0
        }
        catch {
            Write-Log "Elevation was cancelled or failed: $($_.Exception.Message)" 'ERROR'
            Write-Host 'Re-run this script from an Administrator PowerShell, or pass -NoElevate to see what it would do.' -ForegroundColor Red
            exit 1
        }
    }
}

# ------------------------------------------------------------------
# 1. the account
# ------------------------------------------------------------------
if ($SecurityLayer -lt -1 -or $SecurityLayer -gt 2) {
    Write-Log 'SecurityLayer must be -1 (leave unchanged), 0 (RDP), 1 (negotiate) or 2 (TLS)' 'ERROR'
    exit 1
}

$generated = $null
$passwordToUse = $Password
if ($GeneratePassword) {
    $passwordToUse = New-RandomPassword -Length 20
    $generated = $passwordToUse
}

$isDomainController = $false
try {
    # registry check instead of Win32_ComputerSystem: WMI can be slow or wedged
    $productType = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ProductOptions' -Name ProductType -ErrorAction Stop).ProductType
    $isDomainController = ($productType -eq 'LanmanNT')
}
catch {
    Write-Log "Could not read the machine role: $($_.Exception.Message)" 'WARN'
}

$account = $null
if (-not $isDomainController) {
    $account = Get-LocalUser -Name $User -ErrorAction SilentlyContinue
}

if ($RecreateUser -and $account -and -not $isDomainController) {
    if (-not $passwordToUse) {
        Write-Log "-RecreateUser needs -Password or -GeneratePassword" 'ERROR'
        exit 1
    }
    if ($PSCmdlet.ShouldProcess("local user '$User'", 'Delete (recreate)')) {
        try {
            Remove-LocalUser -Name $User -ErrorAction Stop
            $account = $null
            Write-Log "Local user '$User' removed, recreating it" 'OK'
        }
        catch {
            Write-Log "Removing user '$User' failed: $($_.Exception.Message)" 'WARN'
        }
    }
}

if ($isDomainController) {
    Write-Log "This is a domain controller - create the account '$User' in Active Directory instead" 'WARN'
}
elseif (-not $account) {
    if (-not $passwordToUse) {
        Write-Log "Account '$User' does not exist and no -Password or -GeneratePassword was given" 'ERROR'
        exit 1
    }
    if ($PSCmdlet.ShouldProcess("local user '$User'", 'Create')) {
        try {
            $secure = ConvertTo-SecureString $passwordToUse -AsPlainText -Force
            New-LocalUser -Name $User -Password $secure -AccountNeverExpires -PasswordNeverExpires -Description 'Remote desktop account' -ErrorAction Stop | Out-Null
            Write-Log "Local user '$User' created" 'OK'
        }
        catch {
            Write-Log "Creating user '$User' failed: $($_.Exception.Message)" 'ERROR'
            exit 1
        }
    }
}
else {
    Write-Log "Local user '$User' already exists"
    if (-not $account.Enabled) {
        if ($PSCmdlet.ShouldProcess("local user '$User'", 'Enable')) {
            try {
                Enable-LocalUser -Name $User -ErrorAction Stop
                Write-Log "Local user '$User' enabled" 'OK'
            }
            catch {
                Write-Log "Enabling user '$User' failed: $($_.Exception.Message)" 'WARN'
            }
        }
    }
    if ($Password) {
        if ($PSCmdlet.ShouldProcess("local user '$User'", 'Reset password')) {
            try {
                $secure = ConvertTo-SecureString $Password -AsPlainText -Force
                Set-LocalUser -Name $User -Password $secure -PasswordNeverExpires $true -ErrorAction Stop
                Write-Log "Password reset for '$User'" 'OK'
            }
            catch {
                Write-Log "Password reset for '$User' failed: $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

if ($Administrators -and -not $isDomainController) {
    if ($PSCmdlet.ShouldProcess("local group 'Administrators'", "Add '$User'")) {
        try {
            $already = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop | Where-Object { $_.Name -like "*\$User" })
            if ($already.Count -eq 0) {
                Add-LocalGroupMember -Group 'Administrators' -Member $User -ErrorAction Stop
                Write-Log "'$User' added to Administrators" 'OK'
            }
            else {
                Write-Log "'$User' is already in Administrators"
            }
        }
        catch {
            Write-Log "Adding '$User' to Administrators failed: $($_.Exception.Message)" 'WARN'
        }
    }
}

if (-not $passwordToUse -and -not $account) {
    Write-Log 'No password was set - the account cannot sign in until it has one' 'WARN'
}

if (-not $isDomainController) {
    if ($PSCmdlet.ShouldProcess("local group 'Remote Desktop Users'", "Add '$User'")) {
        try {
            $already = @(Get-LocalGroupMember -Group 'Remote Desktop Users' -ErrorAction Stop | Where-Object { $_.Name -like "*\$User" })
            if ($already.Count -eq 0) {
                Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $User -ErrorAction Stop
                Write-Log "'$User' added to Remote Desktop Users" 'OK'
            }
            else {
                Write-Log "'$User' is already in Remote Desktop Users"
            }
        }
        catch {
            Write-Log "Adding '$User' to Remote Desktop Users failed: $($_.Exception.Message)" 'WARN'
        }
    }

    # a locked out account cannot sign in over RDP; stale clients lock accounts fast
    try {
        $local = [ADSI]"WinNT://$env:COMPUTERNAME/$User,user"
        if ($local.IsAccountLocked) {
            if ($PSCmdlet.ShouldProcess("local user '$User'", 'Unlock')) {
                $local.IsAccountLocked = $false
                $local.SetInfo()
                Write-Log "Account '$User' was locked out - unlocked" 'OK'
            }
        }
        else {
            Write-Log "Account '$User' is not locked out"
        }
    }
    catch {
        Write-Log "Checking the lockout state of '$User' failed: $($_.Exception.Message)" 'WARN'
    }
}

# ------------------------------------------------------------------
# 2. Remote Desktop registry settings
# ------------------------------------------------------------------
$tsKey   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$rdpTcp  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'

$changesNeedingRestart = @()

if ($PSCmdlet.ShouldProcess('Remote Desktop', 'Enable')) {
    try {
        $deny = (Get-ItemProperty -Path $tsKey -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
        if ($deny -ne 0) {
            Set-ItemProperty -Path $tsKey -Name fDenyTSConnections -Value 0 -ErrorAction Stop
            Write-Log 'Remote Desktop enabled (fDenyTSConnections = 0)' 'OK'
        }
        else {
            Write-Log 'Remote Desktop was already enabled'
        }
        # keep an RDP session alive when a console session appears (runner VMs, labs)
        Set-ItemProperty -Path $tsKey -Name fSingleSessionPerUser -Value 0 -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log "Enabling Remote Desktop failed: $($_.Exception.Message)" 'ERROR'
    }
}

if ($PSCmdlet.ShouldProcess("RDP listener port -> $Port", 'Set')) {
    try {
        $currentPort = (Get-ItemProperty -Path $rdpTcp -Name PortNumber -ErrorAction SilentlyContinue).PortNumber
        if ($currentPort -ne $Port) {
            Set-ItemProperty -Path $rdpTcp -Name PortNumber -Value $Port -ErrorAction Stop
            Write-Log "RDP port changed from $currentPort to $Port" 'OK'
            $changesNeedingRestart += "port ($currentPort -> $Port)"
        }
        else {
            Write-Log "RDP port is already $Port"
        }
    }
    catch {
        Write-Log "Setting the RDP port failed: $($_.Exception.Message)" 'ERROR'
    }
}

$nlaWanted = if ($RequireNla) { 1 } else { 0 }
if ($PSCmdlet.ShouldProcess("Network Level Authentication -> $(if ($RequireNla) { 'required' } else { 'not required' })", 'Set')) {
    try {
        $currentNla = (Get-ItemProperty -Path $rdpTcp -Name UserAuthentication -ErrorAction SilentlyContinue).UserAuthentication
        if ($currentNla -ne $nlaWanted) {
            Set-ItemProperty -Path $rdpTcp -Name UserAuthentication -Value $nlaWanted -ErrorAction Stop
            Write-Log "Network Level Authentication set to $nlaWanted" 'OK'
            $changesNeedingRestart += 'Network Level Authentication'
        }
        else {
            Write-Log "Network Level Authentication already $nlaWanted"
        }
    }
    catch {
        Write-Log "Setting Network Level Authentication failed: $($_.Exception.Message)" 'WARN'
    }
}

if ($SecurityLayer -ge 0) {
    if ($PSCmdlet.ShouldProcess("RDP security layer -> $SecurityLayer", 'Set')) {
        try {
            $currentLayer = (Get-ItemProperty -Path $rdpTcp -Name SecurityLayer -ErrorAction SilentlyContinue).SecurityLayer
            if ($currentLayer -ne $SecurityLayer) {
                Set-ItemProperty -Path $rdpTcp -Name SecurityLayer -Value $SecurityLayer -ErrorAction Stop
                Write-Log "RDP security layer set to $SecurityLayer" 'OK'
                $changesNeedingRestart += 'security layer'
            }
            else {
                Write-Log "RDP security layer already $SecurityLayer"
            }
        }
        catch {
            Write-Log "Setting the RDP security layer failed: $($_.Exception.Message)" 'WARN'
        }
    }
}

if (-not $KeepTimeouts) {
    if ($PSCmdlet.ShouldProcess('RDP idle and disconnect timeouts', 'Remove')) {
        foreach ($pair in @(
                @{ Path = $rdpTcp; Name = 'MaxIdleTime'; Value = 0 },
                @{ Path = $rdpTcp; Name = 'MaxDisconnectionTime'; Value = 0 },
                @{ Path = $rdpTcp; Name = 'MaxConnectionTime'; Value = 0 },
                @{ Path = $tsKey;  Name = 'MaxIdleTime'; Value = 0 }
            )) {
            try {
                Set-ItemProperty -Path $pair.Path -Name $pair.Name -Value $pair.Value -ErrorAction Stop
            }
            catch {
                Write-Log "$($pair.Name) could not be set: $($_.Exception.Message)" 'WARN'
            }
        }
        Write-Log 'RDP idle/disconnect timeouts removed (0 = never)' 'OK'

        $null = & powercfg.exe /change monitor-timeout-ac 0 standby-timeout-ac 0 hibernate-timeout-ac 0 disk-timeout-ac 0 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Log 'Power timeouts removed (screen/standby/hibernate/disk)' 'OK' }
        else { Write-Log 'Power timeouts could not be changed on this machine' 'WARN' }
    }
}

# ------------------------------------------------------------------
# 3. firewall
# ------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess("inbound TCP $Port", 'Allow in firewall')) {
    $ruleName = if ($FirewallRuleName) { $FirewallRuleName } else { "RDP-$Port" }
    # netsh instead of New-NetFirewallRule: the Net* cmdlets go through CIM,
    # which is slow or unavailable on some machines.
    try {
        $null = & netsh.exe advfirewall firewall show rule name="$ruleName" 2>&1
        if ($LASTEXITCODE -ne 0) {
            $null = & netsh.exe advfirewall firewall add rule name="$ruleName" dir=in action=allow protocol=TCP localport=$Port profile=any 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Log "Firewall rule '$ruleName' created (inbound TCP $Port)" 'OK' }
            else { Write-Log "Creating firewall rule '$ruleName' failed (netsh exit code $LASTEXITCODE)" 'ERROR' }
        }
        else {
            Write-Log "Firewall rule '$ruleName' already exists"
        }
    }
    catch {
        Write-Log "Firewall rule '$ruleName' failed: $($_.Exception.Message)" 'ERROR'
    }

    # built-in rules, so the standard port works even if the group is localized
    try {
        $null = & netsh.exe advfirewall firewall set rule group="Remote Desktop" new enable=Yes 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Log 'Built-in Remote Desktop firewall rules enabled' 'OK' }
        else { Write-Log 'Built-in "Remote Desktop" rule group not found (localized name?) - the custom rule above covers the port' 'WARN' }
    }
    catch {
        Write-Log "Enabling the built-in Remote Desktop rules failed: $($_.Exception.Message)" 'WARN'
    }
}

# ------------------------------------------------------------------
# 4. service
# ------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess("service 'TermService'", 'Start and set to Automatic')) {
    try {
        Set-Service -Name TermService -StartupType Automatic -ErrorAction Stop
        if ((Get-Service -Name TermService).Status -ne 'Running') {
            Start-Service -Name TermService -ErrorAction Stop
            Write-Log 'Remote Desktop service started' 'OK'
        }
        else {
            Write-Log 'Remote Desktop service already running'
        }
    }
    catch {
        Write-Log "Starting the Remote Desktop service failed: $($_.Exception.Message)" 'ERROR'
    }
}

if ($changesNeedingRestart.Count -gt 0) {
    if ($RestartService) {
        if ($PSCmdlet.ShouldProcess('service TermService', 'Restart')) {
            Write-Log 'Restarting the Remote Desktop service - existing RDP sessions will drop' 'WARN'
            try {
                Restart-Service -Name TermService -Force -ErrorAction Stop
                Write-Log 'Remote Desktop service restarted' 'OK'
            }
            catch {
                Write-Log "Restarting the Remote Desktop service failed: $($_.Exception.Message)" 'WARN'
            }
        }
    }
    else {
        Write-Log "Changed: $($changesNeedingRestart -join ', '). Restart the service (Restart-Service TermService -Force) or the machine for it to take effect, or pass -RestartService." 'WARN'
    }
}

# ------------------------------------------------------------------
# 5. report
# ------------------------------------------------------------------
Write-Host ''
Write-Host 'Remote Desktop setup' -ForegroundColor Cyan
Write-Host '--------------------'
Write-Host ("  User          : {0}{1}" -f $User, $(if ($Administrators) { ' (Administrators)' } else { '' }))
Write-Host ("  Port          : {0}" -f $Port)
Write-Host ("  NLA required  : {0}" -f ([bool]$RequireNla))
if ($SecurityLayer -ge 0) {
    Write-Host ("  Security layer: {0}" -f $SecurityLayer)
}
Write-Host ("  Machine       : {0}" -f $env:COMPUTERNAME)

$addresses = @()
try {
    # DNS first: Get-NetIPAddress needs CIM, which can be slow or unavailable
    $addresses = @([System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.IPAddressToString -notlike '127.*' } |
        Select-Object -ExpandProperty IPAddressToString)
}
catch {
    Write-Log "Could not list IP addresses with DNS: $($_.Exception.Message)" 'WARN'
}
if ($addresses.Count -eq 0 -and (Get-Command Get-WmiObject -ErrorAction SilentlyContinue)) {
    try {
        $addresses = @(Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' -ErrorAction Stop |
            ForEach-Object { $_.IPAddress } |
            Where-Object { $_ -and $_ -notlike '127.*' -and $_ -notlike '*:*' })
    }
    catch {
        Write-Log "Could not list IP addresses with WMI: $($_.Exception.Message)" 'WARN'
    }
}

if ($addresses.Count -gt 0) {
    Write-Host '  Connect with  :'
    foreach ($address in $addresses) {
        Write-Host ("                  mstsc /v:{0}:{1}" -f $address, $Port) -ForegroundColor Green
        Write-Host ("                  {0}:{1}" -f $address, $Port)
    }
}
if ($generated) {
    Write-Host ''
    Write-Host ("  Generated password for '{0}': {1}" -f $User, $generated) -ForegroundColor Yellow
    Write-Host '  Save it now - it is not stored anywhere.' -ForegroundColor Yellow
    if (-not $env:CI -and -not $env:GITHUB_ACTIONS) {
        # an interactive run has no log to scroll back to, so keep a copy on disk
        try {
            $passwordFile = Join-Path $env:TEMP 'Enable-RDP-generated-password.txt'
            @(
                "Machine : $env:COMPUTERNAME"
                "User    : $User"
                "Password: $generated"
                "Created : $(Get-Date -Format o)"
            ) | Set-Content -LiteralPath $passwordFile -Encoding UTF8
            Write-Host "  Also written to $passwordFile - delete it once you have it." -ForegroundColor Yellow
        }
        catch {
            Write-Log "Could not save the generated password to disk: $($_.Exception.Message)" 'WARN'
        }
    }
}
if ($WhatIfPreference) {
    Write-Host ''
    Write-Host '  This was a -WhatIf run: nothing was changed.' -ForegroundColor Yellow
}

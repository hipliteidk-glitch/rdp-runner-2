# Boot an emulator, install RunLeft.apk and grab a screenshot.
$ErrorActionPreference = 'Stop'

$SDK_OLD = 'C:\Android\android-sdk'
$SDK     = 'C:\Users\RDP\android-sdk'
$ADB     = Join-Path $SDK_OLD 'platform-tools\adb.exe'
$EMU     = Join-Path $SDK 'emulator\emulator.exe'
if (-not (Test-Path $EMU)) { $EMU = Join-Path $SDK_OLD 'emulator\emulator.exe' }
$AVDMGR  = Join-Path $SDK_OLD 'cmdline-tools\latest\bin\avdmanager.bat'
$APK     = 'C:\Users\RDP\Documents\Default Project\countdown-apk\RunLeft.apk'
$SHOT    = 'C:\Users\RDP\Documents\Default Project\countdown-apk\screenshot.png'

$env:ANDROID_SDK_ROOT = $SDK
$env:ANDROID_HOME     = $SDK
$env:JAVA_HOME       = 'C:\Users\RDP\AppData\Local\Temp\1\opencode\jdk17\jdk-17.0.20.1+1'
$env:PATH            = "$env:JAVA_HOME\bin;$env:PATH"

Write-Host '==> creating AVD'
Get-ChildItem "$env:USERPROFILE\.android\avd" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'runleft*' } | ForEach-Object { Remove-Item $_.FullName -Recurse -Force }
"no" | & $AVDMGR create avd -n runleft -k 'system-images;android-34;default;x86_64' --device pixel_5 2>&1 | Out-String | Write-Host

Write-Host '==> booting emulator (headless)'
$proc = Start-Process -FilePath $EMU -PassThru -ArgumentList @(
    '-avd', 'runleft',
    '-no-window', '-no-audio', '-no-boot-anim', '-no-snapshot',
    '-gpu', 'swiftshader_indirect',
    '-accel', 'on',
    '-memory', '2048',
    '-cores', '2'
) -RedirectStandardOutput "$env:TEMP\emu-out.txt" -RedirectStandardError "$env:TEMP\emu-err.txt"
Write-Host "emulator pid: $($proc.Id)"

Write-Host '==> waiting for boot'
& $ADB wait-for-device
$booted = $false
for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep 5
    $state = (& $ADB shell getprop sys.boot_completed 2>$null) -join ''
    if ($state -match '1') { $booted = $true; break }
}
if (-not $booted) {
    Write-Host 'BOOT FAILED'
    Get-Content "$env:TEMP\emu-err.txt" -Tail 30 -ErrorAction SilentlyContinue
    exit 1
}
Write-Host 'booted'

Write-Host '==> installing'
& $ADB install -r -t $APK

Write-Host '==> launching'
& $ADB shell am start -n dev.opencode.runleft/.MainActivity
Start-Sleep 6

Write-Host '==> screenshot'
& $ADB exec-out screencap -p > $SHOT
Write-Host ("screenshot: {0:N0} bytes" -f (Get-Item $SHOT).Length)

Write-Host '==> app logcat'
& $ADB logcat -d -t 60 2>$null | Select-String -Pattern 'runleft|AndroidRuntime|FATAL' | Out-String | Write-Host

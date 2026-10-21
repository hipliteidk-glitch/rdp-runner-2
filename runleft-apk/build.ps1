# Build the 'Run Left' countdown APK with the SDK's aapt2/d8/apksigner (no Gradle, no network).
$ErrorActionPreference = 'Stop'

$SDK  = 'C:\Android\android-sdk'
$BT   = Join-Path $SDK 'build-tools\34.0.0'
$JAR  = Join-Path $SDK 'platforms\android-34\android.jar'
$JDK  = 'C:\Users\RDP\AppData\Local\Temp\1\opencode\jdk17\jdk-17.0.20.1+1'
$PROJ = 'C:\Users\RDP\Documents\Default Project\countdown-apk'
$OUT  = Join-Path $PROJ 'out'

Remove-Item $OUT -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $OUT, "$OUT\classes", "$OUT\dex" | Out-Null
Remove-Item (Join-Path $PROJ 'gen') -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $PROJ 'gen') | Out-Null

Set-Location $PROJ

Write-Host '==> aapt2 compile'
& "$BT\aapt2.exe" compile --dir res -o "$OUT\res.zip"
if ($LASTEXITCODE -ne 0) { throw 'aapt2 compile failed' }

Write-Host '==> aapt2 link'
& "$BT\aapt2.exe" link `
    -o "$OUT\base.apk" `
    -I $JAR `
    --manifest AndroidManifest.xml `
    --java gen `
    --min-sdk-version 24 `
    --target-sdk-version 34 `
    --version-code 1 `
    --version-name 1.0 `
    "$OUT\res.zip"
if ($LASTEXITCODE -ne 0) { throw 'aapt2 link failed' }

Write-Host '==> javac'
& "$JDK\bin\javac.exe" --release 8 -nowarn -classpath $JAR -d "$OUT\classes" `
    (Join-Path $PROJ 'gen\dev\opencode\runleft\R.java') `
    (Join-Path $PROJ 'src\MainActivity.java')
if ($LASTEXITCODE -ne 0) { throw 'javac failed' }

Write-Host '==> d8'
& "$JDK\bin\jar.exe" cf "$OUT\classes.jar" -C "$OUT\classes" .
if ($LASTEXITCODE -ne 0) { throw 'jar failed' }
& "$JDK\bin\java.exe" -cp "$BT\lib\d8.jar" com.android.tools.r8.D8 `
    --lib $JAR --min-api 24 --output "$OUT\dex" "$OUT\classes.jar"
if ($LASTEXITCODE -ne 0) { throw 'd8 failed' }

Write-Host '==> put classes.dex into the apk'
$py = @'
import shutil, zipfile, os
base = r"C:\Users\RDP\Documents\Default Project\countdown-apk\out\base.apk"
dex  = r"C:\Users\RDP\Documents\Default Project\countdown-apk\out\dex\classes.dex"
with zipfile.ZipFile(base, "a", zipfile.ZIP_DEFLATED) as z:
    z.write(dex, "classes.dex")
print("classes.dex added:", os.path.getsize(dex), "bytes")
'@
$py | Out-File -Encoding utf8 "$OUT\adddex.py"
& python "$OUT\adddex.py"
if ($LASTEXITCODE -ne 0) { throw 'adding classes.dex failed' }

Write-Host '==> zipalign'
& "$BT\zipalign.exe" -f -p 4 "$OUT\base.apk" "$OUT\aligned.apk"
if ($LASTEXITCODE -ne 0) { throw 'zipalign failed' }

Write-Host '==> debug keystore'
$KS = "$OUT\debug.keystore"
if (-not (Test-Path $KS)) {
    & "$JDK\bin\keytool.exe" -genkeypair -v -keystore $KS -storepass android `
        -alias androiddebugkey -keypass android -keyalg RSA -keysize 2048 -validity 10000 `
        -dname 'CN=Android Debug,O=Android,C=US'
    if ($LASTEXITCODE -ne 0) { throw 'keytool failed' }
}

Write-Host '==> apksigner'
& "$JDK\bin\java.exe" -jar "$BT\lib\apksigner.jar" sign `
    --ks $KS --ks-pass pass:android --key-pass pass:android `
    --min-sdk-version 24 `
    --out "$PROJ\RunLeft.apk" "$OUT\aligned.apk"
if ($LASTEXITCODE -ne 0) { throw 'apksigner failed' }

Write-Host '==> verify'
& "$JDK\bin\java.exe" -jar "$BT\lib\apksigner.jar" verify --verbose "$PROJ\RunLeft.apk"
& "$BT\aapt2.exe" dump badging "$PROJ\RunLeft.apk" | Select-Object -First 12

Write-Host ("APK: {0:N0} bytes" -f (Get-Item "$PROJ\RunLeft.apk").Length)

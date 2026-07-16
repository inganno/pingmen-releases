<#
.SYNOPSIS
  Podepsaný Pingmen release (IL2CPP) — interaktivní. Zeptá se na hesla ke keystoru (nikam se
  neukládají), postaví signed APK, volitelně nainstaluje na zařízení a/nebo vyhodí na web.

.DESCRIPTION
  Nahrazuje ruční setování 4 env proměnných. Hesla se zadávají jako SecureString → předají se
  jen child Unity procesu přes env a po buildu se z env vymažou. Keystore je fixní
  (.pingmen-keys\pingmen-release.keystore). Výstup = Builds\pingmen-release-<datum>.apk (pojmenování,
  které čeká publish-apk.ps1).

.EXAMPLE
  .\release.ps1 -Device "192.168.0.226:5555"
  Postaví signed release a nainstaluje na TV. (Bez publishe.)

.EXAMPLE
  .\release.ps1 -Device "192.168.0.226:5555" -Publish
  Postaví, nainstaluje na TV a vyhodí na web (GitHub release → pingmen.games/download/apk).

.EXAMPLE
  .\release.ps1 -Publish -SkipBuild
  Jen publishne poslední už postavený release APK.
#>
param(
  [string]$Device = "",     # adb zařízení pro install (např. TV 192.168.0.226:5555); prázdné = neinstalovat
  [switch]$Publish,         # po buildu spustit publish-apk.ps1 (GitHub release → web) — VEŘEJNÁ akce
  [switch]$SkipBuild        # přeskočit build (jen install/publish existujícího pingmen-release-*.apk)
)

$ErrorActionPreference = "Stop"
$UnityProj = "D:\PROJECTS\INGANNO\Pingmen\Pingmen-unity"
$Unity     = "C:\Program Files\Unity\Hub\Editor\6000.4.4f1\Editor\Unity.exe"
$Adb       = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$Keystore  = "$env:USERPROFILE\.pingmen-keys\pingmen-release.keystore"
$BuildsDir = Join-Path $UnityProj "Builds"
$Log       = Join-Path $BuildsDir "unity-build.log"
$ApkOut    = Join-Path $BuildsDir ("pingmen-release-" + (Get-Date -Format "yyyy-MM-dd") + ".apk")

function Read-Plain([string]$prompt) {
  $sec = Read-Host $prompt -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

if (-not $SkipBuild) {
  if (-not (Test-Path $Keystore)) { throw "Keystore nenalezen: $Keystore" }

  Write-Host "=== Podepsaný release build ===" -ForegroundColor Cyan
  $alias = Read-Host "Keystore alias (Enter = pingmen)"
  if ([string]::IsNullOrWhiteSpace($alias)) { $alias = "pingmen" }
  $ksPass = Read-Plain "Heslo keystore"
  $alPass = Read-Plain "Heslo aliasu (Enter = stejné jako keystore)"
  if ([string]::IsNullOrEmpty($alPass)) { $alPass = $ksPass }

  # Zavři Unity editor (drží project lock → batchmode build by se nespustil).
  $ed = Get-Process Unity -ErrorAction SilentlyContinue
  if ($ed) {
    Write-Host "Ukončuji Unity editor..." -ForegroundColor Yellow
    $ed | Stop-Process -Force
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Process Unity -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
  }

  $env:PINGMEN_KEYSTORE_PATH = $Keystore
  $env:PINGMEN_KEYSTORE_PASS = $ksPass
  $env:PINGMEN_KEYALIAS_NAME = $alias
  $env:PINGMEN_KEYALIAS_PASS = $alPass
  $env:PINGMEN_APK_OUT       = $ApkOut
  # Avast SSL inspection → Unity/Gradle cacerts neznají Avast cert; použij Windows-ROOT store (viz build-tv.ps1).
  $env:JAVA_TOOL_OPTIONS     = "-Djavax.net.ssl.trustStoreType=Windows-ROOT -Djavax.net.ssl.trustStore=NUL"

  Remove-Item $ApkOut -ErrorAction SilentlyContinue
  Remove-Item $Log -ErrorAction SilentlyContinue
  Write-Host "Building signed IL2CPP release (~3 min)..." -ForegroundColor Cyan
  & $Unity -batchmode -nographics -projectPath $UnityProj -buildTarget Android `
    -executeMethod Pingmen.Editor.BuildScript.AndroidRelease -logFile $Log -quit | Out-Null

  # Unity.exe je GUI-subsystem → odpojí se od PowerShellu, build běží na pozadí. Čekej až zmizí proces
  # A vznikne APK; průběžně kontroluj log na chybu (jinak by se čekalo do nekonečna).
  while ($true) {
    Start-Sleep -Seconds 3
    if ((Test-Path $Log) -and (Select-String -Path $Log -Pattern "Build Failed|error CS\d|Release build vyžaduje" -Quiet -ErrorAction SilentlyContinue)) {
      throw "Build SELHAL — viz $Log (špatné heslo/alias?)."
    }
    $running = Get-Process Unity -ErrorAction SilentlyContinue
    if (-not $running -and (Test-Path $ApkOut)) { break }
    if (-not $running -and -not (Test-Path $ApkOut)) { throw "Unity skončil, ale APK nevzniklo — viz $Log." }
  }

  # Vymaž hesla z env (ať nezůstanou v session).
  Remove-Item Env:PINGMEN_KEYSTORE_PASS, Env:PINGMEN_KEYALIAS_PASS -ErrorAction SilentlyContinue
  $sizeMB = [math]::Round((Get-Item $ApkOut).Length / 1MB, 1)
  Write-Host "OK: $ApkOut ($sizeMB MB)" -ForegroundColor Green
}

if ($Device) {
  Write-Host "=== Install na $Device ===" -ForegroundColor Cyan
  & $Adb connect $Device | Out-Host
  $target = if ($SkipBuild) {
    (Get-ChildItem $BuildsDir -Filter "pingmen-release-*.apk" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
  } else { $ApkOut }
  & $Adb -s $Device install -r $target | Out-Host
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Install -r selhal (nejspíš jiný podpis než dosud nainstalovaný) → uninstall + install:" -ForegroundColor Yellow
    & $Adb -s $Device uninstall com.inganno.pingmen | Out-Host
    & $Adb -s $Device install $target | Out-Host
  }
}

if ($Publish) {
  Write-Host "=== Publish na web (GitHub release) ===" -ForegroundColor Cyan
  & (Join-Path $PSScriptRoot "publish-apk.ps1")
}

Write-Host ""
Write-Host "HOTOVO." -ForegroundColor Green
Write-Host "→ Nezapomeň COMMITNOUT versionCode bump v Pingmen-unity/ProjectSettings.asset (release ho zvýšil)." -ForegroundColor Yellow
if (-not $Publish -and -not $SkipBuild) {
  Write-Host "→ Web publish: .\release.ps1 -Publish -SkipBuild" -ForegroundColor Gray
}

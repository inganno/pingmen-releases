<#
.SYNOPSIS
  Podepsaný Pingmen release (IL2CPP) — interaktivní. Zeptá se na hesla ke keystoru (nikam se
  neukládají), postaví signed APK, rozešle ho na CELOU flotilu zařízení a publikuje na web.

.DESCRIPTION
  Jeden podepsaný build = jeden stav všude. Default flow je proto:
    build → install na všechna zařízení z devices.ps1 → publish na web (s potvrzením).
  Dřív se instalovalo na jedno zařízení přes -Device a publish byl opt-in, takže veřejný
  download uměl zůstat několik verzí pozadu (2026-07-29: vc4 se ven nikdy nedostal).

  Zařízení se hledá nejdřív po síti, při neúspěchu přes USB serial; po USB instalaci se
  automaticky obnoví `adb tcpip 5555`, takže tablet po restartu naskočí zpátky do Wi-Fi.
  Zařízení, které se nepodaří najít, se PŘESKOČÍ (ostatní se dokončí) a je vidět v souhrnu.

  Hesla se zadávají jako SecureString → předají se jen child Unity procesu přes env a po
  buildu se z env vymažou. Keystore je fixní (.pingmen-keys\pingmen-release.keystore).
  Výstup = Builds\pingmen-release-<datum>.apk (pojmenování, které čeká publish-apk.ps1).

.EXAMPLE
  .\release.ps1
  Kompletní flow: build → všechna zařízení → publish (zeptá se před odesláním ven).

.EXAMPLE
  .\release.ps1 -NoPublish
  Build + rozeslání na zařízení, veřejný download zůstane na staré verzi.

.EXAMPLE
  .\release.ps1 -Device "192.168.0.226:5555" -NoPublish
  Jen TV, nikam jinam. -Device bere i USB serial a dá se opakovat.

.EXAMPLE
  .\release.ps1 -SkipBuild -NoInstall
  Jen publikace posledního postaveného APK na web.
#>
param(
  [string[]]$Device = @(),  # cílová zařízení (IP:port nebo USB serial); prázdné = flotila z devices.ps1
  [switch]$NoInstall,       # přeskočit rozesílání na zařízení
  [switch]$NoPublish,       # přeskočit publikaci na web
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
$Package   = "com.inganno.pingmen"

function Read-Plain([string]$prompt) {
  $sec = Read-Host $prompt -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Rychlý test TCP portu. `adb connect` na spící zařízení umí viset ~20 s (filtrovaný port),
# tímhle se to zkrátí na $timeoutMs a flotila se projde svižně i s vypnutým tabletem.
function Test-Port([string]$adbHost, [int]$port, [int]$timeoutMs = 1500) {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect($adbHost, $port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs)) { return $false }
    $client.EndConnect($iar)
    return $true
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

# Stav zařízení v `adb devices` — "device" = připraveno, "unauthorized" = čeká dialog na tabletu,
# "" = nevidíme ho vůbec.
function Get-AdbState([string]$serial) {
  if ([string]::IsNullOrWhiteSpace($serial)) { return "" }
  $rows = & $Adb devices
  foreach ($row in $rows) {
    $parts = $row -split "\s+"
    if ($parts.Count -ge 2 -and $parts[0] -eq $serial) { return $parts[1] }
  }
  return ""
}

function Get-InstalledVersionCode([string]$target) {
  # Bez stderr redirectu — s $ErrorActionPreference = "Stop" umí PS 5.1 udělat z native stderr
  # terminating error a shodit celý běh kvůli neškodné hlášce.
  $out = & $Adb -s $target shell dumpsys package $Package
  foreach ($row in $out) {
    if ($row -match "versionCode=(\d+)") { return $Matches[1] }
  }
  return "?"
}

# versionCode, který má APK mít (release build ho zapsal do ProjectSettings). Slouží jen ke
# kontrole po instalaci — při -SkipBuild může být napřed, proto se jen hlásí, nezastavuje.
function Get-ExpectedVersionCode {
  $ps = Join-Path $UnityProj "ProjectSettings\ProjectSettings.asset"
  if (-not (Test-Path $ps)) { return "?" }
  $m = Select-String -Path $ps -Pattern "AndroidBundleVersionCode: (\d+)" | Select-Object -First 1
  if ($m) { return $m.Matches[0].Groups[1].Value }
  return "?"
}

# --- Build ---------------------------------------------------------------------------------

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

# APK, které se rozesílá a publikuje.
$Apk = if ($SkipBuild) {
  $newest = Get-ChildItem $BuildsDir -Filter "pingmen-release-*.apk" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $newest) { throw "Žádný pingmen-release-*.apk v $BuildsDir" }
  $newest.FullName
} else { $ApkOut }

# --- Rozeslání na zařízení -----------------------------------------------------------------

$results = @()

if (-not $NoInstall) {
  # Cíle: buď explicitní -Device, nebo flotila z devices.ps1 (mimo git kvůli veřejnému repu).
  $fleet = @()
  if ($Device.Count -gt 0) {
    foreach ($d in $Device) { $fleet += @{ Name = $d; Ip = $d; Usb = $d } }
  } else {
    $devicesFile = Join-Path $PSScriptRoot "devices.ps1"
    if (Test-Path $devicesFile) {
      $fleet = & $devicesFile
    } else {
      Write-Host "devices.ps1 chybí — nevím, kam instalovat. Zkopíruj devices.example.ps1 a vyplň zařízení," -ForegroundColor Yellow
      Write-Host "nebo použij -Device <IP:port|USB serial>." -ForegroundColor Yellow
    }
  }

  $expected = Get-ExpectedVersionCode
  foreach ($dev in $fleet) {
    Write-Host ""
    Write-Host "=== $($dev.Name) ===" -ForegroundColor Cyan

    # 1) síť, 2) USB fallback
    $target = ""
    $via = ""
    if (-not [string]::IsNullOrWhiteSpace($dev.Ip)) {
      $parts = $dev.Ip -split ":"
      $port = if ($parts.Count -gt 1) { [int]$parts[1] } else { 5555 }
      if (Test-Port $parts[0] $port) {
        & $Adb connect $dev.Ip | Out-Host
        if ((Get-AdbState $dev.Ip) -eq "device") { $target = $dev.Ip; $via = "wifi" }
      }
    }
    if (-not $target -and -not [string]::IsNullOrWhiteSpace($dev.Usb)) {
      $state = Get-AdbState $dev.Usb
      if ($state -eq "device") {
        $target = $dev.Usb
        $via = "usb"
      } elseif ($state -eq "unauthorized") {
        Write-Host "USB vidí zařízení, ale čeká na potvrzení dialogu 'Povolit ladění USB' na displeji." -ForegroundColor Yellow
      }
    }
    if (-not $target) {
      Write-Host "PŘESKOČENO — zařízení není dostupné po síti ani na USB." -ForegroundColor Yellow
      $results += [pscustomobject]@{ Name = $dev.Name; Via = "-"; Vysledek = "přeskočeno"; VersionCode = "-" }
      continue
    }

    Write-Host "Install ($via) → $target" -ForegroundColor Gray
    & $Adb -s $target install -r $Apk | Out-Host
    if ($LASTEXITCODE -ne 0) {
      # Žádný automatický uninstall — smazal by data appky (přihlášení, lokální stav). Od přechodu
      # na release podpis k tomuhle nemá docházet; když ano, stojí za to se podívat proč.
      Write-Host "INSTALL SELHAL. Nejčastěji jiný podpis (debug build na zařízení). Ruční cesta — POZOR, maže data:" -ForegroundColor Red
      Write-Host "  adb -s $target uninstall $Package; adb -s $target install `"$Apk`"" -ForegroundColor Red
      $results += [pscustomobject]@{ Name = $dev.Name; Via = $via; Vysledek = "SELHALO"; VersionCode = "-" }
      continue
    }

    $vc = Get-InstalledVersionCode $target
    $note = if ($expected -ne "?" -and $vc -ne $expected) { "$vc (čekáno $expected!)" } else { $vc }
    $results += [pscustomobject]@{ Name = $dev.Name; Via = $via; Vysledek = "OK"; VersionCode = $note }

    # Po USB instalaci obnov bezdrátové ladění, ať příště stačí síť (po restartu tabletu vypadne).
    if ($via -eq "usb" -and -not [string]::IsNullOrWhiteSpace($dev.Ip)) {
      Write-Host "Obnovuji bezdrátové adb..." -ForegroundColor Gray
      & $Adb -s $target tcpip 5555 | Out-Host
      Start-Sleep -Seconds 4
      & $Adb connect $dev.Ip | Out-Host
    }
  }
}

# --- Publikace na web ----------------------------------------------------------------------

$publishState = "přeskočeno"
if (-not $NoPublish) {
  Write-Host ""
  $failed = @($results | Where-Object { $_.Vysledek -eq "SELHALO" })
  if ($failed.Count -gt 0) {
    Write-Host "Pozor: install selhal na $($failed.Count) zařízení — build možná není v pořádku." -ForegroundColor Yellow
  }
  $ans = Read-Host "Publikovat na web (VEŘEJNÝ download pingmen.games)? [Y/n]"
  if ($ans -match "^(n|ne|no)$") {
    Write-Host "Publikace vynechána." -ForegroundColor Yellow
  } else {
    Write-Host "=== Publish na web (GitHub release) ===" -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot "publish-apk.ps1")
    $publishState = "OK"
  }
}

# --- Souhrn --------------------------------------------------------------------------------

Write-Host ""
Write-Host "=== SOUHRN ===" -ForegroundColor Cyan
Write-Host "APK: $Apk"
if ($results.Count -gt 0) { $results | Format-Table -AutoSize | Out-Host }
Write-Host "Web publish: $publishState"
Write-Host ""
if (-not $SkipBuild) {
  Write-Host "→ Nezapomeň COMMITNOUT versionCode bump v Pingmen-unity/ProjectSettings.asset (release ho zvýšil)." -ForegroundColor Yellow
}

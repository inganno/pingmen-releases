<#
.SYNOPSIS
  Publikuje nejnovejsi Pingmen APK build jako GitHub release na inganno/pingmen-releases.

.DESCRIPTION
  Vezme nejnovejsi pingmen-release-*.apk z Builds slozky Unity projektu, zkopiruje ho
  na stabilni jmeno pingmen.apk a vytvori novy GitHub release. Asset se VZDY jmenuje
  pingmen.apk, takze web (pingmen.games/download/apk -> latest/download/pingmen.apk)
  nepotrebuje zadnou zmenu.

  Defaultne smaze predchozi release (a jejich tagy), aby zustal jen aktualni build.
  Pres -KeepOld se historie zachova.

.EXAMPLE
  .\publish-apk.ps1
  Publikuje nejnovejsi build, tag = apk-<dnesni-datum>, smaze stare release.

.EXAMPLE
  .\publish-apk.ps1 -Tag apk-2026-07-01 -KeepOld
  Vlastni tag, stare release ponecha.
#>
param(
  # Slozka s Unity buildy (pingmen-release-*.apk)
  [string]$BuildsDir = "D:\PROJECTS\INGANNO\Pingmen\Pingmen-unity\Builds",
  # Tag releasu; default = apk-<yyyy-MM-dd>
  [string]$Tag = ("apk-" + (Get-Date -Format "yyyy-MM-dd")),
  # Zachovat predchozi release misto smazani
  [switch]$KeepOld
)

$ErrorActionPreference = "Stop"
$gh = "C:\Program Files\GitHub CLI\gh.exe"
$repo = "inganno/pingmen-releases"

if (-not (Test-Path $gh)) { throw "gh.exe nenalezen na $gh" }
if (-not (Test-Path $BuildsDir)) { throw "Builds slozka neexistuje: $BuildsDir" }

# 1. Najdi nejnovejsi release APK (ignoruje stabilni kopii pingmen.apk i debug buildy)
$apk = Get-ChildItem $BuildsDir -Filter "pingmen-release-*.apk" |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $apk) { throw "Zadny pingmen-release-*.apk v $BuildsDir" }
Write-Host "Build:  $($apk.Name)  ($([math]::Round($apk.Length/1MB,1)) MB, $($apk.LastWriteTime))"
Write-Host "Tag:    $Tag"

# 2. Zkopiruj na stabilni jmeno assetu
$stable = Join-Path $BuildsDir "pingmen.apk"
Copy-Item $apk.FullName $stable -Force

# 3. Smaz stare release vcetne tagu (krome -KeepOld)
if (-not $KeepOld) {
  $oldTags = & $gh release list --repo $repo --json tagName --jq '.[].tagName'
  foreach ($t in $oldTags) {
    if ($t) {
      Write-Host "Mazu stary release: $t"
      & $gh release delete $t --repo $repo --yes --cleanup-tag
    }
  }
}

# 4. Vytvor novy release
& $gh release create $Tag $stable --repo $repo `
  --title "Pingmen APK $Tag" `
  --notes "Sideload build pro Android TV 7.0+. Stahuj vzdy pres /releases/latest/download/pingmen.apk."

Write-Host ""
Write-Host "Hotovo. Verejny download: https://github.com/$repo/releases/latest/download/pingmen.apk"
Write-Host "Web (po deployi): https://test.pingmen.games/download/apk"

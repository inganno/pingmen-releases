# pingmen-releases

Public host for Pingmen sideload APK release assets (source stays in private Pingmen-unity).

## Proč existuje

`Pingmen-unity` je **private** repo a release assety private repa nejdou stáhnout veřejně.
Toto public repo slouží **jen** jako hostitel APK binárek — zdrojáky hry zůstávají private.

Web (`pingmen.games/download/apk`) redirectuje na
`…/pingmen-releases/releases/latest/download/pingmen.apk`. Asset se vždy jmenuje
**`pingmen.apk`**, takže nová verze nevyžaduje žádnou změnu na webu.

## Vydání nové verze

```powershell
.\release.ps1
```

Jeden podepsaný build = jeden stav všude. Skript projde celý flow:

1. **Build** — zeptá se na hesla ke keystoru (nikam se neukládají), postaví signed IL2CPP
   release do `../Pingmen-unity/Builds/pingmen-release-<datum>.apk`.
2. **Rozeslání na zařízení** — všechna z `devices.ps1`. Zkouší nejdřív síť, při neúspěchu USB
   serial; po USB instalaci sám obnoví `adb tcpip 5555`, takže tablet po restartu naskočí zpátky
   do Wi-Fi. Nedostupné zařízení se přeskočí (ostatní se dokončí) a je vidět v souhrnu. Po
   instalaci se kontroluje `versionCode` proti tomu, co má APK mít.
3. **Publikace na web** — zeptá se před odesláním ven, pak zavolá `publish-apk.ps1`.

Na konci vypíše souhrn: co je na kterém zařízení a jestli šel build na web.

Přepínače:

- `-NoPublish` — nechat veřejný download na staré verzi
- `-NoInstall` — nikam neinstalovat
- `-Device <IP:port|USB serial>` — jen tato zařízení místo celé flotily (dá se opakovat)
- `-SkipBuild` — použít poslední postavené APK (`-SkipBuild -NoInstall` = jen publikace)

**Proč default rozesílá všude a publikuje:** dřív se instalovalo na jedno zařízení přes
`-Device` a publish byl opt-in, takže veřejný download uměl zůstat verze pozadu — 2026-07-29 se
zjistilo, že build vc4 se ven nikdy nedostal a na webu ležel měsíc starý APK.

### devices.ps1

Flotilu drží `devices.ps1`, který je **mimo git** (lokální IP + HW serialy, tohle repo je
veřejné). Vzor a popis polí: `devices.example.ps1` — zkopíruj a vyplň.

### Jen publikace

```powershell
.\publish-apk.ps1
```

Najde nejnovější `pingmen-release-*.apk` v `../Pingmen-unity/Builds`, zkopíruje ho na
`pingmen.apk`, smaže předchozí release a vytvoří nový (tag `apk-<datum>`).

- `-KeepOld` — zachová staré release (jinak se mažou)
- `-Tag <name>` — vlastní tag
- `-BuildsDir <path>` — jiná složka s buildy

Vyžaduje přihlášené `gh` (`gh auth login`).

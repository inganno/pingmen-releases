# pingmen-releases

Public host for Pingmen sideload APK release assets (source stays in private Pingmen-unity).

## Proč existuje

`Pingmen-unity` je **private** repo a release assety private repa nejdou stáhnout veřejně.
Toto public repo slouží **jen** jako hostitel APK binárek — zdrojáky hry zůstávají private.

Web (`pingmen.games/download/apk`) redirectuje na
`…/pingmen-releases/releases/latest/download/pingmen.apk`. Asset se vždy jmenuje
**`pingmen.apk`**, takže nová verze nevyžaduje žádnou změnu na webu.

## Vydání nové verze

Po Unity buildu spusť:

```powershell
.\publish-apk.ps1
```

Skript najde nejnovější `pingmen-release-*.apk` v `../Pingmen-unity/Builds`, zkopíruje
ho na `pingmen.apk`, smaže předchozí release a vytvoří nový (tag `apk-<datum>`).

- `-KeepOld` — zachová staré release (jinak se mažou)
- `-Tag <name>` — vlastní tag
- `-BuildsDir <path>` — jiná složka s buildy

Vyžaduje přihlášené `gh` (`gh auth login`).

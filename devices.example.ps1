# Vzor pro devices.ps1 (ten je mimo git — obsahuje lokální IP a HW serialy).
# Zkopíruj na devices.ps1 a vyplň vlastní zařízení.
#
#   Name — jak se zařízení jmenuje ve výpisu
#   Ip   — adb endpoint po `adb tcpip 5555` (prázdné = zařízení jen na USB)
#   Usb  — USB serial pro fallback, když síť neodpovídá (`adb devices`); prázdné = jen síť
#
# release.ps1 zkouší nejdřív síť, pak USB. Po instalaci přes USB sám obnoví `adb tcpip 5555`,
# takže zařízení, které po restartu vypadlo z Wi-Fi, se tímhle vrátí.

@(
  @{ Name = "TV";     Ip = "192.168.0.10:5555"; Usb = "" }
  @{ Name = "Tablet"; Ip = "192.168.0.11:5555"; Usb = "ABCD1234" }
)

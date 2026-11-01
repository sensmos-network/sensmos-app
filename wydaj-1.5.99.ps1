$ErrorActionPreference = 'Stop'
$tmp = "$env:TEMP\sensmos-1.5.99"
New-Item -ItemType Directory -Force $tmp | Out-Null
Copy-Item E:\_DF\SENSMOS\aplikacja\build\app\outputs\flutter-apk\app-release.apk "$tmp\sensmos.apk" -Force
@'
- Wallet: "Save a backup" now says what it is: your wallet's private key. A warning stays on the wallet screen until you save the key, because uninstalling the app or losing the phone without it means losing your GALU.
- Wallet: new "Wallet rewards" section with totals per month and per epoch, split into node rewards and service rewards.
- Nodes: an unpaired node shows a "Pair" button right next to the warning.
- Location ceremony: the phone sends the centre of a 0.05° cell (about 5 km) instead of the exact GPS position; the server confirms positions from network evidence.
'@ | Set-Content "$tmp\notes.md" -Encoding utf8

Write-Host "1/4 GitHub release v1.5.99" -ForegroundColor Cyan
gh release create v1.5.99 --repo sensmos-network/sensmos-app --title "1.5.99" -F "$tmp\notes.md" "$tmp\sensmos.apk"

Write-Host "2/4 manifest aktualizacji: 1.5.98 -> 1.5.99" -ForegroundColor Cyan
$m = 'E:\_DF\SENSMOS\backend\public\app\manifest.json'
(Get-Content $m -Raw -Encoding utf8) -replace '"version": "1.5.98"', '"version": "1.5.99"' | Set-Content $m -Encoding utf8 -NoNewline
Set-Location E:\_DF\SENSMOS\backend
git add public/app/manifest.json
git commit -q -m "manifest apki: 1.5.99"

Write-Host "3/4 deploy BE (manifest + restart z endpointem nagrod portfela)" -ForegroundColor Cyan
& E:\_DF\SENSMOS\backend\deploy.ps1

Write-Host "4/4 sprawdzenie" -ForegroundColor Cyan
"manifest: " + (Invoke-RestMethod https://sensmos.com/app/manifest.json).version
"release:  " + (gh release view v1.5.99 --repo sensmos-network/sensmos-app --json tagName,assets -q '.tagName + " " + (.assets[0].name)')
"rewards:  " + ((Invoke-WebRequest 'https://sensmos.com/v1/wallet/0x5cb314d83f0b15aca87caea920f242a4d19a3dd0/rewards' -UseBasicParsing).Content.Substring(0, 120))
Write-Host "gotowe" -ForegroundColor Green

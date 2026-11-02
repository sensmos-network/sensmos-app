$ErrorActionPreference = 'Stop'
$tmp = "$env:TEMP\sensmos-1.6.0"
New-Item -ItemType Directory -Force $tmp | Out-Null
Copy-Item E:\_DF\SENSMOS\aplikacja\build\app\outputs\flutter-apk\app-release.apk "$tmp\sensmos.apk" -Force
@'
- Testers programme: Settings → Testers programme. Sign up with your wallet, tell us your hardware, switch on tester mode and send reports (Works / Does not work) with a diagnostic package that carries no tokens or keys. Scenarios and ranking: https://sensmos.com/test/
- The "node is silent" notification now says what happened (power at the place, the node itself, weak Wi-Fi, out of memory, a fresh update) and what to do; tapping it shows the full text.
- Removed the old GALU ranking screen (the ranking lives on sensmos.com).
'@ | Set-Content "$tmp\notes.md" -Encoding utf8

Write-Host "1/4 GitHub release v1.6.0" -ForegroundColor Cyan
gh release create v1.6.0 --repo sensmos-network/sensmos-app --title "1.6.0" -F "$tmp\notes.md" "$tmp\sensmos.apk"

Write-Host "2/4 manifest aktualizacji: 1.5.99 -> 1.6.0 (bez BOM)" -ForegroundColor Cyan
$m = 'E:\_DF\SENSMOS\backend\public\app\manifest.json'
$txt = [IO.File]::ReadAllText($m, [Text.UTF8Encoding]::new($false)) -replace '"version": "1.5.99"', '"version": "1.6.0"'
[IO.File]::WriteAllText($m, $txt, [Text.UTF8Encoding]::new($false))
Set-Location E:\_DF\SENSMOS\backend
git add public/app/manifest.json
git commit -q -m "manifest apki: 1.6.0"

Write-Host "3/4 deploy BE (manifest + restart: /v1/diag, /v1/test, migracje 018-019, scenariusze)" -ForegroundColor Cyan
& E:\_DF\SENSMOS\backend\deploy.ps1

Write-Host "4/4 sprawdzenie" -ForegroundColor Cyan
"manifest: " + (Invoke-RestMethod https://sensmos.com/app/manifest.json).version
"release:  " + (gh release view v1.6.0 --repo sensmos-network/sensmos-app --json tagName,assets -q '.tagName + " " + (.assets[0].name)')
"scenariusze: " + ((Invoke-RestMethod 'https://sensmos.com/v1/test/scenarios?lang=pl').scenarios.Count)
Write-Host "gotowe" -ForegroundColor Green

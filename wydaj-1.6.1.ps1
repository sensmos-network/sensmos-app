$ErrorActionPreference = 'Stop'
$tmp = "$env:TEMP\sensmos-1.6.1"
New-Item -ItemType Directory -Force $tmp | Out-Null
Copy-Item E:\_DF\SENSMOS\aplikacja\build\app\outputs\flutter-apk\app-release.apk "$tmp\sensmos.apk" -Force
@'
- Fixed: adding the Home Assistant panel (and terminal / LAN panels) through Sensmos Hub was blocked with "Requires FW > 0.70". The Hub has its own version numbering and is now recognised as tunnel-capable.
'@ | Set-Content "$tmp\notes.md" -Encoding utf8

Write-Host "1/4 GitHub release v1.6.1" -ForegroundColor Cyan
gh release create v1.6.1 --repo sensmos-network/sensmos-app --title "1.6.1" -F "$tmp\notes.md" "$tmp\sensmos.apk"

Write-Host "2/4 manifest aktualizacji: 1.6.0 -> 1.6.1 (bez BOM)" -ForegroundColor Cyan
$m = 'E:\_DF\SENSMOS\backend\public\app\manifest.json'
$txt = [IO.File]::ReadAllText($m, [Text.UTF8Encoding]::new($false)) -replace '"version": "1.6.0"', '"version": "1.6.1"'
[IO.File]::WriteAllText($m, $txt, [Text.UTF8Encoding]::new($false))
Set-Location E:\_DF\SENSMOS\backend
git add public/app/manifest.json
git commit -q -m "manifest apki: 1.6.1"

Write-Host "3/4 deploy BE (manifest + rejestracja wersji FW ze scenariuszy, restart)" -ForegroundColor Cyan
& E:\_DF\SENSMOS\backend\deploy.ps1

Write-Host "4/4 sprawdzenie" -ForegroundColor Cyan
"manifest: " + (Invoke-RestMethod https://sensmos.com/app/manifest.json).version
"release:  " + (gh release view v1.6.1 --repo sensmos-network/sensmos-app --json tagName,assets -q '.tagName + " " + (.assets[0].name)')
Write-Host "gotowe" -ForegroundColor Green

$ErrorActionPreference = 'Stop'
$tmp = "$env:TEMP\sensmos-1.5.97"
New-Item -ItemType Directory -Force $tmp | Out-Null
Copy-Item E:\_DF\SENSMOS\aplikacja\build\app\outputs\flutter-apk\app-release.apk "$tmp\sensmos.apk" -Force
"- The app works on Android 7.0 (Let's Encrypt root certificate bundled).`n- A failed HTTP tunnel connection now says what to check: IP address, port, plain HTTP instead of HTTPS." | Set-Content "$tmp\notes.md" -Encoding utf8

Write-Host "1/4 GitHub release v1.5.97" -ForegroundColor Cyan
gh release create v1.5.97 --repo sensmos-network/sensmos-app --title "1.5.97" -F "$tmp\notes.md" "$tmp\sensmos.apk"

Write-Host "2/4 manifest aktualizacji w aplikacji" -ForegroundColor Cyan
& E:\_DF\SENSMOS\backend\deploy.ps1 -NoRestart
(Invoke-RestMethod https://sensmos.com/app/manifest.json).version

Write-Host "3/4 ogloszenie + odpowiedzi w ticketach" -ForegroundColor Cyan
node E:\_DF\DISCORD-MCP\wyslij-ogloszenie.js

Write-Host "4/4 gotowe" -ForegroundColor Green

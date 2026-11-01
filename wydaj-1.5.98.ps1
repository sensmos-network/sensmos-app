$ErrorActionPreference = 'Stop'
$tmp = "$env:TEMP\sensmos-1.5.98"
New-Item -ItemType Directory -Force $tmp | Out-Null
Copy-Item E:\_DF\SENSMOS\aplikacja\build\app\outputs\flutter-apk\app-release.apk "$tmp\sensmos.apk" -Force
"- The location ceremony only accepts the phone's real GPS: no node position from emulators or mocked locations." | Set-Content "$tmp\notes.md" -Encoding utf8

Write-Host "1/4 GitHub release v1.5.98" -ForegroundColor Cyan
gh release create v1.5.98 --repo sensmos-network/sensmos-app --title "1.5.98" -F "$tmp\notes.md" "$tmp\sensmos.apk"

Write-Host "2/4 manifest aktualizacji w aplikacji" -ForegroundColor Cyan
& E:\_DF\SENSMOS\backend\deploy.ps1 -NoRestart
(Invoke-RestMethod https://sensmos.com/app/manifest.json).version

Write-Host "3/4 odpowiedz w tickecie jayman" -ForegroundColor Cyan
node E:\_DF\DISCORD-MCP\wyslij-jayman.js

Write-Host "4/4 gotowe" -ForegroundColor Green

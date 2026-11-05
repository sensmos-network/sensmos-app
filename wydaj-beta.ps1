# Wersja beta apki dla testerów (program testów, krok 9). Stabilni użytkownicy jej nie widzą:
# release na GitHubie jako prerelease (releases/latest dalej wskazuje stabilną), w manifeście pole "beta",
# które apka ≥1.6.2 czyta tylko w trybie testera. Wersja beta = kolejny numer (np. 1.6.3), bez "-beta".
#   .\wydaj-beta.ps1 -Version 1.6.3 -Notes "Co nowego, po angielsku"
# Najpierw: wersja w pubspec.yaml = $Version i flutter build apk --release.
param([Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Notes)
$ErrorActionPreference = 'Stop'
$apk = 'E:\_DF\SENSMOS\aplikacja\build\app\outputs\flutter-apk\app-release.apk'
if (-not (Select-String -Path E:\_DF\SENSMOS\aplikacja\pubspec.yaml -Pattern "^version: $([regex]::Escape($Version))\+" -Quiet)) { throw "pubspec.yaml nie ma wersji $Version" }
$tmp = "$env:TEMP\sensmos-$Version"
New-Item -ItemType Directory -Force $tmp | Out-Null
Copy-Item $apk "$tmp\sensmos.apk" -Force
"- $Notes" | Set-Content "$tmp\notes.md" -Encoding utf8

Write-Host "1/3 GitHub prerelease v$Version" -ForegroundColor Cyan
gh release create "v$Version" --repo sensmos-network/sensmos-app --title "$Version (beta)" --prerelease -F "$tmp\notes.md" "$tmp\sensmos.apk"

Write-Host "2/3 manifest: beta = $Version" -ForegroundColor Cyan
$env:BETA_VER = $Version; $env:BETA_NOTES = $Notes
node -e "const fs=require('fs');const p='E:/_DF/SENSMOS/backend/public/app/manifest.json';const m=JSON.parse(fs.readFileSync(p,'utf8'));const v=process.env.BETA_VER;m.beta={version:v,url:'https://github.com/sensmos-network/sensmos-app/releases/download/v'+v+'/sensmos.apk',notes:{[v]:{en:[process.env.BETA_NOTES]}}};fs.writeFileSync(p,JSON.stringify(m,null,2)+'\n')"
Set-Location E:\_DF\SENSMOS\backend
git add public/app/manifest.json
git commit -q -m "manifest apki: beta $Version"

Write-Host "3/3 deploy BE bez restartu (tylko pliki public/)" -ForegroundColor Cyan
& E:\_DF\SENSMOS\backend\deploy.ps1 -NoRestart
"beta w manifeście: " + (Invoke-RestMethod https://sensmos.com/app/manifest.json).beta.version

# Wieczór 6.11: pierwsza beta apki (1.6.3, przycisk „Wyślij logi noda”) + dzienne deploy BE (przycisk na /test).
$ErrorActionPreference = 'Stop'
& E:\_DF\SENSMOS\aplikacja\wydaj-beta.ps1 -Version 1.6.3 -SkipDeploy -Notes 'Testers programme: "Send node logs" button. The node sends its recent log lines straight to the report (firmware 1.12 or newer).'
& E:\_DF\SENSMOS\backend\deploy.ps1
"beta w manifeście: " + (Invoke-RestMethod https://sensmos.com/app/manifest.json).beta.version

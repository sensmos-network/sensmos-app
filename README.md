<img src="logo.png" alt="Sensmos" height="80">

# Sensmos — Mobile App

The Sensmos companion app — onboard nodes over Bluetooth, watch the live map, and manage your self-custody **GALU** wallet. Built with Flutter (Android; iOS-ready), in English and Polish (follows the system language).

> Sensmos is a DePIN sensor network: cheap ESP32 nodes measure the real world, publish to a shared map, trade data peer-to-peer, and earn GALU. This app is how you run and own your part of it — no cloud, your keys stay with you.
>
> The network powers **[UpFromWhere](https://upfromwhere.com)** — uptime monitoring as seen from real home connections.

## Features

- **Node onboarding** — discover nodes over BLE / mDNS, provision WiFi, and pair with a PIN.
- **Live map & leaderboard** — your neighborhood's data and the network ranking, in real time.
- **Self-custody wallet** (`web3dart`) — GALU balance, **claim** rewards on-chain (cumulative Merkle proof), and **deposit** to spend in the network.
- **Node config** — location, entities, edge scripts and webhooks, straight from your phone.
- **Wallet safety** — encrypted backup to your own node (behind a PIN), or export the key to MetaMask.

## Security model

```
Sensitive (wallet, node config) → NodeService → ESP32 (PIN / session token) → backend
Public (map, leaderboard)       → ApiService  → backend directly
Wallet key                      → device secure storage  (+ optional encrypted backup on the node)
```

## Build & run

```bash
flutter pub get
# set the backend + contract in lib/config.dart
flutter run                      # debug
flutter build apk --release      # release APK
```

## Download

Latest Android APK: **[releases/latest](https://github.com/sensmos-network/sensmos-app/releases/latest)** (installed outside Google Play).

## Part of the Sensmos project

| | |
|---|---|
| 🌐 Website | https://sensmos.com |
| 🔌 Firmware | https://github.com/sensmos-network/sensmos-firmware |
| 🏠 Home Assistant | https://github.com/sensmos-network/sensmos-homeassistant |
| 🧩 Hub (node in Docker / HA add-on) | https://github.com/sensmos-network/sensmos-hub |
| 📜 Protocol | https://github.com/sensmos-network/sensmos-protocol |
| 💬 Discord | https://discord.gg/ukea386Kqx |

GALU runs on Polygon. © 2026 Sensmos.

import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'l10n_pt.dart';

/// Lekka lokalizacja: klucz = polski tekst źródłowy, mapy nadpisań per język.
/// Domyślnie język z systemu (pl → polski, de → niemiecki, inne → angielski);
/// użytkownik może wymusić w ustawieniach ('pl'/'en'/'de'/'system').
/// Fallback brakującego wpisu: język → EN → klucz (PL).
/// Interpolacja: w kluczu `%s`, podmieniane kolejno z [args].
///
/// Użycie:
///   tr('Portfel')                       → "Wallet" (EN) / "Portfel" (PL)
///   tr('Saldo: %s GALU', [balance])     → "Balance: 12 GALU"
///
/// NOWY JĘZYK = mapa `_xxMap` + wpis w `_langMaps` + case w `_apply()`
/// + opcja w ustawieniach + Locale w main.dart.
class L10n {
  static String _lang = 'pl'; // rozwiązany: 'pl' | 'en' | 'de'
  static String _mode = 'system'; // 'system' | 'pl' | 'en' | 'de'
  static final ValueNotifier<int> notifier =
      ValueNotifier(0); // wymusza rebuild UI

  static Future<void> init() async {
    try {
      final p = await SharedPreferences.getInstance();
      _mode = p.getString('lang') ?? 'system';
    } catch (_) {
      _mode = 'system';
    }
    _apply();
  }

  static void _apply() {
    _lang = switch (_mode) {
      'pl' || 'en' || 'de' || 'pt' => _mode,
      _ => switch (PlatformDispatcher.instance.locale.languageCode) {
          'pl' => 'pl',
          'de' => 'de',
          'pt' => 'pt',
          _ => 'en',
        },
    };
  }

  static String get mode => _mode;
  static String get lang => _lang;
  static bool get isEn => _lang != 'pl'; // legacy (stare użycia binarne)

  static Future<void> setMode(String mode) async {
    if (mode == _mode) return;
    _mode = mode;
    _apply();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('lang', mode);
    } catch (_) {}
    notifier.value++; // przebuduj całą apkę
  }
}

const Map<String, Map<String, String>> _langMaps = {
  'en': _enMap,
  'de': _deMap,
  'pt': ptMap
};

String tr(String pl, [List<Object?> args = const []]) {
  var s =
      L10n.lang == 'pl' ? pl : (_langMaps[L10n.lang]?[pl] ?? _enMap[pl] ?? pl);
  for (final a in args) {
    s = s.replaceFirst('%s', '$a');
  }
  return s;
}

/// Nadpisania angielskie. Brak wpisu → pokazujemy klucz (PL).
const Map<String, String> _enMap = {
  "Zerwane połączenie — wracam tam, gdzie skończyło":
      "Connection dropped — carrying on where it stopped",
  // ── Store: wybór liczby kopii + odparowanie (1.5.74) ──
  "Ile kopii": "Number of copies",
  "%s · zalecane": "%s · recommended",
  "Host, który zamilknie, wypada z pakietu dopiero po trzech dobach i dopiero wtedy kopia odbudowuje się gdzie indziej. Przy dwóch kopiach plik wisi przez ten czas na jednym dysku, przy trzech — na dwóch.":
      "A host that goes quiet only drops out of the package after three days, and only then is the copy rebuilt elsewhere. With two copies the file hangs on a single disk for that time; with three, on two.",
  "Odbudowa: %s z %s kopii na miejscu": "Rebuilding: %s of %s copies in place",
  "Zmieniam liczbę kopii…": "Changing the number of copies…",
  "Twoje pliki szyfruje telefon kluczem z portfela. Sprzedawcy trzymają szyfrogram u różnych właścicieli i nie mogą go odczytać.":
      "Your phone encrypts every file with a key from your wallet. The sellers hold ciphertext, at different owners, and cannot read it.",
  "Dostęp znika natychmiast. Urządzenie nie wejdzie już na to konto, dopóki nie sparujesz go od nowa.":
      "Access is gone at once. The device cannot get back into this account until you pair it again.",
  "Ten folder jest pusty": "This folder is empty",
  "Wróć wyżej": "Back up one level",
  "plików: %s": "%s files",
  "Wczytuję nazwy: %s z %s": "Reading names: %s of %s",
  "Nowy folder": "New folder",
  "zdjęcia": "photos",
  "Folder mieszka w zaszyfrowanej nazwie pliku — serwer go nie widzi. Powstanie razem z pierwszym plikiem, który tu wyślesz.":
      "A folder lives inside the encrypted file name \u2014 the server never sees it. It comes into being with the first file you send here.",
  "Przejdź": "Go",
  "Pokaż więcej (%s)": "Show %s more",
  // ── Node alias/tag (1.5.49) ──
  "Nazwa / tag noda": "Node name / tag",
  "Twoja etykieta, żeby łatwiej rozpoznać node — np. Garaż albo Router.":
      "Your own label to recognise the node — e.g. Garage or Router.",
  // ── Portfel: hasło / wysyłka / QR / przebudowa salda (1.5.48) ──
  "W SENSMOS": "IN SENSMOS",
  "Zarobione GALU — do odbioru na portfel on-chain albo do wykorzystania na usługi (Store, LoRa).":
      "Earned GALU — claim to your on-chain wallet or spend on services (Store, LoRa).",
  "Odbiór wymaga POL na gaz — patrz portfel on-chain poniżej.":
      "Claiming needs POL for gas — see the on-chain wallet below.",
  "Przenosi GALU z portfela on-chain do Sensmos — na opłacanie usług (Store, LoRa).":
      "Moves GALU from your on-chain wallet into Sensmos — to pay for services (Store, LoRa).",
  "Twoje własne środki na portfelu. Nie płacą za usługi — do tego służy Wpłata.":
      "Your own funds, on-chain. They don't pay for services — use Deposit for that.",
  "Zarobione": "Earned",
  "Wydane": "Spent",
  "PORTFEL ON-CHAIN (Polygon)": "ON-CHAIN WALLET (Polygon)",
  "Wyślij": "Send",
  "Wyślij %s": "Send %s",
  "Brak %s w portfelu": "No %s in wallet",
  "Za mało POL — zostaw rezerwę na gas":
      "Not enough POL — leave a reserve for gas",
  "Nieprawidłowy adres odbiorcy": "Invalid recipient address",
  "Podaj kwotę": "Enter an amount",
  "Za mało POL na gas — dopłać POL, aby wysłać":
      "Not enough POL for gas — top up POL to send",
  "Wysyłanie…": "Sending…",
  "Wysłano %s %s": "Sent %s %s",
  "Transakcja odrzucona przez kontrakt": "Transaction reverted",
  "Adres odbiorcy (0x…)": "Recipient address (0x…)",
  "Skanuj QR": "Scan QR",
  "W kodzie QR nie ma poprawnego adresu": "The QR code has no valid address",
  "Gas zapłacisz w POL. Wysyłka jest nieodwracalna — sprawdź adres.":
      "Gas is paid in POL. The transfer is irreversible — check the address.",
  "Zostawiam 0.1 POL na gas. Wysyłka jest nieodwracalna — sprawdź adres.":
      "0.1 POL is kept for gas. The transfer is irreversible — check the address.",
  "Potwierdź wysyłkę": "Confirm transfer",
  "Wysyłasz %s %s": "You're sending %s %s",
  "na adres:": "to address:",
  "Tej operacji NIE można cofnąć.": "This operation CANNOT be undone.",
  "Za mało POL — odbiór nagród (claim) wymaga gazu. Wpłać POL na adres portfela (QR na górze).":
      "Not enough POL — claiming rewards needs gas. Send POL to your wallet address (QR at the top).",
  "Zeskanuj adres (QR)": "Scan address (QR)",
  "Skieruj aparat na kod QR z adresem portfela":
      "Point the camera at a QR code with a wallet address",
  "Hasło portfela": "Wallet password",
  "Zalecane": "Recommended",
  "Klucz zaszyfrowany hasłem. Zapomniane hasło zresetujesz przy nodzie (tryb serwisowy + PIN).":
      "Key encrypted with a password. Reset a forgotten password at your node (service mode + PIN).",
  "Zaszyfruj klucz hasłem — chroni środki, gdyby ktoś wykradł dane aplikacji. Zapomniane hasło zresetujesz przy nodzie.":
      "Encrypt the key with a password — it protects your funds if someone steals the app's data. Reset a forgotten password at your node.",
  "Włącz hasło": "Enable password",
  "Wyłącz hasło": "Disable password",
  "Ustaw hasło portfela": "Set a wallet password",
  "Powtórz hasło": "Repeat password",
  "Zapamiętaj PIN swojego noda — to jedyna droga odzysku, jeśli zapomnisz hasła.":
      "Remember your node's PIN — it's the only way to recover if you forget the password.",
  "Hasła nie są takie same": "Passwords don't match",
  "Hasło włączone — portfel zaszyfrowany.":
      "Password enabled — wallet encrypted.",
  "Wyłączyć hasło?": "Disable password?",
  "Klucz wróci do ochrony samego telefonu. Podaj obecne hasło.":
      "The key will fall back to phone-only protection. Enter your current password.",
  "Hasło wyłączone.": "Password disabled.",
  "Twoje pliki szyfruje klucz z portfela, więc bez odblokowania nie ma czym ich otworzyć ani sprawdzić miejsca w sieci.":
      "Your files are encrypted with a key from your wallet, so without unlocking there is nothing to open them with — or to check the space in the network.",
  "Odblokuj portfel": "Unlock wallet",
  "Portfel jest chroniony hasłem. Podaj je, aby wykonywać operacje.":
      "The wallet is password-protected. Enter it to perform operations.",
  "Zapomniałem": "Forgot",
  "Odzyskaj portfel z noda (Ustawienia noda → tryb serwisowy Bluetooth) — to zresetuje hasło.":
      "Recover your wallet from the node (Node settings → Bluetooth service mode) — this resets the password.",
  "Portfel zablokowany": "Wallet locked",
  "Podaj hasło, aby odblokować portfel.":
      "Enter your password to unlock the wallet.",
  "Zapomniałem hasła": "I forgot my password",
  "Portfel zablokowany — odblokuj hasłem, aby wykonać operację.":
      "Wallet locked — unlock with your password to perform the operation.",
  "Błędne hasło": "Wrong password",
  "Kopia zapasowa i odzysk": "Backup and recovery",
  "zapisz klucz offline albo odzyskaj portfel":
      "save the key offline or recover the wallet",
  "Zapisz kopię zapasową": "Save a backup",
  "klucz do zapisania offline — na wypadek utraty telefonu i noda":
      "a key to store offline — in case you lose your phone and node",
  "Odzyskaj portfel z kopii": "Recover wallet from backup",
  "wpisz zapisany klucz — tylko jeśli sam go stworzyłeś":
      "enter a saved key — only if you created it yourself",
  "Wpisz klucz z własnej kopii zapasowej, aby odzyskać portfel. Rób to tylko na swoim telefonie i tylko kluczem, który sam stworzyłeś.":
      "Enter the key from your own backup to recover the wallet. Do this only on your own phone and only with a key you created yourself.",
  "Przepisz na kartkę i schowaj. To Twoja kopia zapasowa na wypadek utraty telefonu — nie służy do wklejania w innych aplikacjach.":
      "Write it on paper and store it safely. It's your backup in case you lose your phone — not for pasting into other apps.",
  "⚠️ To jest klucz do Twoich środków. NIKT — ani my, ani żadna strona, giełda czy „pomoc na forum\" — nie ma prawa Cię o niego prosić. Nie wysyłaj go, nie wklejaj online, nie rób zdjęcia. Zapisz go na papierze i trzymaj offline.":
      "⚠️ This is the key to your funds. NO ONE — not us, not any website, exchange, or 'forum helper' — has the right to ask for it. Don't send it, don't paste it online, don't photograph it. Write it on paper and keep it offline.",

  // ── RemoteTerminal / Panel (auto) ──
  "Łączę z relayem…": "Connecting to relay…",
  "Brak portfela w apce": "No wallet in the app",
  "Node jest offline — nie połączysz się z nim, dopóki nie wróci do sieci.":
      "Node is offline — you can't connect until it's back online.",
  "Remote access WŁĄCZONY — ten node będzie rzadziej wybierany do monitorów":
      "Remote access ON — this node will be chosen less often for monitors",
  "Otwieram tunel → %s:%s…": "Opening tunnel → %s:%s…",
  "Sesja zakończona": "Session ended",
  "Rozłączono": "Disconnected",
  "Terminal": "Terminal",
  "Rozłącz": "Disconnect",
  "Remote access na nodzie": "Remote access on the node",
  "Pozwala łączyć się z urządzeniami w sieci noda. Włączony node jest rzadziej wybierany do monitorów.":
      "Lets you connect to devices on the node's network. An enabled node is chosen less often for monitors.",
  "Host w sieci noda": "Host on the node's network",
  "Port": "Port",
  "Użytkownik SSH": "SSH user",
  "Hasło SSH": "SSH password",
  "SSH jest szyfrowany end-to-end — node i nasze serwery przekazują tylko zaszyfrowane bajty.":
      "SSH is end-to-end encrypted — the node and our servers only relay encrypted bytes.",
  "Połącz": "Connect",
  "Najpierw włącz remote access powyżej.": "Enable remote access above first.",
  "Podaj PIN noda": "Enter node PIN",
  "Integracje": "Integrations",
  "Dodaj integrację": "Add integration",
  "Odpiąć integrację?": "Remove integration?",
  "Odepnij": "Remove",
  "Wymaga FW > 0.70": "Requires FW > 0.70",
  "Wszystko już podpięte": "Everything already added",
  "Usuń node z sieci": "Remove node from network",
  "Integracje wymagają noda online (połączonego z chmurą).":
      "Integrations require the node online (connected to the cloud).",
  "Panel HA": "HA Panel",
  "Ustawienia HA": "HA settings",
  "Home Assistant": "Home Assistant",
  "Host HA (IP w sieci noda)": "HA host (IP on node's network)",
  "Long-lived token": "Long-lived token",
  "Podaj host i token": "Enter host and token",
  "Podłącz HA w sieci noda przez tunel. Użyj wewnętrznego adresu HTTP (np. 192.168.1.10:8123) — tunel i tak szyfruje.":
      "Connect to HA on the node's network via the tunnel. Use the internal HTTP address (e.g. 192.168.1.10:8123) — the tunnel encrypts anyway.",
  "Token wygenerujesz w HA: Profil → Long-Lived Access Tokens.":
      "Generate the token in HA: Profile → Long-Lived Access Tokens.",
  "Usuń integrację": "Remove integration",
  "Pokaż": "Show",
  "Ukryj": "Hide",
  "Łączę z HA…": "Connecting to HA…",
  "Node jest offline — wróci, gdy odzyska sieć.":
      "Node is offline — it'll return once it regains network.",
  "HA nie odpowiada — sprawdź adres i token":
      "HA not responding — check address and token",
  "Pusty dashboard": "Empty dashboard",
  "Dodaj kafelek": "Add tile",
  "Nie udało się pobrać encji": "Couldn't fetch entities",
  "Szukaj encji…": "Search entities…",
  "Nazwa kafelka": "Tile name",
  "Odśwież encje z HA": "Refresh entities from HA",
  "Zły PIN — remote access nie włączony":
      "Wrong PIN — remote access not enabled",
  "Remote access wyłączony": "Remote access off",
  "Połączenie zerwane — dotknij „Spróbuj ponownie\".":
      "Connection lost — tap \"Try again\".",
  "Spróbuj ponownie": "Try again",
  "W tej sieci": "On this network",
  "Zdalny terminal": "Remote terminal",
  "Dostępne zawsze": "Always available",
  "Terminal wymaga noda online (połączonego z chmurą).":
      "Terminal requires the node to be online (connected to the cloud).",
  "Sieć lokalna (tylko w sieci noda)":
      "Local network (only on the node's network)",
  "Ustaw lokalizację (BLE + GPS)": "Set location (BLE + GPS)",
  "Połącz telefon z siecią WiFi noda, żeby zobaczyć encje i zmienić ustawienia.":
      "Connect your phone to the node's WiFi to see entities and change settings.",
  "Ten node nie jest dodany lokalnie — połącz się z jego siecią i dodaj go, by konfigurować.":
      "This node isn't added locally — connect to its network and add it to configure it.",
  "Online": "Online",
  "Z lokalizacją": "With location",
  "online": "online",
  // ── Self-update ──────────────────────────────────────────────
  "Sprawdź aktualizację": "Check for updates",
  "nowa wersja i lista zmian": "new version and changelog",
  "Masz najnowszą wersję (%s)": "You're on the latest version (%s)",
  "Dostępna aktualizacja %s": "Update %s available",
  "Później": "Later",
  "Pobierz": "Download",
  "Nie udało się sprawdzić aktualizacji": "Couldn't check for updates",
  // ── Wspólne ──────────────────────────────────────────────────
  "Anuluj": "Cancel",
  "Zapisz": "Save",
  "Usuń": "Delete",
  "Zamknij": "Close",
  "Kopiuj": "Copy",
  "Edytuj": "Edit",
  "Dalej": "Next",
  "Błąd": "Error",
  "błąd": "error",
  "Błąd: %s": "Error: %s",
  "Błąd %s": "Error %s",
  "Błąd ładowania: %s": "Loading error: %s",
  "Błędny PIN": "Wrong PIN",
  "PIN noda": "Node PIN",
  "Skanowanie...": "Scanning...",
  "Łączę...": "Connecting...",
  "JAK TO DZIAŁA": "HOW IT WORKS",
  "Ustawienia": "Settings",
  "Język": "Language",
  "wymuś język aplikacji": "force app language",
  "Systemowy": "System",
  "Logi": "Logs",
  "błędy i zdarzenia aplikacji": "app errors and events",
  "Skopiowano logi": "Logs copied",
  "Brak logów": "No logs",
  "Nie odpowiada (offline?)": "Not responding (offline?)",
  "Poza siecią": "Off network",
  "Błędna odpowiedź noda": "Bad node response",
  "Niedostępny": "Unavailable",
  "Nody": "Nodes",
  "Encje": "Entities",
  "Skrypty": "Scripts",
  "Akcje": "Actions",
  "Odebrane": "Inbox",
  "Wymagane": "Required",
  "Wyczyść": "Clear",

  // ── Portfel ──────────────────────────────────────────────────
  "Portfel": "Wallet",
  "Wpłać GALU na nody": "Deposit GALU to nodes",
  "Za mało GALU w portfelu": "Not enough GALU in wallet",
  "Zatwierdzanie GALU (approve)…": "Approving GALU…",
  "Approve nie powiodło się": "Approve failed",
  "Wpłacanie…": "Depositing…",
  "Wpłacono %s GALU": "Deposited %s GALU",
  "Wpłata odrzucona przez kontrakt": "Deposit reverted",
  "Brak nagród": "No rewards",
  "Nagrody z epoki %s już odebrane": "Rewards for epoch %s already claimed",
  "Odbieranie nagród…": "Claiming rewards…",
  "Odebrano nagrody (epoka %s)": "Rewards claimed (epoch %s)",
  "Odbiór odrzucony przez kontrakt": "Claim reverted",
  "Brak nodów — eksport wymaga PIN-u noda":
      "No nodes — export requires a node PIN",
  "Brak połączenia z żadnym nodem": "No connection to any node",
  "ADRES PORTFELA": "WALLET ADDRESS",
  "Adres skopiowany": "Address copied",
  "SALDO W SIECI (GALU)": "NETWORK BALANCE (GALU)",
  "Do wydania na nody": "Available for nodes",
  "Do odebrania (claim)": "Claimable",
  "Wypłata w toku": "Claim in progress",
  "Wpłata w toku": "Deposit in progress",
  "Zarobione (nagrody)": "Earned (rewards)",
  "Wpłacone (Twój kapitał)": "Deposited (your funds)",
  "Zdeponowane": "Deposited",
  "Odebrano": "Claimed",
  "Odbierz (Claim)": "Claim",
  "Wpłać (Deposit)": "Deposit",
  "SALDO ON-CHAIN (Polygon)": "ON-CHAIN BALANCE (Polygon)",
  "GALU w portfelu": "GALU in wallet",
  "POL (gas)": "POL (gas)",
  "Za mało POL — transakcje (claim/deposit) wymagają gazu. Wpłać POL na adres portfela (QR powyżej).":
      "Not enough POL — transactions (claim/deposit) require gas. Send POL to your wallet address (QR above).",
  "Za mało POL — odbiór nagród (claim) wymaga gazu. Wpłać POL na adres portfela (QR powyżej).":
      "Not enough POL — claiming rewards requires gas. Send POL to your wallet address (QR above).",
  "Eksportuj klucz (MetaMask)": "Export key (MetaMask)",
  "wymaga PIN-u dowolnego Twojego noda":
      "requires the PIN of any of your nodes",
  "Dostępne: %s (MAX)": "Available: %s (MAX)",
  "Odblokuj": "Unlock",
  "Klucz prywatny": "Private key",
  "⚠️ Nigdy nikomu nie pokazuj tego klucza. Kto go ma, kontroluje portfel i wszystkie GALU.":
      "⚠️ Never show this key to anyone. Whoever has it controls the wallet and all GALU.",
  "MetaMask → Importuj konto → Private Key → wklej.":
      "MetaMask → Import account → Private Key → paste.",
  "Klucz skopiowany": "Key copied",
  "Odbiór POL / GALU": "Receive POL / GALU",
  "Wyślij POL na ten adres (gas na transakcje)":
      "Send POL to this address (gas for transactions)",
  "Kopiuj adres": "Copy address",

  // ── Skrypty ──────────────────────────────────────────────────
  "Usuń skrypt": "Delete script",
  "Skrypty wykonywane lokalnie na nodzie — uruchamiane przez akcje wiadomości.":
      "Scripts run locally on the node — triggered by message actions.",
  "Skrypty wykonywane lokalnie na nodzie — przez akcje wiadomości, cyklicznie (interwał) albo przyciskiem Uruchom.":
      "Scripts run locally on the node — via message actions, on a schedule (interval) or with the Run button.",
  "Pętla zatrzymana.": "Loop stopped.",
  "Pętla uruchomiona.": "Loop started.",
  "Skrypt wykonany.": "Script executed.",
  "co %s": "every %s",
  "wstrzymany": "paused",
  "Stop": "Stop",
  "Start": "Start",
  "Interwał (sekundy)": "Interval (seconds)",
  "Puste lub 0 = skrypt odpalany tylko wyzwalaczem albo przyciskiem Uruchom. Wartość (min 60) = chodzi w pętli co N sekund — start i stop przyciskiem na liście. Pętlę może mieć jeden skrypt.":
      "Empty or 0 = the script runs only from a trigger or the Run button. A value (min 60) = it runs in a loop every N seconds — start and stop with the button on the list. Only one script can have a loop.",
  "Brak skryptów. Dodaj przyciskiem +": "No scripts. Add one with +",
  "Kroki: %s": "Steps: %s",
  "Edytuj skrypt": "Edit script",
  "Nowy skrypt": "New script",
  "Dodaj krok (%s/%s)": "Add step (%s/%s)",
  "KROK %s": "STEP %s",
  "WARUNEK (opcjonalnie)": "CONDITION (optional)",
  "BODY TEMPLATE (opcjonalnie)": "BODY TEMPLATE (optional)",
  "TYTUŁ": "TITLE",
  "TREŚĆ": "BODY",
  "Wartość: {{pub.grid_v}}": "Value: {{pub.grid_v}}",
  "DEVICE ID ODBIORCY": "RECIPIENT DEVICE ID",
  "PAYLOAD (opc.)": "PAYLOAD (opt.)",
  "WYRAŻENIE": "EXPRESSION",
  "ZAPISZ DO": "STORE TO",
  "ZAPISZ DO (opc.)": "STORE TO (opt.)",
  "JSON PATH (opc.)": "JSON PATH (opt.)",
  "ENCJA": "ENTITY",
  "FUNKCJA": "FUNCTION",
  "PRÓBKI": "SAMPLES",

  // ── Akcje wiadomości / wiadomości ────────────────────────────
  "Usuń akcję": "Delete action",
  "Brak akcji. Dodaj przyciskiem +": "No actions. Add one with +",
  "Automatyczne akcje wykonywane, gdy node odbierze wiadomość o podanym ID (albo \"*\" dla wszystkich).":
      "Automatic actions run when the node receives a message with the given ID (or \"*\" for all).",
  "ID wiadomości triggera — \"alarm\", \"update\", \"*\" = wszystkie":
      "Trigger message ID — \"alarm\", \"update\", \"*\" = all",
  "powiadomienie na telefon (tytuł/treść; {{from}}, {{payload}})":
      "phone notification (title/body; {{from}}, {{payload}})",
  "URL do wywołania HTTP POST z payloadem wiadomości":
      "URL to call via HTTP POST with the message payload",
  "Zapisz encje z payloadu jako {prefix}.entity_id na nodzie":
      "Store payload entities as {prefix}.entity_id on the node",
  "ID skryptu do uruchomienia przy odebraniu wiadomości":
      "Script ID to run when the message is received",
  "Edytuj akcję": "Edit action",
  "Nowa akcja": "New action",
  "alarm, update, * (wszystkie)": "alarm, update, * (all)",
  "POWIADOMIENIE": "NOTIFICATION",
  "Tytuł — np. Od {from}": "Title — e.g. From {from}",
  "Treść — np. {message}": "Body — e.g. {message}",
  "msg  →  zapisze jako msg.*": "msg  →  stored as msg.*",
  "ID skryptu do uruchomienia": "Script ID to run",
  "Brak wiadomości w skrzynce.": "No messages in the inbox.",
  "· %s nieprzeczytanych": "· %s unread",
  "od: %s": "from: %s",
  "(brak payloadu)": "(no payload)",

  // ── Setup / Onboarding ───────────────────────────────────────
  "Włącz Bluetooth": "Turn on Bluetooth",
  "Lokalizacja (GPS) jest wyłączona — na Androidzie 11 i starszych jest wymagana do skanowania Bluetooth.":
      "Location (GPS) is off — on Android 11 and older it is required for Bluetooth scanning.",
  "Wpisz nazwę sieci WiFi": "Enter WiFi network name",
  "Łączenie przez BLE...": "Connecting via BLE...",
  "Łączenie z nodem...": "Connecting to node...",
  "Autoryzacja BLE...": "BLE authorization...",
  "Brak nonce — aktualizuj firmware": "No nonce — update firmware",
  "Zły PIN — sprawdź kod ustawiony na urządzeniu":
      "Wrong PIN — check the code set on the device",
  "Nie udało się połączyć z nodem przez Bluetooth. Upewnij się, że node jest w trybie konfiguracji (przytrzymaj przycisk ~3 s), podejdź bliżej i przełącz Bluetooth. Jeśli resetowałeś node — wróć do skanowania, bo ma teraz nową nazwę.":
      "Couldn't connect to the node over Bluetooth. Make sure the node is in setup mode (hold the button ~3 s), move closer and toggle Bluetooth. If you reset the node, go back to scanning — it now has a new name.",
  "Wpisz PIN urządzenia": "Enter the device PIN",
  "Autoryzacja nieudana": "Authorization failed",
  "Sprawdzam portfel...": "Checking wallet...",
  "Odzyskiwanie portfela z noda...": "Restoring wallet from node...",
  "Brak kopii na nodzie": "No backup on node",
  "Tworzę nowy portfel...": "Creating new wallet...",
  "Podpisywanie challenge...": "Signing challenge...",
  "Łączę z WiFi przez node...": "Connecting to WiFi via node...",
  "Łączę z nodem przez sieć...": "Connecting to node over network...",
  "Podłącz urządzenie": "Connect device",
  "Szukam...": "Searching...",
  "Znalezione urządzenia": "Found devices",
  "Brak urządzeń.\nUpewnij się, że node jest w trybie konfiguracji.":
      "No devices.\nMake sure the node is in setup mode.",
  "Podaj dane WiFi": "Enter WiFi credentials",
  "Nazwa sieci WiFi (SSID)": "WiFi network name (SSID)",
  "Hasło WiFi": "WiFi password",
  "PIN noda (zapisany w urządzeniu)": "Node PIN (set on the device)",
  "Konfiguruj": "Configure",
  "← Wróć do skanowania": "← Back to scanning",
  // ── Odtwarzanie ID noda (po reflashu) ──
  "Odtwórz ID noda": "Restore node ID",
  "Ta płytka przejmie ID i historię wybranego noda offline (np. po reflashu).":
      "This board takes over the ID and history of the selected offline node (e.g. after a reflash).",
  "Odtwarzam poprzednie ID noda...": "Restoring the node's previous ID...",
  "Ta płytka ma za stary firmware, żeby odtworzyć ID. Zaflashuj najnowszy firmware na sensmos.com/flash i spróbuj ponownie.":
      "This board's firmware is too old to restore an ID. Flash the latest firmware at sensmos.com/flash and try again.",
  "Ta płytka nie umie odtworzyć ID (firmware: %s). Zaflashuj najnowszy firmware na sensmos.com/flash i spróbuj ponownie.":
      "This board can't restore an ID (firmware: %s). Flash the latest firmware at sensmos.com/flash and try again.",
  "Usunięto nieaktywny wpis %s (node po reflashu)":
      "Removed stale entry %s (reflashed node)",
  "Nie udało się zarejestrować noda": "Failed to register node",
  "Urządzenie się resetuje — zaczekaj i spróbuj ponownie.":
      "The device is resetting — wait and try again.",
  "Może potrwać do 30 sekund": "May take up to 30 seconds",
  "Gotowe!": "Done!",
  "Przejdź do panelu (%s)": "Go to dashboard (%s)",
  "Przejdź do panelu": "Go to dashboard",
  "Twoje urządzenia. Twoje dane. Twoja sieć.":
      "Your devices. Your data. Your network.",
  "Podłącz czujnik i monitoruj okolicę":
      "Connect a sensor and monitor your area",
  "Wymieniaj dane z sąsiadami": "Exchange data with neighbors",
  "Alerty na telefon": "Alerts on your phone",
  "Połącz node": "Connect node",
  "Portfel powstaje przy pierwszym nodzie albo jest odzyskiwany z noda przez Bluetooth.":
      "The wallet is created with your first node or restored from a node via Bluetooth.",

  // ── Ustawienia noda ──────────────────────────────────────────
  "Ustawienia noda": "Node settings",
  "odebrane wiadomości na nodzie": "messages received on the node",
  "akcje na odebrane wiadomości (webhook, encje)":
      "actions on received messages (webhook, entities)",
  "automatyzacje noda": "node automations",
  "Lokalizacja": "Location",
  "współrzędne noda": "node coordinates",
  "Lokalizacja noda": "Node location",
  "Integracja (webhook)": "Integration (webhook)",
  "URL wywoływany przy zdarzeniach noda": "URL called on node events",
  "Zaufanie (trust)": "Trust",
  "ceremonia potwierdzająca fizyczne urządzenie":
      "ceremony confirming the physical device",
  "Zmień PIN": "Change PIN",
  "PIN dostępu do noda": "node access PIN",
  "Tryb serwisowy (Bluetooth)": "Service mode (Bluetooth)",
  "zmiana WiFi / odzyskiwanie portfela": "change WiFi / recover wallet",
  "Usuń node z listy": "Remove node from list",
  "Usuwa node tylko z tej apki": "Removes the node only from this app",
  "Usuń node z sieci (permanentnie)": "Delete node from network (permanent)",
  "Kasuje node i wszystkie jego dane z SENSMOS. Możesz go później dodać ponownie (onboarding przez Bluetooth). Zarobione GALU zostają w Twoim portfelu.":
      "Removes the node and all its data from SENSMOS. You can add it back later (Bluetooth onboarding). Earned GALU stays in your wallet.",
  "Usunąć node z sieci?": "Delete node from network?",
  "Node %s i WSZYSTKIE jego dane zostaną trwale usunięte z SENSMOS. Możesz go później dodać ponownie (onboarding przez Bluetooth). Zarobione GALU pozostają w Twoim portfelu.":
      "Node %s and ALL its data will be permanently removed from SENSMOS. You can add it back later (Bluetooth onboarding). Earned GALU stays in your wallet.",
  "Usuń permanentnie": "Delete permanently",
  "Node usunięty z sieci": "Node deleted from network",
  "Błąd usuwania: %s": "Delete error: %s",
  "Brak portfela": "No wallet",
  "Importujesz INNY portfel (%s) niż obecny (%s).\n\nTwoje nody pozostaną przypisane do obecnego portfela, dopóki nie dodasz ich ponownie przez Bluetooth (to zmieni właściciela i wymaga ponownej weryfikacji — bez resetu urządzenia). Zarobione GALU zostają przy portfelu, który je zarobił.":
      "You are importing a DIFFERENT wallet (%s) than the current one (%s).\n\nYour nodes stay assigned to the current wallet until you re-add them over Bluetooth (that changes the owner and requires re-verification — no device reset). Earned GALU stays with the wallet that earned it.",

  "Moje nody w sieci": "My nodes in the network",
  "Wszystkie nody zarejestrowane na Twój portfel (wg SENSMOS)":
      "All nodes registered to your wallet (per SENSMOS)",
  "brak w tej apce": "not in this app",
  "nieaktywny": "inactive",
  "ID skopiowane: %s": "ID copied: %s",
  "Kopiuj ID noda": "Copy node ID",
  "Kopiuj ID": "Copy ID",
  "Importuj klucz prywatny": "Import private key",
  "Importuj portfel": "Import wallet",
  "Monitoruj sieć i internet": "Monitor your network and internet",
  "Korzystałeś już z SENSMOS?": "Already using SENSMOS?",
  "Wyszukaj moje nody w sieci WiFi": "Find my nodes on WiFi",
  "Wyszukaj moje nody": "Find my nodes",
  "Node dodany": "Node added",
  "Zły PIN": "Wrong PIN",
  "Szukam noda...": "Searching for node...",
  "Sprawdzam PIN...": "Checking PIN...",
  "Wpisz IP noda — PIN podasz, gdy urządzenie się odnajdzie.":
      "Enter the node IP — you'll enter the PIN once the device is found.",
  "brak portfela": "no wallet",
  "Aplikacja nie ma przypisanego portfela": "The app has no wallet assigned",
  "Zaimportuj go z klucza (zakładka Portfel) albo z noda (rozwiń swój node poniżej → Importuj portfel z noda).":
      "Import it from a key (Wallet tab) or from a node (expand your node below -> Import wallet from node).",
  "import z klucza": "import from key",
  "Klucz portfela (zaawansowane)": "Wallet key (advanced)",
  "Usunąć z tej apki?": "Remove from this app?",
  "Node zniknie tylko z tego telefonu — zostaje w sieci i dalej nalicza nagrody. Żeby usunąć go z sieci, użyj „Usuń z sieci”.":
      "The node disappears only from this phone - it stays in the network and keeps earning. To remove it from the network, use Delete from network.",
  "Usuń z apki": "Remove from app",
  "import / eksport klucza prywatnego": "import / export private key",
  "Brak portfela w apce. Odzyskaj kopię zapisaną na tym nodzie.":
      "No wallet in the app. Recover the copy saved on this node.",
  "Importuj portfel z noda": "Import wallet from node",
  "Dodaj node": "Add node",
  "tworzy nowy portfel": "creates a new wallet",
  "masz już portfel (np. w MetaMask)? odzyskaj dostęp do swoich nodów":
      "already have a wallet (e.g. in MetaMask)? restore access to your nodes",
  "wklej klucz z MetaMask (0x… lub 64 hex)":
      "paste a key from MetaMask (0x… or 64 hex)",
  "Wklej klucz prywatny (np. z MetaMask). Rób to tylko na swoim telefonie.":
      "Paste a private key (e.g. from MetaMask). Only do this on your own phone.",
  "Importuj": "Import",
  "Nieprawidłowy klucz prywatny": "Invalid private key",
  "Inny portfel": "Different wallet",
  "Zaimportuj mimo to": "Import anyway",
  "Portfel zaimportowany — Twoje nody działają dalej":
      "Wallet imported — your nodes keep working",
  "Portfel zaimportowany: %s": "Wallet imported: %s",
  "Błąd importu: %s": "Import error: %s",
  "Odebrano nagrody": "Rewards claimed",
  "Wszystko już odebrane": "Everything already claimed",
  "Usunąć \"%s\"?": "Delete \"%s\"?",
  "Usunąć akcję dla \"%s\"?": "Delete action for \"%s\"?",
  "Usuń z sieci": "Delete from network",
  "Trwale usuwa node z Twoich urządzeń":
      "Permanently removes the node from your devices",
  "Node POST-uje tu zdarzenia (message_received, batch_sent, sub_received, ws_connected). Puste = wyłączone.":
      "The node POSTs events here (message_received, batch_sent, sub_received, ws_connected). Empty = disabled.",
  "Integracja wyłączona": "Integration disabled",
  "Webhook zapisany": "Webhook saved",
  "Nowy PIN (min. 4 cyfry)": "New PIN (min. 4 digits)",
  "PIN zmieniony": "PIN changed",

  // ── Lokalizacja noda (GPS) ───────────────────────────────────
  "Włącz lokalizację (GPS) w telefonie": "Enable location (GPS) on your phone",
  "Brak zgody na lokalizację": "Location permission denied",
  "Pozycja GPS pobrana ✓": "GPS position acquired ✓",
  "Błąd GPS: %s": "GPS error: %s",
  "Najpierw pobierz pozycję GPS": "Get the GPS position first",
  "Lokalizacja potwierdzona i zapisana": "Location confirmed and saved",
  "Stań przy nodzie i pobierz pozycję GPS — to potwierdza, że node jest naprawdę tutaj. Miasto uzupełni się samo.":
      "Stand next to the node and grab the GPS position — this confirms the node is really here. The city fills in automatically.",
  "Pobierz GPS ponownie": "Get GPS again",
  "Pobierz moją pozycję (GPS)": "Get my position (GPS)",
  "POZYCJA GPS": "GPS POSITION",
  "dokładność ±%s m": "accuracy ±%s m",
  "Brak pozycji — naciśnij przycisk powyżej.":
      "No position — tap the button above.",
  "Rozmycie prywatności": "Privacy blur",
  "Na mapie ~200–800 m od prawdziwej pozycji (losowo)":
      "On the map ~200–800 m from the real position (random)",
  "Na mapie dokładny adres noda": "Exact node address on the map",
  "Zapisz lokalizację": "Save location",

  // ── Node manager / lista nodów ───────────────────────────────
  "Dodaj": "Add",
  "Szukaj": "Search",
  "Ręcznie": "Manual",
  "Jak dodać node?": "How to add a node?",
  "ESP32 musi być włączony i w trybie konfiguracji (świeci LED)":
      "ESP32 must be on and in configuration mode (LED lit)",
  "Bluetooth musi być włączony na telefonie":
      "Bluetooth must be enabled on your phone",
  "Telefon musi być połączony z siecią WiFi z dostępem do internetu":
      "Phone must be connected to WiFi with internet access",
  "WiFi, do której podłączysz node, musi być w zasięgu":
      "The WiFi you connect the node to must be in range",
  "Przygotuj nazwę sieci (SSID) i hasło WiFi":
      "Have your network name (SSID) and WiFi password ready",
  "Dodaj nowy node przez BLE": "Add new node via BLE",
  "Szuka nodów SENSMOS w sieci WiFi.":
      "Searches for SENSMOS nodes on the WiFi network.",
  "Szukaj w sieci": "Search network",
  "Nie znaleziono nodów w sieci.": "No nodes found on the network.",
  "Dodany": "Added",
  "Wpisz IP i PIN gdy znasz adres noda.":
      "Enter IP and PIN if you know the node's address.",
  "Adres IP noda": "Node IP address",
  "Połącz i dodaj": "Connect and add",
  "Wpisz adres IP": "Enter IP address",
  "Brak odpowiedzi z %s.": "No response from %s.",
  "Dodaję...": "Adding...",
  "Panel": "Dashboard",
  "Odśwież": "Refresh",
  "GALU saldo": "GALU balance",
  // „Pokrycie" = mnożnik geograficzny (dawniej „Scarcity"): im dalej najbliższy sąsiad,
  // tym wyżej. Trzymać przy „Sąsiedzi"/„Promień" — to jeden wiersz statystyk na karcie noda.
  "Pokrycie": "Coverage",
  "Sąsiedzi": "Neighbors",
  "Promień": "Radius",
  "Node niedostępny": "Node unavailable",
  "Brak nodów": "No nodes",
  "Dodaj node przez BLE": "Add node via BLE",

  // ── Zaufanie (trust) / tryb serwisowy ────────────────────────
  "Zaufanie noda": "Node trust",
  "Przełączam node w tryb Bluetooth…": "Switching node to Bluetooth mode…",
  "Node nie odpowiada: %s": "Node not responding: %s",
  "Node restartuje się — szukam przez Bluetooth…":
      "Node is restarting — searching over Bluetooth…",
  "Nie znalazłem noda przez Bluetooth.\nNode wróci sam do WiFi w ciągu 5 minut.":
      "Couldn't find the node over Bluetooth.\nThe node will return to WiFi on its own within 5 minutes.",
  "Połączono — przeprowadzam ceremonię…": "Connected — running the ceremony…",
  "Autoryzacja BLE nieudana (PIN?)": "BLE authorization failed (PIN?)",
  "Backend niedostępny — brak seedu ceremonii":
      "Backend unavailable — no ceremony seed",
  "Rundy challenge (%s)…": "Challenge rounds (%s)…",
  "Weryfikacja w sieci…": "Verifying on the network…",
  "Weryfikacja odrzucona: %s": "Verification rejected: %s",
  "Node zaufany — wraca do WiFi.": "Node trusted — returning to WiFi.",
  "Powtórz ceremonię": "Repeat ceremony",
  "Przeprowadź ceremonię": "Run ceremony",
  "Ceremonia zakończona — node zaufany.": "Ceremony complete — node trusted.",
  "Node zaufany": "Node trusted",
  "Node niezweryfikowany": "Node not verified",
  "Ceremonia: %s": "Ceremony: %s",
  "Przeprowadź ceremonię, aby potwierdzić,\nże to fizyczne urządzenie.":
      "Run the ceremony to confirm\nthis is a physical device.",
  "Node restartuje się w tryb Bluetooth (zostaw go włączony).":
      "The node restarts into Bluetooth mode (leave it powered on).",
  "Telefon łączy się i wykonuje szybkie rundy challenge — dowód, że urządzenie jest fizycznie obok.":
      "The phone connects and runs quick challenge rounds — proof the device is physically nearby.",
  "Node podpisuje atest swoim kluczem, Ty podpisujesz portfelem.":
      "The node signs the attestation with its key, you sign with your wallet.",
  "Sieć weryfikuje oba podpisy i oznacza node jako zaufany. Node sam wraca do WiFi.":
      "The network verifies both signatures and marks the node as trusted. The node returns to WiFi on its own.",
  "Tryb serwisowy": "Service mode",
  "Node nieosiągalny po sieci — przytrzymaj przycisk na nodzie 3 s, aż wejdzie w tryb Bluetooth…":
      "Node unreachable over the network — hold the button on the node for 3 s until it enters Bluetooth mode…",
  "Nie znalazłem noda przez Bluetooth.\nUpewnij się, że jest w trybie serwisowym (przycisk 3 s).":
      "Couldn't find the node over Bluetooth.\nMake sure it's in service mode (button, 3 s).",
  "Zapisuję WiFi…": "Saving WiFi…",
  "WiFi zapisane — node restartuje się i łączy z siecią.":
      "WiFi saved — the node restarts and connects to the network.",
  "Pobieram kopię z noda…": "Fetching backup from the node…",
  "Ten node nie ma kopii portfela": "This node has no wallet backup",
  "Brak kopii": "No backup",
  "Portfel odzyskany: %s": "Wallet recovered: %s",
  "Wejdź w tryb serwisowy": "Enter service mode",
  "Zmień sieć WiFi": "Change WiFi network",
  "wpisz nowe SSID i hasło — node przełączy się":
      "enter a new SSID and password — the node will switch",
  "Odzyskaj portfel z noda": "Recover wallet from node",
  "pobierz kopię portfela na ten telefon":
      "download the wallet backup to this phone",
  "Po co tryb serwisowy?": "Why service mode?",
  "Zmiana WiFi i odzyskiwanie portfela działają tylko przez Bluetooth (bliskość fizyczna). Node przejdzie w tryb BLE — jeśli jest nieosiągalny po sieci, przytrzymaj przycisk na nodzie ok. 3 s.":
      "Changing WiFi and recovering the wallet work only over Bluetooth (physical proximity). The node enters BLE mode — if it's unreachable over the network, hold the button on the node for about 3 s.",
  "Nowa sieć WiFi": "New WiFi network",
  "Nazwa sieci (SSID)": "Network name (SSID)",
  "Hasło": "Password",

  // ── Powiadomienia / Ustawienia / Encje / Lokalizacje / Ranking ─
  "Zapisano na %s/%s nodach": "Saved on %s/%s nodes",
  "Powiadomienia": "Notifications",
  "TOKEN PUSH (FCM)": "PUSH TOKEN (FCM)",
  "wklej token FCM…": "paste FCM token…",
  "Włącz na nodach": "Enable on nodes",
  "Wyłącz": "Disable",
  "STAN NA NODACH": "STATUS ON NODES",
  "włączone · %s…": "enabled · %s…",
  "wyłączone": "disabled",
  "Token FCM jest pobierany automatycznie i rozsyłany na nody przy starcie aplikacji. To pole pokazuje aktualny token — możesz go też ręcznie wymusić na nodach. Node przekazuje go do backendu, który wysyła powiadomienia.":
      "The FCM token is fetched automatically and pushed to nodes at app startup. This field shows the current token — you can also force it onto nodes manually. The node forwards it to the backend, which sends notifications.",
  "Lokalizacja nodów": "Node locations",
  "współrzędne wszystkich urządzeń": "coordinates of all devices",
  "token push, włącz/wyłącz na nodach": "push token, enable/disable on nodes",
  "Aplikacja": "App",
  "Wersja": "Version",
  "Brak encji": "No entities",
  "Publiczne": "Public",
  "Własne": "Own",
  "Zewnętrzne": "External",
  "Telemetria": "Telemetry",
  "Radio LoRa": "LoRa radio",
  "Wiek: %s": "Age: %s",
  "lokalna": "local",
  "Brak zapisanych nodów": "No saved nodes",
  "Ustaw współrzędne każdego noda osobno — pozycja na mapie sieci i regiony scoringu.":
      "Set coordinates for each node separately — position on the network map and scoring regions.",
  "Ranking miast": "City ranking",
  "%s nodów · %s online": "%s nodes · %s online",

  // ── Pasek nawigacji / powiadomienia ──────────────────────────
  "Nowe powiadomienie\nsprawdź skrzynkę noda":
      "New notification\ncheck the node inbox",

  // ── Komunikaty z serwisów (wyjątki → snackbar) ───────────────
  "Brak usługi SENSMOS": "SENSMOS service not found",
  "Nie połączono": "Not connected",
  "Node nie pojawił się w sieci.\nSprawdź SSID i hasło WiFi.":
      "Node didn't appear on the network.\nCheck the SSID and WiFi password.",
  "Node jest skonfigurowany i zarejestrowany, ale apka nie widzi go w tej sieci WiFi.\nTelefon jest prawdopodobnie w innej sieci niż node. Połącz telefon z tą samą siecią WiFi i dodaj node ręcznie (Szukaj nodów w sieci).":
      "The node is set up and registered, but the app can't see it on this WiFi network.\nYour phone is probably on a different network than the node. Connect the phone to the same WiFi and add the node manually (Search for nodes).",
  "Błędny PIN lub uszkodzona kopia": "Wrong PIN or corrupted backup",

  // ── Lokalizacja / weryfikacja / prywatność ───────────────────
  "Lokalizacja i weryfikacja": "Location & verification",
  "ceremonia BLE + GPS — ustawia pozycję i potwierdza urządzenie":
      "BLE + GPS ceremony — sets position and verifies the device",
  "PRYWATNOŚĆ": "PRIVACY",
  "Na mapie ~200–800 m od prawdziwej pozycji (losowo).":
      "On the map ~200–800 m from the real position (random).",
  "Na mapie dokładny adres noda.": "Exact node address on the map.",
  "Rozmycie włączone — na mapie ~200–800 m od pozycji":
      "Blur on — shown ~200–800 m from position on the map",
  "Rozmycie wyłączone — na mapie dokładny adres":
      "Blur off — exact address shown on the map",
  "Najpierw ustaw lokalizację (ceremonia powyżej).":
      "Set the location first (ceremony above).",
  "Wymaga firmware 0.27+ — zaktualizuj node.":
      "Requires firmware 0.27+ — update the node.",
  "Wymaga firmware 0.25+ — zaktualizuj node.":
      "Requires firmware 0.25+ — update the node.",
  "Tryb prywatny (ghost)": "Private mode (ghost)",
  "Ukryty z mapy, 0 nagród. Dane działają lokalnie; za subskrypcje płacisz.":
      "Hidden from map, 0 rewards. Data works locally; you still pay for subscriptions.",
  "Tryb prywatny włączony — node ukryty z mapy":
      "Private mode on — node hidden from the map and rewards",
  "Tryb prywatny wyłączony": "Private mode off",
  "Pobieram pozycję GPS...": "Getting GPS position...",
  "Zaraz poprosimy o lokalizację (GPS) — potwierdza, że node jest fizycznie tutaj. Bez niej node działa, ale zarabia znacznie mniej.":
      "We'll ask for location (GPS) — it confirms the node is physically here. Without it the node works but earns much less.",
  "Brak lokalizacji — node niewidoczny na mapie i nie nalicza nagród.":
      "No location — node not shown on the map and earns no rewards.",
  "Ustaw lokalizację": "Set location",
  "Połącz się z siecią noda, aby ustawić lokalizację.":
      "Connect to the node's network to set the location.",
  "Połącz się z siecią WiFi noda, aby zobaczyć encje i zmienić ustawienia.":
      "Connect to the node's WiFi to view entities and change settings.",

  // ── Widok noda: chmura vs sieć lokalna ───────────────────────
  "raportuje": "reporting",
  "Raportują": "Reporting",
  "cisza": "silent",
  "brak danych z chmury": "no cloud data",
  "W sieci": "On network",
  "Zdalnie": "Remote",
  "przed chwilą": "just now",
  "Usuń z listy": "Remove from list",
  "Usunąć z aplikacji?": "Remove from the app?",
  "Node %s zniknie z tej listy. W sieci SENSMOS zostaje bez zmian — nie należy do Twojego portfela, więc nie możesz go stamtąd usunąć.":
      "Node %s will disappear from this list. It stays unchanged in the SENSMOS network — it does not belong to your wallet, so you cannot remove it from there.",
  "Usuń z aplikacji": "Remove from app",
  "Usunięto z aplikacji: %s": "Removed from the app: %s",
  "Zastąpić portfel w aplikacji?": "Replace the wallet in the app?",
  "W aplikacji jest już inny portfel. Odzysk go NADPISZE.":
      "The app already holds a different wallet. Restoring will OVERWRITE it.",
  "Obecny w aplikacji:": "Currently in the app:",
  "Kopia na nodzie:": "Backup on the node:",
  "Jeśli obecny portfel nie został nigdzie wyeksportowany, stracisz do niego dostęp razem ze środkami. Klucza nie da się odtworzyć.":
      "If the current wallet has not been exported anywhere, you will lose access to it and to its funds. The key cannot be recreated.",
  "Nadpisz": "Overwrite",
  "Sprawdzam kopię na nodzie…": "Checking the backup on the node…",
  "Na nodzie jest kopia TEGO SAMEGO portfela — nic nie zmieniam.":
      "The node holds a backup of THE SAME wallet — nothing changed.",
  "Pełne ID": "Full ID",
  "Adres IP": "IP address",
  "Skopiowano %s": "Copied %s",
  "Pod tym adresem jest inny node (%s) — ta płytka została przeflashowana i ma nową tożsamość.":
      "A different node is at this address (%s) — this board was reflashed and has a new identity.",
  "Ten node nie ma zapisanego adresu IP — apka zna go tylko z chmury. Połącz telefon z siecią noda i wyszukaj go lokalnie.":
      "This node has no saved IP address — the app only knows it from the cloud. Connect your phone to the node's network and search for it locally.",
  "Wyszukaj noda w tej sieci": "Search for the node on this network",
  "Szukam w sieci...": "Searching the network...",
  "Nie znaleziono noda w tej sieci. Upewnij się, że telefon jest w tej samej sieci WiFi co node.":
      "Node not found on this network. Make sure your phone is on the same WiFi network as the node.",
  "Node znaleziony: %s": "Node found: %s",
  "Rozmyj dokładną pozycję": "Blur the exact position",
  "Na mapie pokazujemy punkt przesunięty o 200-800 m. Wyłącz tylko, jeśli chcesz publikować dokładny adres.":
      "On the map we show a point shifted by 200-800 m. Turn this off only if you want to publish the exact address.",
  "Node w ogóle nie pojawi się na mapie. Zarabia mniej, bo nie współtworzy publicznego pokrycia sieci.":
      "The node will not appear on the map at all. It earns less because it does not contribute to the network's public coverage.",
  "Tryb prywatny — node nie jest pokazywany na mapie i zarabia w obniżonej stawce, bo nie współtworzy publicznego pokrycia sieci.":
      "Private mode — the node is not shown on the map and earns at a reduced rate, because it does not contribute to the network's public coverage.",
  "Brak potwierdzonej lokalizacji GPS — ten node prawie nie zarabia. Podejdź do niego z telefonem i ustaw lokalizację.":
      "No confirmed GPS location — this node earns almost nothing. Walk up to it with your phone and set the location.",
  "Sprawdzam połączenie...": "Checking connection...",
  "Nie można zarejestrować noda — aplikacja nie ma połączenia z internetem. Telefon musi być online przez cały czas rejestracji. Połącz się z siecią i spróbuj ponownie.":
      "Cannot register the node — the app has no internet connection. Your phone must stay online for the whole registration. Connect to a network and try again.",
  "Utracono połączenie z internetem — nie udało się zarejestrować noda. Telefon musi być online przez cały czas rejestracji.":
      "Internet connection lost — the node could not be registered. Your phone must stay online for the whole registration.",
  "Serwer odrzucił rejestrację noda.":
      "The server rejected the node registration.",
  "Node dodany, ale weryfikacja się nie powiodła — bez niej nie nalicza nagród. Powtórz ceremonię w ustawieniach noda (Zaufanie).":
      "Node added, but verification failed — without it the node earns nothing. Repeat the ceremony in the node settings (Trust).",
  // ── Panel HA: typy kafelków + akcje ──
  "Typ kafelka": "Tile type",
  "Wykres": "Chart",
  "Odczyt": "Reading",
  "Przełącznik": "Switch",
  "Światło": "Light",
  "Przycisk": "Button",
  "Uruchom": "Run",
  "uruchomiono": "started",
  "Nie udało się uruchomić": "Couldn't run it",
  "brak historii": "no history",
  "Gotowe": "Done",
  "OK": "OK",
  "Nagrody naliczają się po ok. 4 godzinach online w danej dobie — zero na starcie jest normalne.":
      "Rewards start after roughly 4 hours online within a day — zero at first is normal.",

  // ── Parowanie noda (klucz w telefonie, kanał wyłącznie po LAN) ──
  "Zdalny dostęp": "Remote access",
  "Zapamiętaj hasło na tym telefonie": "Remember the password on this phone",
  "sparowany — terminal i panel HA działają z dowolnego miejsca":
      "paired — terminal and HA panel work from anywhere",
  "NIESPAROWANY — sparuj teraz, będąc w sieci noda":
      "NOT PAIRED — pair now, while you're on the node's network",
  "Sparuj": "Pair",
  "Sparuj node": "Pair node",
  "Node sparowany.": "Node paired.",
  "Node sparowany — możesz się połączyć.": "Node paired — you can connect now.",
  "Node niesparowany": "Node not paired",
  "Najpierw sparuj node powyżej.": "Pair the node above first.",
  "Nie znam tego noda na tym telefonie.": "This phone doesn't know that node.",
  "Zdalny dostęp wymaga jednorazowego sparowania w tej samej sieci WiFi co node.":
      "Remote access needs a one-time pairing on the same Wi-Fi network as the node.",
  "Zdalny dostęp wymaga jednorazowego sparowania: telefon zapisze w nodzie tajny klucz, którego nasz serwer nigdy nie zobaczy. Bez niego nikt — łącznie z nami — nie otworzy tunelu do Twojej sieci.\n\nMusisz być teraz w tej samej sieci WiFi co node.":
      "Remote access needs a one-time pairing: your phone stores a secret key on the node that our server never sees. Without it nobody — us included — can open a tunnel into your network.\n\nYou need to be on the same Wi-Fi network as the node right now.",
  "Wyłączyć zdalny dostęp?": "Turn off remote access?",
  "Node skasuje wszystkie klucze — terminal i panel HA przestaną działać ze WSZYSTKICH telefonów, także innych domowników. Ponowne włączenie wymaga bycia w sieci noda.":
      "The node will erase every key — the terminal and the HA panel will stop working on ALL phones, including other people in your home. Turning it back on requires being on the node's network.",
  "Zdalny dostęp wyłączony.": "Remote access turned off.",
  "Zły PIN noda.": "Wrong node PIN.",
  "Nie widzę noda w tej sieci — połącz telefon z tym samym WiFi co node.":
      "Can't see the node on this network — connect your phone to the same Wi-Fi as the node.",
  "Node nie ma zapisanych kluczy (przeflashowany?) — sparuj go ponownie, będąc w jego sieci WiFi.":
      "The node has no saved keys (reflashed?) — pair it again while on its Wi-Fi network.",
  "Nowa płytka przejęła ID noda — zdalny dostęp wymaga ponownego sparowania: Ustawienia noda → Zdalny dostęp, będąc w jego sieci WiFi.":
      "A new board took over this node's ID — remote access requires pairing again: Node settings → Remote access, while on its Wi-Fi network.",
  "Odtwarzam parowanie...": "Restoring pairing...",
  "Uwaga: to lekka wersja proxy, nie pełny tunel — jedno połączenie naraz, bez WebSocketów i strumieni. Proste panele HTTP zadziałają, ciężkie aplikacje nie.":
      "Note: this is a lightweight proxy, not a full tunnel — one connection at a time, no WebSockets or streams. Simple HTTP panels will work, heavy apps won't.",
  "Zdalny dostęp sparowany ponownie.": "Remote access paired again.",
  "Node odrzucił parowanie (HTTP %s).": "The node refused pairing (HTTP %s).",
  "Node odrzucił żądanie (HTTP %s).": "The node refused the request (HTTP %s).",
  "Node nie jest sparowany z tym telefonem — sparuj go, będąc w tej samej sieci WiFi.":
      "This node isn't paired with this phone — pair it while on the same Wi-Fi network.",
  "Wymagane sparowanie": "Pairing required",
  "Rozumiem": "Got it",
  "Wymaga sparowania noda — tylko w jego sieci WiFi":
      "Needs node pairing — only on its Wi-Fi network",
  "Node niesparowany — tunel nie ruszy. Sparuj, będąc w jego sieci WiFi.":
      "Node not paired — the tunnel won't open. Pair it while on its Wi-Fi network.",
  "Ta integracja otwiera tunel do Twojej sieci, a zgodę na to daje sam node — nie nasz serwer. Trzeba zapisać w nim klucz, będąc w tej samej sieci WiFi: Ustawienia noda → Zdalny dostęp.\n\nIntegrację dodam już teraz, ale połączy się dopiero po sparowaniu.":
      "This integration opens a tunnel into your network, and only the node itself can allow that — not our server. You need to store a key on it while on the same Wi-Fi: Node settings → Remote access.\n\nI'll add the integration now, but it will only connect once the node is paired.",
  // ── 1.5.39/40: MQTT + LoRa awaryjne + push przez BE ──────────
  "MQTT (lokalny broker)": "MQTT (local broker)",
  "publikacja statusu i encji do Mosquitto / Home Assistant":
      "publish status and entities to Mosquitto / Home Assistant",
  "LoRa awaryjne": "LoRa emergency",
  "encje nadawane radiem przy padzie internetu":
      "entities broadcast over radio when internet is down",
  // ── 1.5.51: sekcja LoRa (odbiór/wysyłka/inbox) + Wydatki usług ──
  "awaryjne, odbiór czujników, wysyłka, inbox":
      "emergency, sensor receive, send, inbox",
  "Ten node nie ma radia LoRa (albo firmware bez LoRa).":
      "This node has no LoRa radio (or firmware without LoRa).",
  "Encje nadawane beaconem przy padzie internetu + komendy z Panelu Emergency.":
      "Entities broadcast when internet is down + commands from the Emergency Panel.",
  "Odbiór ramek (czujniki LoRa)": "Frame receive (LoRa sensors)",
  "dzień użycia": "day of use",
  "Fraza-klucz zostaje TYLKO na nodzie — tę samą wpisz w swoje czujniki. Serwer przekazuje ramki na ślepo.":
      "The key phrase stays ONLY on the node — enter the same one in your sensors. The server relays frames blindly.",
  "klucz ustawiony — wpisz, by zmienić": "key set — type to change",
  "fraza-klucz": "key phrase",
  "klucz ustawiony": "key set",
  "brak klucza": "no key",
  "Przyjmuj ramki jawne (bez szyfrowania)":
      "Accept plain frames (no encryption)",
  "Uwaga: jawną ramkę może nadać każdy, kto zna adres noda.":
      "Note: anyone who knows the node address can send a plain frame.",
  "Wyślij ramkę": "Send a frame",
  "adresat (id8)": "recipient (id8)",
  "treść (do 128 B)": "payload (up to 128 B)",
  "Podaj dst (8 hex) i treść": "Enter dst (8 hex) and payload",
  "Zakolejkowane — nadanie w ciągu kilku(nastu) sekund":
      "Queued — transmitting within seconds",
  "Inbox LoRa": "LoRa inbox",
  "Pusto — ramki i komendy odebrane przez LoRa pojawią się tutaj.":
      "Empty — frames and commands received over LoRa will appear here.",
  "Wydatki usług": "Service expenses",
  "ryczałty dobowe — ostatnie 30 dni": "daily flat fees — last 30 days",
  "Brak naliczeń — płatne funkcje nie były używane.":
      "No charges — paid features were not used.",
  "LoRa: odbiór ramek (AES)": "LoRa: frame receive (AES)",
  "LoRa: odbiór ramek jawnych": "LoRa: plain frame receive",
  "LoRa: wysyłka ramek": "LoRa: frame send",
  "Tunel (SSH / HA / panel)": "Tunnel (SSH / HA / panel)",
  "Nie można połączyć z nodem: %s": "Cannot reach the node: %s",
  "Ten node nie obsługuje MQTT — zaktualizuj firmware do 0.90 lub nowszego.":
      "This node does not support MQTT — update the firmware to 0.90 or newer.",
  "Podaj adres brokera": "Enter the broker address",
  "Zapisano — node łączy się z brokerem":
      "Saved — the node is connecting to the broker",
  "Połączony z brokerem · wysłano %s wiadomości":
      "Connected to the broker · %s messages sent",
  "Łączenie... %s": "Connecting... %s",
  "Włączone": "Enabled",
  "Wyłączone": "Disabled",
  "Node publikuje do brokera w Twojej sieci: status (online/offline), diagnostykę, encje (z auto-wykryciem w Home Assistant) i wiadomości. Działa też bez internetu — temat net/wan mówi, czy internet w domu żyje.":
      "The node publishes to a broker on your network: status (online/offline), diagnostics, entities (auto-discovered by Home Assistant) and messages. Works without internet too — the net/wan topic tells you whether your home's internet is alive.",
  "Adres brokera (IP w LAN)": "Broker address (LAN IP)",
  "Użytkownik (opcjonalnie)": "Username (optional)",
  "Hasło (opcjonalnie)": "Password (optional)",
  "Zapisywanie...": "Saving...",
  "Ten node nie obsługuje trybu awaryjnego — wymaga firmware 0.91+ na płytce z radiem LoRa (SX1262, wariant -lora).":
      "This node does not support emergency mode — it needs firmware 0.91+ on a board with a LoRa radio (SX1262, -lora variant).",
  "Zapisano — node nada te encje przy awarii":
      "Saved — the node will broadcast these entities during an outage",
  "TRYB AWARYJNY AKTYWNY — node nadaje te encje przez LoRa":
      "EMERGENCY MODE ACTIVE — the node is broadcasting these entities over LoRa",
  "Gdy node straci internet, dołączy wybrane encje (max %s) do ramki radiowej LoRa. Jeśli usłyszy go sąsiedni node albo brama, dostaniesz powiadomienie z ostatnimi wartościami — mimo że Twój dom jest offline.":
      "When the node loses internet, it attaches the selected entities (max %s) to its LoRa radio frame. If a neighboring node or gateway hears it, you get a notification with the last values — even though your home is offline.",
  "Node nie ma jeszcze żadnych encji.": "The node has no entities yet.",
  "Maksymalnie %s encje": "At most %s entities",
  "Zapisz (%s/%s)": "Save (%s/%s)",
  "Zarejestrowane w SENSMOS": "Registered with SENSMOS",
  "Brak tokenu FCM (usługi Google niedostępne?)":
      "No FCM token (Google services unavailable?)",
  "Niezarejestrowane": "Not registered",
  "Zarejestruj ponownie": "Register again",
  "Rejestrowanie...": "Registering...",
  "Token zarejestrowany — powiadomienia aktywne na tym urządzeniu.":
      "Token registered — notifications are active on this device.",
  "Rejestracja nie powiodła się — sprawdź internet i spróbuj ponownie.":
      "Registration failed — check your internet and try again.",
  "Powiadomienia rejestrują się automatycznie przy starcie aplikacji — jedna rejestracja obejmuje wszystkie Twoje nody (akcje skryptów, wiadomości, alarm o utracie łączności przez LoRa). Wyłączysz je w systemowych ustawieniach powiadomień.":
      "Notifications register automatically when the app starts — one registration covers all your nodes (script actions, messages, the LoRa connectivity-loss alarm). You can turn them off in the system notification settings.",
  "Brak powiadomień": "No notifications",
  // ── 1.5.42: plugin Raport łącza ──────────────────────────────
  "Raport łącza": "Connection report",
  "Łącze": "Link",
  "Okres": "Period",
  "ostatnie %s dni": "last %s days",
  "Przerwy w dostępie do internetu": "Internet outages",
  "Łączny czas bez internetu": "Total time without internet",
  "Najdłuższa przerwa": "Longest outage",
  "Pomiar niezależny, 24/7, stempel czasu NTP":
      "Independent measurement, 24/7, NTP timestamps",
  "%s dni": "%s days",
  "Twój internet (wina dostawcy)": "Your internet (provider's fault)",
  "przerw": "outages",
  "bez internetu": "without internet",
  "najdłuższa": "longest",
  "Pozostałe %s przerw to chwilowe prace po stronie SENSMOS — nie liczą się do raportu.":
      "The remaining %s interruptions were brief SENSMOS maintenance — they don't count toward the report.",
  "Raport skopiowany — wklej go do reklamacji":
      "Report copied — paste it into your complaint",
  "Kopiuj raport": "Copy report",
  "Brak zaników w tym okresie — łącze działało bez przerw. 🎉":
      "No outages in this period — your connection ran uninterrupted. 🎉",
  "internet nie działał (wina dostawcy)":
      "internet was down (provider's fault)",
  "serwis SENSMOS — nie liczy się do raportu":
      "SENSMOS maintenance — not counted in the report",
  // ── 1.5.43: plugin Panel LAN ─────────────────────────────────
  "Panel LAN": "LAN panel",
  "HTTP w LAN": "HTTP on LAN",
  "Dodaj panel": "Add panel",
  "Edytuj panel": "Edit panel",
  "Nazwa": "Name",
  "Adres w LAN": "LAN address",
  "Tylko HTTP. Ciężkie panele (UniFi, HA) nie zadziałają — tunel jest wolny.":
      "HTTP only. Heavy panels (UniFi, HA) won't work — the tunnel is slow.",
  "Dodaj panele WWW z sieci noda (router, drukarka, Pi-hole…) — otworzysz je stąd z dowolnego miejsca, przez tunel.":
      "Add web panels from the node's network (router, printer, Pi-hole…) — you'll open them from anywhere, through the tunnel.",
  "Otwieram tunel do noda…": "Opening the tunnel to the node…",
  "Podaj adres w LAN": "Enter the LAN address",
  "LoRa awaryjne — słyszany radiem": "LoRa emergency — heard over radio",
  "LoRa awaryjne — bez internetu, słyszany %s temu przez %s":
      "LoRa emergency — no internet, heard %s ago by %s",
  // ── Panel Emergency (model v2) ──
  "Panel Emergency": "Emergency Panel",
  "Panel Emergency — encje i komenda": "Emergency Panel — entities & command",
  "Node bez internetu — nadaje przez LoRa":
      "Node offline — transmitting over LoRa",
  "Node ma łączność z serwerem (WS)": "Node is connected to the server (WS)",
  "Ostatnia ramka %s temu · usłyszał %s": "Last frame %s ago · heard by %s",
  "Brak ramek emergency — czekam na pierwszy beacon":
      "No emergency frames yet — waiting for the first beacon",
  "Ostatni kontakt WS: %s temu": "Last WS contact: %s ago",
  "Encje awaryjne": "Emergency entities",
  "Nie wybrano encji awaryjnych (Ustawienia noda → LoRa awaryjne)":
      "No emergency entities selected (Node settings → Emergency LoRa)",
  "odebrano %s temu": "received %s ago",
  "Komenda do noda": "Command to node",
  "Max 8 znaków. Node przekaże ją do inboxu, MQTT/HA i webhooka (jeśli ustawiony).":
      "Max 8 chars. The node forwards it to the inbox, MQTT/HA and the webhook (if set).",
  "Webhook przy komendzie (opcjonalny)": "Webhook on command (optional)",
  "Gdy node odbierze komendę przez LoRa, wyśle POST na ten adres w Twojej sieci (np. UniFi Protect). Komenda trafia też do inboxu i MQTT/HA.":
      "When the node receives a command over LoRa, it POSTs to this address on your network (e.g. UniFi Protect). The command also goes to the inbox and MQTT/HA.",
  "Wyślij przez LoRa": "Send via LoRa",
  "Komenda w kolejce — poleci przez najbliższy przekaźnik":
      "Command queued — will go out via the nearest relay",
  "Historia komend": "Command history",
  "ODEBRANA przez node": "RECEIVED by node",
  "wysłana": "sent",
  "nieudana": "failed",
  "w kolejce": "queued",
  "Wpisz komendę: 1-8 znaków ASCII, bez spacji":
      "Enter a command: 1-8 ASCII chars, no spaces",
  "Złe hasło": "Wrong password",
  "%s temu": "%s ago",
  "Tryb LoRa uzbraja się ~2 min po padzie; ramka leci co ~4 min":
      "LoRa mode arms ~2 min after the outage; a frame goes out every ~4 min",
  "Komenda LoRa jest dostępna, gdy node straci łączność z serwerem":
      "The LoRa command is available when the node loses its server connection",
  "LoRa awaryjne — ostatni epizod %s temu":
      "LoRa emergency — last episode %s ago",
  "Limit komend wyczerpany — spróbuj za ~%s min":
      "Command limit reached — try again in ~%s min",
  "Komendy w tej godzinie: %s/%s — airtime LoRa jest wspólny":
      "Commands this hour: %s/%s — LoRa airtime is shared",

  // ── 1.5.52: token ownera, lista celów SSH, widgety ──────────
  "Błędne hasło portfela.": "Wrong wallet password.",
  "Pytamy ostatni raz: apka zapamięta osobny klucz dostępu do tuneli, więc portfel może zostać zamknięty.":
      "Last time we ask: the app stores a separate tunnel access key, so the wallet can stay locked.",
  "Nie udało się wydać tokenu dostępu.": "Could not issue the access token.",
  "Podaj adres w sieci noda.": "Enter an address on the node’s network.",
  "Nowe połączenie": "New connection",
  "Edytuj połączenie": "Edit connection",
  "Maszyna w sieci noda — otworzysz ją stąd z dowolnego miejsca, przez tunel.":
      "A machine on the node’s network — open it from anywhere, through the tunnel.",
  "Cel widgetu „Terminal\"": "Target of the “Terminal” widget",
  "Widget na pulpicie otworzy od razu to połączenie, bez pytania.":
      "The home-screen widget opens this connection straight away, without asking.",
  "Cel widgetu na pulpicie": "Home-screen widget target",
  "Połączenie jednorazowe": "One-off connection",
  "Podaj adres w LAN.": "Enter an address on the LAN.",
  "Cel widgetu „Panel HA\"": "Target of the “HA panel” widget",
  "Widget na pulpicie otworzy od razu ten node, bez pytania.":
      "The home-screen widget opens this node straight away, without asking.",
  "Wybierz node — plugin zostanie do niego podpięty.":
      "Pick a node — the plugin will be added to it.",
  "Dodaj połączenie": "Add connection",
  "Nazwa celu": "Target name",
  "Panel WWW w sieci noda — router, drukarka, Pi-hole. Otworzysz go stąd z dowolnego miejsca, przez tunel.":
      "A web panel on the node’s network — router, printer, Pi-hole. Open it from anywhere, through the tunnel.",
  "Dodaj maszyny z sieci noda (serwer, NAS, Raspberry) — otworzysz je stąd z dowolnego miejsca, przez tunel.":
      "Add machines from the node’s network (server, NAS, Raspberry) — open them from anywhere, through the tunnel.",
  "Powiadomienia aktywne": "Notifications are on",
  "Nieaktywne — dotknij, aby włączyć": "Off — tap to turn on",
  "Nie udało się włączyć powiadomień.": "Could not turn notifications on.",
  "Nowy PIN musi mieć co najmniej 4 znaki.":
      "The new PIN must be at least 4 characters.",
  "Zły obecny PIN. Jeśli zmieniałeś go z innego telefonu, wpisz tamten; po przeflashowaniu noda PIN wraca do 123456.":
      "Wrong current PIN. If you changed it from another phone, enter that one; after re-flashing a node the PIN goes back to 123456.",
  "Za dużo prób — node blokuje zmianę na 30 sekund.":
      "Too many attempts — the node blocks changes for 30 seconds.",
  "Node odrzucił zmianę (HTTP %s).": "The node rejected the change (HTTP %s).",
  "Nie widzę noda pod %s — połącz telefon z tą samą siecią WiFi.":
      "No response from %s — connect the phone to the same WiFi network.",
  "PIN chroni lokalne API noda: ustawienia, skrypty, MQTT i tryb serwisowy. Zmiana działa tylko w sieci noda.":
      "The PIN protects the node’s local API: settings, scripts, MQTT and service mode. Changing it only works on the node’s network.",
  "Obecny PIN": "Current PIN",
  "Nowy PIN (min. 4 znaki)": "New PIN (at least 4 characters)",
  "Po zmianie inne telefony z tym nodem zachowają stary PIN — trzeba go tam poprawić w tym samym miejscu.":
      "After the change, other phones paired with this node keep the old PIN — fix it there in the same place.",
  "Node ma za stare oprogramowanie — zaktualizuj je.":
      "The node firmware is too old — please update it.",
  "Node ma za stare oprogramowanie (%s) — zaktualizuj je do 1.01 lub nowszego.":
      "The node firmware is too old (%s) — update it to 1.01 or newer.",
  "Ramka odrzucona — zerwane szyfrowanie tunelu.":
      "Frame rejected — the tunnel encryption broke.",
  "Zapisuję PIN…": "Saving the PIN…",
  "Ustaw nowy PIN": "Set a new PIN",
  "gdy PIN się rozjechał albo go nie pamiętasz":
      "when the PIN drifted apart or you do not remember it",
  "Nowy PIN": "New PIN",
  "Połączenie serwisowe jest już autoryzowane — starego PIN-u nie trzeba znać.":
      "The service connection is already authorised — you do not need to know the old PIN.",
  "PIN ustawiony. Inne telefony z tym nodem trzeba poprawić osobno.":
      "PIN set. Other phones paired with this node have to be fixed separately.",
  "Ustawiam PIN na nodzie...": "Setting the PIN on the node...",
  "Bez PIN-u sprzed zmiany nie odczytam kopii portfela z noda.":
      "Without the PIN from before the change I cannot read the wallet copy from the node.",
  "PIN sprzed zmiany": "PIN from before the change",
  "Kopia portfela na nodzie jest zaszyfrowana PIN-em, który obowiązywał w chwili jej zapisu. Podaj tamten PIN — nowy jest już ustawiony i zostaje.":
      "The wallet copy on the node is encrypted with the PIN that was in force when it was saved. Enter that PIN — the new one is already set and stays.",
  "Poprzedni PIN": "Previous PIN",
  "Pomiń": "Skip",
  "Odczytaj": "Read it",
  "Wiadomość": "Message",
  "Zwiń do paska": "Collapse to the bar",

  // ── 1.5.57: Store (Dysk) ──────────────────────────────
  "Zmniejsz o 1 GB (−%s GALU/dobę)": "Shrink by 1 GB (−%s GALU/day)",
  "Zmniejszam…": "Shrinking…",
  "Wykupić pakiet %s GB za %s GALU na dobę?":
      "Buy a %s GB package for %s GALU a day?",
  "Opłata nalicza się za każdą dobę, także przy pustym pakiecie. Pakiet zamkniesz w każdej chwili.":
      "You are charged for every day, an empty package included. You can close it at any time.",
  "Zamykam pakiet…": "Closing the package…",
  "Zamknij pakiet": "Close the package",
  "Zamknąć pakiet?": "Close the package?",
  "Usunie %s plików u sprzedawców. Opłaty kończą się z tą dobą, ponowny zakup zaczyna od zera.":
      "This deletes %s files at the sellers. Charges stop with today; buying again starts from scratch.",
  "Pakiet zamknięty": "Package closed",
  "Dodatki": "Additions",
  "Brama LoRa": "LoRa gateway",
  "meldunków: %s": "reports: %s",
  "od %s": "since %s",
  "offline": "offline",
  "oferowane %s GB · zajęte %s GB": "offered %s GB · %s GB used",
  "kopii u Ciebie: %s · dowody 7 dni: %s ✓ %s ✗":
      "copies held: %s · proofs 7d: %s ✓ %s ✗",
  "zarobek 7 dni: %s · łącznie: %s GALU": "earned 7d: %s · total: %s GALU",
  "Odłączyć %s?": "Detach %s?",
  "Token przystawki zostanie odebrany, agent natychmiast traci dostęp.":
      "The attachment's token is revoked; the agent loses access immediately.",
  "Odłącz": "Detach",
  "Odłączono": "Detached",
  "Miejsce na pliki u innych właścicieli nodów, szyfrowane w telefonie.":
      "Space for your files at other node owners, encrypted on the phone.",
  "Kup miejsce": "Buy storage",
  "plików: %s · %s GALU na dobę": "files: %s · %s GALU per day",
  "Zaległość: %s dni — wysyłki wstrzymane, doładuj GALU":
      "Arrears: %s days — uploads paused, top up GALU",
  "Ukryj kartę": "Hide the card",
  "Karta ukryta — włączysz ją w Ustawieniach":
      "Card hidden — turn it back on in Settings",
  "Storage na ekranie nodów": "Storage on the nodes screen",
  "karta pakietu pod listą nodów": "package card under the node list",
  "Obiekt bez klucza (wysyłka testowa) — nie da się odszyfrować":
      "Object without a key (test upload) — cannot be decrypted",
  "Dysk": "Storage",
  "Miejsce w sieci": "Space in the network",
  "Sprzedawców online: %s": "Sellers online: %s",
  "Wolnych pakietów: %s": "Free packages: %s",
  "Tryb testowy": "Test mode",
  "Wykup pakiet %s GB (%s GALU/dobę)": "Buy a %s GB package (%s GALU/day)",
  "Brak wolnego miejsca — wróć później": "No free space — come back later",
  "Pakiet %s GB · zajęte %s GB": "Package %s GB · %s GB used",
  "%s GALU na dobę · kopii: %s": "%s GALU per day · copies: %s",
  "Dokup 1 GB (+%s GALU/dobę)": "Add 1 GB (+%s GALU/day)",
  "Dodaj plik": "Add a file",
  "Brak plików": "No files yet",
  "kopii: %s": "copies: %s",
  "Wykupuję pakiet…": "Buying the package…",
  "Dokupuję…": "Adding space…",
  "Szyfrowanie…": "Encrypting…",
  "Pobieranie…": "Downloading…",
  "Odszyfrowywanie…": "Decrypting…",
  "Pobrano: %s": "Saved: %s",
  "Plik jest pusty": "The file is empty",
  "Za duży plik do pobrania na telefon (limit %s MB)":
      "Too large to download to the phone (limit %s MB)",
  "Usunąć %s?": "Delete %s?",
  "Portfel wymagany": "Wallet required",

  // ── dopisane 2026-09-09: brakowało tłumaczeń, obcojęzyczny user widział polski tekst ──
  "%s GB · %s GALU na dobę": "%s GB · %s GALU per day",
  "Do wyboru teraz: %s GB": "Available right now: %s GB",
  "LoRa": "LoRa",
  "Sprzedawców gotowych: %s · wolne w sieci: %s GB":
      "Sellers ready: %s · free in the network: %s GB",
  "Twoje pliki szyfruje telefon kluczem z portfela. Sprzedawcy trzymają szyfrogram w %s kopiach u różnych właścicieli i nie mogą go odczytać.":
      "Your phone encrypts the files with a key from your wallet. Sellers hold the ciphertext in %s copies at different owners and cannot read it.",
  "Wykup %s GB": "Buy %s GB",
  "Zobacz, ile miejsca ma sieć": "See how much space the network has",
  // ── archiwum pomiarów 2026-09-09 ──
  "Archiwum pomiarów": "Measurement archive",
  "Pomiary z Twoich nodów kasujemy po 48 godzinach. Włącz, a raz na dobę wylądują w tym pakiecie — zaszyfrowane Twoim kluczem, więc my ich nie odczytamy. Rok historii jednego noda to kilka MB.":
      "We delete measurements from your nodes after 48 hours. Switch this on and once a day they land in this package — encrypted with your key, so we cannot read them. A year of one node's history is a few MB.",
  "Wstrzymane: %s — przestaw przełącznik, żeby wznowić.":
      "Paused: %s — flip the switch to resume.",
  "Ostatnia zapisana doba: %s": "Last archived day: %s",
  "Pierwsza paczka pojawi się po najbliższej pełnej dobie.":
      "The first bundle appears after the next full day.",
  "Włączam archiwum…": "Turning the archive on…",
  "Wyłączam archiwum…": "Turning the archive off…",
  // ── konto bez noda 2026-09-09 ──
  "Chcę tylko miejsce na pliki": "I just want space for files",
  "Zakładamy portfel, node nie jest potrzebny.":
      "We create a wallet for you; no node needed.",
  "Portfel gotowy: %s. Zapisz klucz (Portfel → Klucz prywatny) — bez noda to jedyna kopia.":
      "Wallet ready: %s. Save the key (Wallet → Private key) — without a node it is the only copy.",
  "albo bez własnego sprzętu": "or without hardware of your own",
  "GALU dostaniesz od kogoś, kto ma nody, albo wpłacisz je w portfelu.":
      "You can get GALU from someone who runs nodes, or deposit it in your wallet.",
  // ── obietnice na ekranie powitalnym 2026-09-09 ──
  "Twoja domowa sieć z dowolnego miejsca — bez VPN-u":
      "Your home network from anywhere — no VPN",
  "Home Assistant bez abonamentu": "Home Assistant without a subscription",
  "LoRa działa, gdy internet nie działa":
      "LoRa works when the internet doesn't",
  "Zaszyfrowane miejsce na pliki u innych":
      "Encrypted space for files at other people's",
  "Zatrzymaj": "Stop",
  "Księgowanie odbioru…": "Booking the claim…",
  "Wysłano: %s": "Sent: %s",
  "bezpośrednio": "direct",
  "przez serwer": "via the server",
  "Dostępna nowsza wersja: sensmos-store.py":
      "A newer version is available: sensmos-store.py",
  "Nie udało się sprawdzić stanu pakietu": "Could not check the package",
  "To nie znaczy, że coś zginęło — Twoje pliki leżą u sprzedawców niezależnie od tego połączenia. Spróbuj za chwilę.":
      "It does not mean anything is lost — your files sit on the sellers' disks regardless of this connection. Try again in a moment.",
  "Sprawdzam…": "Checking…",
  "Sparowane urządzenia": "Paired devices",
  "komputery i Home Assistant z dostępem do konta": "computers and Home Assistant with access to this account",
  "Sparuj urządzenie": "Pair a device",
  "to urządzenie": "this device",
  "Dostęp znika natychmiast. Jeśli to token tego telefonu, powiadomienia i tunele odłączą się do czasu ponownego zalogowania.":
      "Access ends at once. If this is this phone's token, notifications and tunnels drop until it signs in again.",
  "Urządzenie sparowane z kontem wchodzi tokenem, nie portfelem. Portfel zostaje w telefonie i nigdy go nie opuszcza.":
      "A paired device gets in with a token, not the wallet. The wallet stays on this phone and never leaves it.",
  "Nic jeszcze nie sparowano.": "Nothing paired yet.",
  "bez nazwy": "unnamed",
  "ostatnio: %s": "last used: %s",
  "Urządzenie, które parujesz (np. komputer albo Home Assistant), pokaże kod. Wpisz go tutaj — albo zeskanuj, jeśli widać kod QR.":
      "The device you're pairing (e.g. a computer or Home Assistant) shows a code. Type it here — or scan it if a QR code is shown.",
  "Kod z urządzenia": "Code from the device",
  "Zeskanuj": "Scan",
  "Zeskanuj kod": "Scan the code",
  "Sprawdź kod": "Check the code",
  "„%s\" prosi o dostęp do konta": "“%s” is asking for access to the account",
  "Zaznacz, co temu urządzeniu wolno. Możesz to odebrać w każdej chwili.":
      "Tick what this device may do. You can take it back at any time.",
  "Może czytać pliki": "May read files",
  "Bez tego urządzenie wyśle pliki i zobaczy listę, ale nie otworzy żadnego. Odłączenie odbiera dostęp do konta, ale NIE odbiera klucza, który już dostało.":
      "Without this the device can upload and see the list, but cannot open anything. Unpairing takes back account access, but NOT the key it already received.",
  "Szukam…": "Looking…",
  "Paruję…": "Pairing…",
  "Włącz lokalizację w telefonie": "Turn on location on your phone",
  "Pozycja jest za daleko od miejsca, z którego łączy się brama (%s). Brama jest sparowana, ale bez pozycji nie zarabia.": "The position is too far from where the gateway connects from (%s). The gateway is paired, but without a position it does not earn.",
  "Pozycja jest w innym kraju niż łącze bramy. Brama jest sparowana, ale bez pozycji nie zarabia.": "The position is in a different country than the gateway's connection. The gateway is paired, but without a position it does not earn.",
  "Nie udało się ustawić pozycji (%s).": "Could not set the position (%s).",
  "EUI bramy to 16 znaków szesnastkowych": "The gateway EUI is 16 hexadecimal characters",
  "Podaj pozycję bramy": "Enter the gateway position",
  "Brama nie wysyła teraz danych do sensmos.com:1700. Dopisz ten adres w forwarderze bramy i spróbuj za minutę.": "The gateway is not sending to sensmos.com:1700 right now. Add this address in the gateway's forwarder and try again in a minute.",
  "Ta brama jest już sparowana z innym portfelem.": "This gateway is already paired with another wallet.",
  "Brama sparowana": "Gateway paired",
  "Brama LoRaWAN": "LoRaWAN gateway",
  "Dodaj bramę LoRaWAN": "Add LoRaWAN gateway",
  "W panelu bramy (np. Crankk → Forwards To) dopisz serwer sensmos.com:1700. Gdy brama zacznie do nas wysyłać, wpisz tu jej EUI. Brama słyszy nody Sensmos, nadaje beacon i zarabia jak node.": "In the gateway's panel (e.g. Crankk → Forwards To) add the server sensmos.com:1700. Once the gateway starts sending to us, enter its EUI here. The gateway hears Sensmos nodes, transmits a beacon and earns like a node.",
  "EUI bramy": "Gateway EUI",
  "Nazwa (opcjonalnie)": "Name (optional)",
  "np. brama na dachu": "e.g. rooftop gateway",
  "Szerokość": "Latitude",
  "Długość": "Longitude",
  "Jestem przy bramie — użyj pozycji telefonu": "I'm at the gateway — use the phone's position",
  "Pozycja musi zgadzać się z krajem i okolicą, z której łączy się brama.": "The position must match the country and area the gateway connects from.",
  "Sparuj z portfelem": "Pair with wallet",
  "Bez pozycji — brama nie zarabia. Ustaw pozycję.": "No position — the gateway does not earn. Set the position.",
  "Nazwa i pozycja": "Name and position",
  "Odepnij bramę": "Unpair gateway",
  "Dodaj bramę LoRaWAN (np. Crankk)": "Add LoRaWAN gateway (e.g. Crankk)",
  "Nowa pozycja odrzucona — zostaje poprzednia, brama dalej zarabia.": "New position rejected — the previous one stays, the gateway keeps earning.",
  "Wpisana pozycja jest za daleko od miejsca, z którego łączy się brama (%s). Przyjęliśmy przybliżoną pozycję z łącza.": "The entered position is too far from where the gateway connects from (%s). We used an approximate position from its connection.",
  "Wpisana pozycja jest w innym kraju niż łącze bramy. Przyjęliśmy przybliżoną pozycję z łącza.": "The entered position is in a different country than the gateway's connection. We used an approximate position from its connection.",
  "Podaj obie współrzędne albo zostaw obie puste": "Enter both coordinates or leave both empty",
  "Pozycja jest opcjonalna — bez niej bierzemy przybliżoną z łącza bramy. Wpisana musi zgadzać się z krajem i okolicą łącza.": "The position is optional — without it we use an approximate one from the gateway's connection. An entered position must match the country and area of that connection.",
  "Pozycja: wpisana": "Position: entered",
  "Pozycja: przybliżona z łącza bramy": "Position: approximate, from the gateway's connection",
  "Bez pozycji — brama nie zarabia.": "No position — the gateway does not earn.",
  "Słyszy nodów: %s · słyszą ją: %s (24 h)": "Hears nodes: %s · heard by: %s (24 h)",
  "Ramki Sensmos (24 h): %s": "Sensmos frames (24 h): %s",
  "Beacon: jeszcze nie nadany": "Beacon: not sent yet",
  "Beacon: przed chwilą": "Beacon: just now",
  "Beacon: %s temu": "Beacon: %s ago",
  "brama odrzuciła (%s)": "gateway rejected it (%s)",
  "Zarobek: %s GALU": "Earned: %s GALU",
  "Odpiąć bramę?": "Unpair this gateway?",
  "Brama %s zniknie z Twojego portfela i przestanie zarabiać. Możesz ją później sparować ponownie po EUI. Zarobione GALU zostają w portfelu.": "Gateway %s will be removed from your wallet and stop earning. You can pair it again later by its EUI. GALU already earned stays in your wallet.",
  "Brama odpięta": "Gateway unpaired",
  "Zapisano": "Saved",
  "Zegar telefonu odbiega o ponad godzinę — włącz automatyczny czas i spróbuj ponownie.": "Your phone's clock is off by more than an hour — turn on automatic time and try again.",
  "Nie udało się sparować bramy (%s).": "Could not pair the gateway (%s).",
};

/// Nadpisania niemieckie. Brak wpisu → fallback EN → klucz (PL).
const Map<String, String> _deMap = {
  "Zerwane połączenie — wracam tam, gdzie skończyło":
      "Verbindung abgerissen — es geht weiter, wo es aufhörte",
  // ── Store: wybór liczby kopii + odparowanie (1.5.74) ──
  "Ile kopii": "Wie viele Kopien",
  "%s · zalecane": "%s · empfohlen",
  "Host, który zamilknie, wypada z pakietu dopiero po trzech dobach i dopiero wtedy kopia odbudowuje się gdzie indziej. Przy dwóch kopiach plik wisi przez ten czas na jednym dysku, przy trzech — na dwóch.":
      "Ein Host, der verstummt, fällt erst nach drei Tagen aus dem Paket, und erst dann wird die Kopie anderswo neu aufgebaut. Bei zwei Kopien hängt die Datei diese Zeit an einer einzigen Platte, bei drei an zweien.",
  "Odbudowa: %s z %s kopii na miejscu":
      "Wiederaufbau: %s von %s Kopien vorhanden",
  "Zmieniam liczbę kopii…": "Zahl der Kopien wird geändert…",
  "Twoje pliki szyfruje telefon kluczem z portfela. Sprzedawcy trzymają szyfrogram u różnych właścicieli i nie mogą go odczytać.":
      "Ihr Telefon verschlüsselt jede Datei mit einem Schlüssel aus Ihrer Wallet. Die Verkäufer halten Chiffrat bei verschiedenen Besitzern und können es nicht lesen.",
  "Dostęp znika natychmiast. Urządzenie nie wejdzie już na to konto, dopóki nie sparujesz go od nowa.":
      "Der Zugang ist sofort weg. Das Gerät kommt nicht mehr in dieses Konto, bis Sie es erneut koppeln.",
  "Ten folder jest pusty": "Dieser Ordner ist leer",
  "Wróć wyżej": "Eine Ebene h\u00f6her",
  "plików: %s": "%s Dateien",
  "Wczytuję nazwy: %s z %s": "Namen werden gelesen: %s von %s",
  "Nowy folder": "Neuer Ordner",
  "zdjęcia": "fotos",
  "Folder mieszka w zaszyfrowanej nazwie pliku — serwer go nie widzi. Powstanie razem z pierwszym plikiem, który tu wyślesz.":
      "Ein Ordner lebt im verschl\u00fcsselten Dateinamen \u2014 der Server sieht ihn nie. Er entsteht mit der ersten Datei, die Sie hierher senden.",
  "Przejdź": "Los",
  "Pokaż więcej (%s)": "%s weitere anzeigen",
  // ── Node-Alias/Tag (1.5.49) ──
  "Nazwa / tag noda": "Node-Name / Tag",
  "Twoja etykieta, żeby łatwiej rozpoznać node — np. Garaż albo Router.":
      "Dein eigenes Label, um den Node leichter zu erkennen — z. B. Garage oder Router.",
  // ── Wallet: Passwort / Senden / QR / Saldo-Umbau (1.5.48) ──
  "W SENSMOS": "IN SENSMOS",
  "Zarobione GALU — do odbioru na portfel on-chain albo do wykorzystania na usługi (Store, LoRa).":
      "Verdiente GALU — auf die On-Chain-Wallet abholen oder für Dienste ausgeben (Store, LoRa).",
  "Odbiór wymaga POL na gaz — patrz portfel on-chain poniżej.":
      "Abholen braucht POL für Gas — siehe On-Chain-Wallet unten.",
  "Przenosi GALU z portfela on-chain do Sensmos — na opłacanie usług (Store, LoRa).":
      "Überträgt GALU von der On-Chain-Wallet nach Sensmos — zum Bezahlen von Diensten (Store, LoRa).",
  "Twoje własne środki na portfelu. Nie płacą za usługi — do tego służy Wpłata.":
      "Dein eigenes Guthaben on-chain. Es bezahlt keine Dienste — dafür ist Einzahlen da.",
  "Zarobione": "Verdient",
  "Wydane": "Ausgegeben",
  "PORTFEL ON-CHAIN (Polygon)": "ON-CHAIN-WALLET (Polygon)",
  "Wyślij": "Senden",
  "Wyślij %s": "%s senden",
  "Brak %s w portfelu": "Kein %s im Wallet",
  "Za mało POL — zostaw rezerwę na gas":
      "Nicht genug POL — lass eine Reserve für Gas",
  "Nieprawidłowy adres odbiorcy": "Ungültige Empfängeradresse",
  "Podaj kwotę": "Betrag eingeben",
  "Za mało POL na gas — dopłać POL, aby wysłać":
      "Nicht genug POL für Gas — POL aufladen, um zu senden",
  "Wysyłanie…": "Senden…",
  "Wysłano %s %s": "%s %s gesendet",
  "Transakcja odrzucona przez kontrakt": "Transaktion zurückgewiesen",
  "Adres odbiorcy (0x…)": "Empfängeradresse (0x…)",
  "Skanuj QR": "QR scannen",
  "W kodzie QR nie ma poprawnego adresu":
      "Der QR-Code enthält keine gültige Adresse",
  "Gas zapłacisz w POL. Wysyłka jest nieodwracalna — sprawdź adres.":
      "Gas wird in POL bezahlt. Die Überweisung ist unumkehrbar — prüfe die Adresse.",
  "Zostawiam 0.1 POL na gas. Wysyłka jest nieodwracalna — sprawdź adres.":
      "0,1 POL werden für Gas zurückbehalten. Die Überweisung ist unumkehrbar — prüfe die Adresse.",
  "Potwierdź wysyłkę": "Überweisung bestätigen",
  "Wysyłasz %s %s": "Du sendest %s %s",
  "na adres:": "an Adresse:",
  "Tej operacji NIE można cofnąć.":
      "Dieser Vorgang kann NICHT rückgängig gemacht werden.",
  "Za mało POL — odbiór nagród (claim) wymaga gazu. Wpłać POL na adres portfela (QR na górze).":
      "Nicht genug POL — das Abholen der Belohnungen (Claim) benötigt Gas. Sende POL an deine Wallet-Adresse (QR oben).",
  "Zeskanuj adres (QR)": "Adresse scannen (QR)",
  "Skieruj aparat na kod QR z adresem portfela":
      "Richte die Kamera auf einen QR-Code mit einer Wallet-Adresse",
  "Hasło portfela": "Wallet-Passwort",
  "Zalecane": "Empfohlen",
  "Klucz zaszyfrowany hasłem. Zapomniane hasło zresetujesz przy nodzie (tryb serwisowy + PIN).":
      "Schlüssel mit Passwort verschlüsselt. Vergessenes Passwort setzt du am Node zurück (Servicemodus + PIN).",
  "Zaszyfruj klucz hasłem — chroni środki, gdyby ktoś wykradł dane aplikacji. Zapomniane hasło zresetujesz przy nodzie.":
      "Verschlüssle den Schlüssel mit einem Passwort — es schützt dein Guthaben, falls jemand die App-Daten stiehlt. Vergessenes Passwort setzt du am Node zurück.",
  "Włącz hasło": "Passwort aktivieren",
  "Wyłącz hasło": "Passwort deaktivieren",
  "Ustaw hasło portfela": "Wallet-Passwort festlegen",
  "Powtórz hasło": "Passwort wiederholen",
  "Zapamiętaj PIN swojego noda — to jedyna droga odzysku, jeśli zapomnisz hasła.":
      "Merke dir die PIN deines Nodes — sie ist der einzige Weg zur Wiederherstellung, wenn du das Passwort vergisst.",
  "Hasła nie są takie same": "Passwörter stimmen nicht überein",
  "Hasło włączone — portfel zaszyfrowany.":
      "Passwort aktiviert — Wallet verschlüsselt.",
  "Wyłączyć hasło?": "Passwort deaktivieren?",
  "Klucz wróci do ochrony samego telefonu. Podaj obecne hasło.":
      "Der Schlüssel wird nur noch durch das Telefon geschützt. Gib dein aktuelles Passwort ein.",
  "Hasło wyłączone.": "Passwort deaktiviert.",
  "Twoje pliki szyfruje klucz z portfela, więc bez odblokowania nie ma czym ich otworzyć ani sprawdzić miejsca w sieci.": "Deine Dateien verschlüsselt ein Schlüssel aus der Wallet — ohne Entsperren gibt es nichts, womit man sie öffnen oder den Platz im Netz prüfen könnte.",
  "Odblokuj portfel": "Wallet entsperren",
  "Portfel jest chroniony hasłem. Podaj je, aby wykonywać operacje.":
      "Das Wallet ist passwortgeschützt. Gib es ein, um Vorgänge auszuführen.",
  "Zapomniałem": "Vergessen",
  "Odzyskaj portfel z noda (Ustawienia noda → tryb serwisowy Bluetooth) — to zresetuje hasło.":
      "Stelle dein Wallet über den Node wieder her (Node-Einstellungen → Bluetooth-Servicemodus) — das setzt das Passwort zurück.",
  "Portfel zablokowany": "Wallet gesperrt",
  "Podaj hasło, aby odblokować portfel.":
      "Gib dein Passwort ein, um das Wallet zu entsperren.",
  "Zapomniałem hasła": "Passwort vergessen",
  "Portfel zablokowany — odblokuj hasłem, aby wykonać operację.":
      "Wallet gesperrt — mit Passwort entsperren, um den Vorgang auszuführen.",
  "Błędne hasło": "Falsches Passwort",
  "Kopia zapasowa i odzysk": "Backup und Wiederherstellung",
  "zapisz klucz offline albo odzyskaj portfel":
      "Schlüssel offline speichern oder Wallet wiederherstellen",
  "Zapisz kopię zapasową": "Backup speichern",
  "klucz do zapisania offline — na wypadek utraty telefonu i noda":
      "ein Schlüssel zum Offline-Speichern — falls du Telefon und Node verlierst",
  "Odzyskaj portfel z kopii": "Wallet aus Backup wiederherstellen",
  "wpisz zapisany klucz — tylko jeśli sam go stworzyłeś":
      "gespeicherten Schlüssel eingeben — nur wenn du ihn selbst erstellt hast",
  "Wpisz klucz z własnej kopii zapasowej, aby odzyskać portfel. Rób to tylko na swoim telefonie i tylko kluczem, który sam stworzyłeś.":
      "Gib den Schlüssel aus deinem eigenen Backup ein, um das Wallet wiederherzustellen. Tu das nur auf deinem eigenen Telefon und nur mit einem Schlüssel, den du selbst erstellt hast.",
  "Przepisz na kartkę i schowaj. To Twoja kopia zapasowa na wypadek utraty telefonu — nie służy do wklejania w innych aplikacjach.":
      "Schreibe ihn auf Papier und bewahre ihn sicher auf. Es ist dein Backup, falls du dein Telefon verlierst — nicht zum Einfügen in andere Apps.",
  "⚠️ To jest klucz do Twoich środków. NIKT — ani my, ani żadna strona, giełda czy „pomoc na forum\" — nie ma prawa Cię o niego prosić. Nie wysyłaj go, nie wklejaj online, nie rób zdjęcia. Zapisz go na papierze i trzymaj offline.":
      "⚠️ Das ist der Schlüssel zu deinem Guthaben. NIEMAND — weder wir noch eine Website, Börse oder ‚Forum-Hilfe' — darf danach fragen. Sende ihn nicht, füge ihn nicht online ein, fotografiere ihn nicht. Schreibe ihn auf Papier und bewahre ihn offline auf.",

  // ── Panel HA: typy kafelków + akcje ──
  "Typ kafelka": "Kacheltyp",
  "Wykres": "Diagramm",
  "Odczyt": "Messwert",
  "Przełącznik": "Schalter",
  "Światło": "Licht",
  "Przycisk": "Taste",
  "Uruchom": "Ausführen",
  "uruchomiono": "ausgeführt",
  "Nie udało się uruchomić": "Konnte nicht ausgeführt werden",
  "brak historii": "kein Verlauf",
  "Gotowe": "Fertig",
  "Usuń z listy": "Aus der Liste entfernen",
  "Usunąć z aplikacji?": "Aus der App entfernen?",
  "Node %s zniknie z tej listy. W sieci SENSMOS zostaje bez zmian — nie należy do Twojego portfela, więc nie możesz go stamtąd usunąć.":
      "Node %s verschwindet aus dieser Liste. Im SENSMOS-Netzwerk bleibt er unverändert — er gehört nicht zu deiner Wallet, du kannst ihn dort also nicht entfernen.",
  "Usuń z aplikacji": "Aus der App entfernen",
  "Usunięto z aplikacji: %s": "Aus der App entfernt: %s",
  "Zastąpić portfel w aplikacji?": "Wallet in der App ersetzen?",
  "W aplikacji jest już inny portfel. Odzysk go NADPISZE.":
      "Die App enthält bereits eine andere Wallet. Die Wiederherstellung ÜBERSCHREIBT sie.",
  "Obecny w aplikacji:": "Aktuell in der App:",
  "Kopia na nodzie:": "Kopie auf dem Node:",
  "Jeśli obecny portfel nie został nigdzie wyeksportowany, stracisz do niego dostęp razem ze środkami. Klucza nie da się odtworzyć.":
      "Wenn die aktuelle Wallet nirgends exportiert wurde, verlierst du den Zugang zu ihr und zu ihrem Guthaben. Der Schlüssel lässt sich nicht wiederherstellen.",
  "Nadpisz": "Überschreiben",
  "Sprawdzam kopię na nodzie…": "Prüfe die Kopie auf dem Node…",
  "Na nodzie jest kopia TEGO SAMEGO portfela — nic nie zmieniam.":
      "Auf dem Node liegt eine Kopie DERSELBEN Wallet — nichts geändert.",
  "Pełne ID": "Vollständige ID",
  "Adres IP": "IP-Adresse",
  "Skopiowano %s": "Kopiert %s",
  "Pod tym adresem jest inny node (%s) — ta płytka została przeflashowana i ma nową tożsamość.":
      "Unter dieser Adresse ist ein anderer Node (%s) — diese Platine wurde neu geflasht und hat eine neue Identität.",
  "Ten node nie ma zapisanego adresu IP — apka zna go tylko z chmury. Połącz telefon z siecią noda i wyszukaj go lokalnie.":
      "Dieser Node hat keine gespeicherte IP-Adresse — die App kennt ihn nur aus der Cloud. Verbinde das Telefon mit dem Netzwerk des Nodes und suche ihn lokal.",
  "Wyszukaj noda w tej sieci": "Node in diesem Netzwerk suchen",
  "Szukam w sieci...": "Suche im Netzwerk...",
  "Nie znaleziono noda w tej sieci. Upewnij się, że telefon jest w tej samej sieci WiFi co node.":
      "Node in diesem Netzwerk nicht gefunden. Stelle sicher, dass das Telefon im selben WLAN ist wie der Node.",
  "Node znaleziony: %s": "Node gefunden: %s",
  "Rozmyj dokładną pozycję": "Genaue Position unscharf machen",
  "Na mapie pokazujemy punkt przesunięty o 200-800 m. Wyłącz tylko, jeśli chcesz publikować dokładny adres.":
      "Auf der Karte zeigen wir einen um 200-800 m verschobenen Punkt. Schalte das nur aus, wenn du die genaue Adresse veröffentlichen willst.",
  "Node w ogóle nie pojawi się na mapie. Zarabia mniej, bo nie współtworzy publicznego pokrycia sieci.":
      "Der Node erscheint gar nicht auf der Karte. Er verdient weniger, weil er nicht zur öffentlichen Netzabdeckung beiträgt.",
  "Tryb prywatny — node nie jest pokazywany na mapie i zarabia w obniżonej stawce, bo nie współtworzy publicznego pokrycia sieci.":
      "Privater Modus — der Node wird nicht auf der Karte gezeigt und verdient zu einem reduzierten Satz, da er nicht zur öffentlichen Netzabdeckung beiträgt.",
  "Brak potwierdzonej lokalizacji GPS — ten node prawie nie zarabia. Podejdź do niego z telefonem i ustaw lokalizację.":
      "Kein bestätigter GPS-Standort — dieser Node verdient fast nichts. Geh mit dem Telefon zu ihm und setze den Standort.",
  "Sprawdzam połączenie...": "Verbindung wird geprüft...",
  "Nie można zarejestrować noda — aplikacja nie ma połączenia z internetem. Telefon musi być online przez cały czas rejestracji. Połącz się z siecią i spróbuj ponownie.":
      "Node kann nicht registriert werden — die App hat keine Internetverbindung. Das Telefon muss während der gesamten Registrierung online sein. Verbinde dich mit einem Netzwerk und versuche es erneut.",
  "Utracono połączenie z internetem — nie udało się zarejestrować noda. Telefon musi być online przez cały czas rejestracji.":
      "Internetverbindung verloren — der Node konnte nicht registriert werden. Das Telefon muss während der gesamten Registrierung online sein.",
  "Serwer odrzucił rejestrację noda.":
      "Der Server hat die Node-Registrierung abgelehnt.",
  "Node dodany, ale weryfikacja się nie powiodła — bez niej nie nalicza nagród. Powtórz ceremonię w ustawieniach noda (Zaufanie).":
      "Node hinzugefügt, aber die Verifizierung schlug fehl — ohne sie gibt es keine Belohnungen. Wiederhole die Zeremonie in den Node-Einstellungen (Vertrauen).",
  "Nagrody naliczają się po ok. 4 godzinach online w danej dobie — zero na starcie jest normalne.":
      "Belohnungen beginnen nach etwa 4 Stunden online pro Tag — null am Anfang ist normal.",
  // ── RemoteTerminal / Panel (auto) ──
  "Łączę z relayem…": "Verbinde mit Relay…",
  "Brak portfela w apce": "Keine Wallet in der App",
  "Node jest offline — nie połączysz się z nim, dopóki nie wróci do sieci.":
      "Node ist offline — keine Verbindung möglich, bis er wieder online ist.",
  "Remote access WŁĄCZONY — ten node będzie rzadziej wybierany do monitorów":
      "Fernzugriff AN — dieser Node wird seltener für Monitore ausgewählt",
  "Otwieram tunel → %s:%s…": "Öffne Tunnel → %s:%s…",
  "Sesja zakończona": "Sitzung beendet",
  "Rozłączono": "Getrennt",
  "Terminal": "Terminal",
  "Rozłącz": "Trennen",
  "Remote access na nodzie": "Fernzugriff auf dem Node",
  "Pozwala łączyć się z urządzeniami w sieci noda. Włączony node jest rzadziej wybierany do monitorów.":
      "Ermöglicht Verbindungen zu Geräten im Netzwerk des Nodes. Ein aktivierter Node wird seltener für Monitore ausgewählt.",
  "Host w sieci noda": "Host im Netzwerk des Nodes",
  "Port": "Port",
  "Użytkownik SSH": "SSH-Benutzer",
  "Hasło SSH": "SSH-Passwort",
  "SSH jest szyfrowany end-to-end — node i nasze serwery przekazują tylko zaszyfrowane bajty.":
      "SSH ist Ende-zu-Ende-verschlüsselt — der Node und unsere Server leiten nur verschlüsselte Bytes weiter.",
  "Połącz": "Verbinden",
  "Najpierw włącz remote access powyżej.":
      "Aktiviere zuerst oben den Fernzugriff.",
  "Podaj PIN noda": "Node-PIN eingeben",
  "Integracje": "Integrationen",
  "Dodaj integrację": "Integration hinzufügen",
  "Odpiąć integrację?": "Integration entfernen?",
  "Odepnij": "Entfernen",
  "Wymaga FW > 0.70": "Benötigt FW > 0.70",
  "Wszystko już podpięte": "Alles bereits hinzugefügt",
  "Usuń node z sieci": "Node aus Netzwerk entfernen",
  "Integracje wymagają noda online (połączonego z chmurą).":
      "Integrationen erfordern ein Online-Node (mit der Cloud verbunden).",
  "Panel HA": "HA-Panel",
  "Ustawienia HA": "HA-Einstellungen",
  "Home Assistant": "Home Assistant",
  "Host HA (IP w sieci noda)": "HA-Host (IP im Node-Netz)",
  "Long-lived token": "Long-Lived-Token",
  "Podaj host i token": "Host und Token angeben",
  "Podłącz HA w sieci noda przez tunel. Użyj wewnętrznego adresu HTTP (np. 192.168.1.10:8123) — tunel i tak szyfruje.":
      "Verbinde HA im Node-Netz über den Tunnel. Nutze die interne HTTP-Adresse (z. B. 192.168.1.10:8123) — der Tunnel verschlüsselt ohnehin.",
  "Token wygenerujesz w HA: Profil → Long-Lived Access Tokens.":
      "Token in HA erstellen: Profil → Long-Lived Access Tokens.",
  "Usuń integrację": "Integration entfernen",
  "Pokaż": "Anzeigen",
  "Ukryj": "Verbergen",
  "Łączę z HA…": "Verbinde mit HA…",
  "Node jest offline — wróci, gdy odzyska sieć.":
      "Node ist offline — kommt zurück, sobald es wieder Netz hat.",
  "HA nie odpowiada — sprawdź adres i token":
      "HA antwortet nicht — Adresse und Token prüfen",
  "Pusty dashboard": "Leeres Dashboard",
  "Dodaj kafelek": "Kachel hinzufügen",
  "Nie udało się pobrać encji": "Entitäten konnten nicht geladen werden",
  "Szukaj encji…": "Entitäten suchen…",
  "Nazwa kafelka": "Kachelname",
  "Odśwież encje z HA": "Entitäten von HA aktualisieren",
  "Zły PIN — remote access nie włączony":
      "Falsche PIN — Fernzugriff nicht aktiviert",
  "Remote access wyłączony": "Fernzugriff aus",
  "Połączenie zerwane — dotknij „Spróbuj ponownie\".":
      "Verbindung getrennt — tippe auf „Erneut versuchen“.",
  "Spróbuj ponownie": "Erneut versuchen",
  "W tej sieci": "In diesem Netzwerk",
  "Zdalny terminal": "Fernterminal",
  "Dostępne zawsze": "Immer verfügbar",
  "Terminal wymaga noda online (połączonego z chmurą).":
      "Das Terminal erfordert einen Online-Node (mit der Cloud verbunden).",
  "Sieć lokalna (tylko w sieci noda)":
      "Lokales Netzwerk (nur im Netzwerk des Nodes)",
  "Ustaw lokalizację (BLE + GPS)": "Standort festlegen (BLE + GPS)",
  "Połącz telefon z siecią WiFi noda, żeby zobaczyć encje i zmienić ustawienia.":
      "Verbinde dein Telefon mit dem WLAN des Nodes, um Entitäten zu sehen und Einstellungen zu ändern.",
  "Ten node nie jest dodany lokalnie — połącz się z jego siecią i dodaj go, by konfigurować.":
      "Dieser Node ist nicht lokal hinzugefügt — verbinde dich mit seinem Netzwerk und füge ihn hinzu, um ihn zu konfigurieren.",
  "Online": "Online",
  "Z lokalizacją": "Mit Standort",
  "online": "online",
  // ── Self-update ──────────────────────────────────────────────
  "Sprawdź aktualizację": "Nach Updates suchen",
  "nowa wersja i lista zmian": "neue Version und Änderungsliste",
  "Masz najnowszą wersję (%s)": "Du hast die neueste Version (%s)",
  "Dostępna aktualizacja %s": "Update %s verfügbar",
  "Później": "Später",
  "Pobierz": "Herunterladen",
  "Nie udało się sprawdzić aktualizacji": "Update-Prüfung fehlgeschlagen",
  // ── Wspólne ──────────────────────────────────────────────────
  "Anuluj": "Abbrechen",
  "Zapisz": "Speichern",
  "Usuń": "Löschen",
  "Zamknij": "Schließen",
  "Kopiuj": "Kopieren",
  "Edytuj": "Bearbeiten",
  "Dalej": "Weiter",
  "Błąd": "Fehler",
  "błąd": "Fehler",
  "Błąd: %s": "Fehler: %s",
  "Błąd %s": "Fehler %s",
  "Błąd ładowania: %s": "Ladefehler: %s",
  "Błędny PIN": "Falsche PIN",
  "PIN noda": "Node-PIN",
  "Skanowanie...": "Suche läuft...",
  "Łączę...": "Verbinde...",
  "JAK TO DZIAŁA": "SO FUNKTIONIERT ES",
  "Ustawienia": "Einstellungen",
  "Język": "Sprache",
  "wymuś język aplikacji": "App-Sprache erzwingen",
  "Systemowy": "System",
  "Logi": "Protokolle",
  "błędy i zdarzenia aplikacji": "App-Fehler und -Ereignisse",
  "Skopiowano logi": "Protokolle kopiert",
  "Brak logów": "Keine Protokolle",
  "Nie odpowiada (offline?)": "Antwortet nicht (offline?)",
  "Poza siecią": "Außerhalb des Netzwerks",
  "Błędna odpowiedź noda": "Ungültige Node-Antwort",
  "Niedostępny": "Nicht verfügbar",
  "Nody": "Nodes",
  "Encje": "Entitäten",
  "Skrypty": "Skripte",
  "Akcje": "Aktionen",
  "Odebrane": "Posteingang",
  "Wymagane": "Erforderlich",
  "Wyczyść": "Leeren",

  // ── Portfel ──────────────────────────────────────────────────
  "Portfel": "Wallet",
  "Wpłać GALU na nody": "GALU auf Nodes einzahlen",
  "Za mało GALU w portfelu": "Nicht genug GALU im Wallet",
  "Zatwierdzanie GALU (approve)…": "GALU wird freigegeben (approve)…",
  "Approve nie powiodło się": "Approve fehlgeschlagen",
  "Wpłacanie…": "Einzahlung läuft…",
  "Wpłacono %s GALU": "%s GALU eingezahlt",
  "Wpłata odrzucona przez kontrakt": "Einzahlung zurückgesetzt (revert)",
  "Brak nagród": "Keine Belohnungen",
  "Nagrody z epoki %s już odebrane":
      "Belohnungen für Epoche %s bereits abgeholt",
  "Odbieranie nagród…": "Belohnungen werden abgeholt…",
  "Odebrano nagrody (epoka %s)": "Belohnungen abgeholt (Epoche %s)",
  "Odbiór odrzucony przez kontrakt": "Claim zurückgesetzt (revert)",
  "Brak nodów — eksport wymaga PIN-u noda":
      "Keine Nodes — Export erfordert eine Node-PIN",
  "Brak połączenia z żadnym nodem": "Keine Verbindung zu einem Node",
  "ADRES PORTFELA": "WALLET-ADRESSE",
  "Adres skopiowany": "Adresse kopiert",
  "SALDO W SIECI (GALU)": "NETZWERK-GUTHABEN (GALU)",
  "Do wydania na nody": "Verfügbar für Nodes",
  "Do odebrania (claim)": "Abholbar (Claim)",
  "Wypłata w toku": "Claim läuft",
  "Wpłata w toku": "Einzahlung läuft",
  "Zarobione (nagrody)": "Verdient (Belohnungen)",
  "Wpłacone (Twój kapitał)": "Eingezahlt (dein Kapital)",
  "Zdeponowane": "Eingezahlt",
  "Odebrano": "Abgeholt",
  "Odbierz (Claim)": "Abholen (Claim)",
  "Wpłać (Deposit)": "Einzahlen (Deposit)",
  "SALDO ON-CHAIN (Polygon)": "ON-CHAIN-GUTHABEN (Polygon)",
  "GALU w portfelu": "GALU im Wallet",
  "POL (gas)": "POL (Gas)",
  "Za mało POL — transakcje (claim/deposit) wymagają gazu. Wpłać POL na adres portfela (QR powyżej).":
      "Zu wenig POL — Transaktionen (Claim/Deposit) brauchen Gas. Sende POL an deine Wallet-Adresse (QR oben).",
  "Za mało POL — odbiór nagród (claim) wymaga gazu. Wpłać POL na adres portfela (QR powyżej).":
      "Zu wenig POL — das Abholen der Belohnungen braucht Gas. Sende POL an deine Wallet-Adresse (QR oben).",
  "Eksportuj klucz (MetaMask)": "Schlüssel exportieren (MetaMask)",
  "wymaga PIN-u dowolnego Twojego noda":
      "erfordert die PIN eines beliebigen deiner Nodes",
  "Dostępne: %s (MAX)": "Verfügbar: %s (MAX)",
  "Odblokuj": "Entsperren",
  "Klucz prywatny": "Privater Schlüssel",
  "⚠️ Nigdy nikomu nie pokazuj tego klucza. Kto go ma, kontroluje portfel i wszystkie GALU.":
      "⚠️ Zeige diesen Schlüssel niemandem. Wer ihn hat, kontrolliert das Wallet und alle GALU.",
  "MetaMask → Importuj konto → Private Key → wklej.":
      "MetaMask → Konto importieren → Private Key → einfügen.",
  "Klucz skopiowany": "Schlüssel kopiert",
  "Odbiór POL / GALU": "POL / GALU empfangen",
  "Wyślij POL na ten adres (gas na transakcje)":
      "Sende POL an diese Adresse (Gas für Transaktionen)",
  "Kopiuj adres": "Adresse kopieren",

  // ── Skrypty ──────────────────────────────────────────────────
  "Usuń skrypt": "Skript löschen",
  "Skrypty wykonywane lokalnie na nodzie — uruchamiane przez akcje wiadomości.":
      "Skripte laufen lokal auf dem Node — ausgelöst durch Nachrichten-Aktionen.",
  "Skrypty wykonywane lokalnie na nodzie — przez akcje wiadomości, cyklicznie (interwał) albo przyciskiem Uruchom.":
      "Skripte laufen lokal auf dem Node — über Nachrichten-Aktionen, zyklisch (Intervall) oder mit dem Ausführen-Button.",
  "Pętla zatrzymana.": "Schleife gestoppt.",
  "Pętla uruchomiona.": "Schleife gestartet.",
  "Skrypt wykonany.": "Skript ausgeführt.",
  "co %s": "alle %s",
  "wstrzymany": "pausiert",
  "Stop": "Stopp",
  "Start": "Start",
  "Interwał (sekundy)": "Intervall (Sekunden)",
  "Puste lub 0 = skrypt odpalany tylko wyzwalaczem albo przyciskiem Uruchom. Wartość (min 60) = chodzi w pętli co N sekund — start i stop przyciskiem na liście. Pętlę może mieć jeden skrypt.":
      "Leer oder 0 = das Skript läuft nur über einen Auslöser oder den Ausführen-Button. Ein Wert (min 60) = es läuft in einer Schleife alle N Sekunden — Start und Stopp mit dem Button in der Liste. Nur ein Skript kann eine Schleife haben.",
  "Brak skryptów. Dodaj przyciskiem +": "Keine Skripte. Mit + hinzufügen",
  "Kroki: %s": "Schritte: %s",
  "Edytuj skrypt": "Skript bearbeiten",
  "Nowy skrypt": "Neues Skript",
  "Dodaj krok (%s/%s)": "Schritt hinzufügen (%s/%s)",
  "KROK %s": "SCHRITT %s",
  "WARUNEK (opcjonalnie)": "BEDINGUNG (optional)",
  "BODY TEMPLATE (opcjonalnie)": "BODY-TEMPLATE (optional)",
  "TYTUŁ": "TITEL",
  "TREŚĆ": "INHALT",
  "Wartość: {{pub.grid_v}}": "Wert: {{pub.grid_v}}",
  "DEVICE ID ODBIORCY": "EMPFÄNGER DEVICE-ID",
  "PAYLOAD (opc.)": "PAYLOAD (opt.)",
  "WYRAŻENIE": "AUSDRUCK",
  "ZAPISZ DO": "SPEICHERN NACH",
  "ZAPISZ DO (opc.)": "SPEICHERN NACH (opt.)",
  "JSON PATH (opc.)": "JSON-PFAD (opt.)",
  "ENCJA": "ENTITÄT",
  "FUNKCJA": "FUNKTION",
  "PRÓBKI": "PROBEN",

  // ── Akcje wiadomości / wiadomości ────────────────────────────
  "Usuń akcję": "Aktion löschen",
  "Brak akcji. Dodaj przyciskiem +": "Keine Aktionen. Mit + hinzufügen",
  "Automatyczne akcje wykonywane, gdy node odbierze wiadomość o podanym ID (albo \"*\" dla wszystkich).":
      "Automatische Aktionen, wenn der Node eine Nachricht mit der angegebenen ID empfängt (oder \"*\" für alle).",
  "ID wiadomości triggera — \"alarm\", \"update\", \"*\" = wszystkie":
      "Trigger-Nachrichten-ID — \"alarm\", \"update\", \"*\" = alle",
  "powiadomienie na telefon (tytuł/treść; {{from}}, {{payload}})":
      "Benachrichtigung aufs Handy (Titel/Inhalt; {{from}}, {{payload}})",
  "URL do wywołania HTTP POST z payloadem wiadomości":
      "URL für HTTP POST mit dem Nachrichten-Payload",
  "Zapisz encje z payloadu jako {prefix}.entity_id na nodzie":
      "Payload-Entitäten als {prefix}.entity_id auf dem Node speichern",
  "ID skryptu do uruchomienia przy odebraniu wiadomości":
      "Skript-ID, die beim Empfang der Nachricht ausgeführt wird",
  "Edytuj akcję": "Aktion bearbeiten",
  "Nowa akcja": "Neue Aktion",
  "alarm, update, * (wszystkie)": "alarm, update, * (alle)",
  "POWIADOMIENIE": "BENACHRICHTIGUNG",
  "Tytuł — np. Od {from}": "Titel — z. B. Von {from}",
  "Treść — np. {message}": "Inhalt — z. B. {message}",
  "msg  →  zapisze jako msg.*": "msg  →  gespeichert als msg.*",
  "ID skryptu do uruchomienia": "Auszuführende Skript-ID",
  "Brak wiadomości w skrzynce.": "Keine Nachrichten im Posteingang.",
  "· %s nieprzeczytanych": "· %s ungelesen",
  "od: %s": "von: %s",
  "(brak payloadu)": "(kein Payload)",

  // ── Setup / Onboarding ───────────────────────────────────────
  "Włącz Bluetooth": "Bluetooth einschalten",
  "Lokalizacja (GPS) jest wyłączona — na Androidzie 11 i starszych jest wymagana do skanowania Bluetooth.":
      "Standort (GPS) ist aus — auf Android 11 und älter ist er für das Bluetooth-Scannen erforderlich.",
  "Wpisz nazwę sieci WiFi": "WLAN-Namen eingeben",
  "Łączenie przez BLE...": "Verbindung über BLE...",
  "Łączenie z nodem...": "Verbindung zum Node...",
  "Autoryzacja BLE...": "BLE-Autorisierung...",
  "Brak nonce — aktualizuj firmware": "Keine Nonce — Firmware aktualisieren",
  "Zły PIN — sprawdź kod ustawiony na urządzeniu":
      "Falsche PIN — prüfe den auf dem Gerät gesetzten Code",
  "Nie udało się połączyć z nodem przez Bluetooth. Upewnij się, że node jest w trybie konfiguracji (przytrzymaj przycisk ~3 s), podejdź bliżej i przełącz Bluetooth. Jeśli resetowałeś node — wróć do skanowania, bo ma teraz nową nazwę.":
      "Bluetooth-Verbindung zum Node fehlgeschlagen. Stelle sicher, dass der Node im Einrichtungsmodus ist (Taste ~3 s halten), geh näher heran und schalte Bluetooth aus/ein. Falls du den Node zurückgesetzt hast, geh zurück zum Scannen — er hat jetzt einen neuen Namen.",
  "Wpisz PIN urządzenia": "Geräte-PIN eingeben",
  "Autoryzacja nieudana": "Autorisierung fehlgeschlagen",
  "Sprawdzam portfel...": "Wallet wird geprüft...",
  "Odzyskiwanie portfela z noda...":
      "Wallet wird vom Node wiederhergestellt...",
  "Brak kopii na nodzie": "Keine Sicherung auf dem Node",
  "Tworzę nowy portfel...": "Neues Wallet wird erstellt...",
  "Podpisywanie challenge...": "Challenge wird signiert...",
  "Łączę z WiFi przez node...": "WLAN-Verbindung über den Node...",
  "Łączę z nodem przez sieć...": "Verbindung zum Node über das Netzwerk...",
  "Podłącz urządzenie": "Gerät verbinden",
  "Szukam...": "Suche...",
  "Znalezione urządzenia": "Gefundene Geräte",
  "Brak urządzeń.\nUpewnij się, że node jest w trybie konfiguracji.":
      "Keine Geräte.\nStelle sicher, dass der Node im Konfigurationsmodus ist.",
  "Podaj dane WiFi": "WLAN-Zugangsdaten eingeben",
  "Nazwa sieci WiFi (SSID)": "WLAN-Name (SSID)",
  "Hasło WiFi": "WLAN-Passwort",
  "PIN noda (zapisany w urządzeniu)": "Node-PIN (im Gerät gespeichert)",
  "Konfiguruj": "Konfigurieren",
  "← Wróć do skanowania": "← Zurück zur Suche",
  // ── Odtwarzanie ID noda (po reflashu) ──
  "Odtwórz ID noda": "Node-ID wiederherstellen",
  "Ta płytka przejmie ID i historię wybranego noda offline (np. po reflashu).":
      "Dieses Board übernimmt ID und Verlauf des gewählten Offline-Nodes (z. B. nach einem Reflash).",
  "Odtwarzam poprzednie ID noda...":
      "Vorherige Node-ID wird wiederhergestellt...",
  "Ta płytka ma za stary firmware, żeby odtworzyć ID. Zaflashuj najnowszy firmware na sensmos.com/flash i spróbuj ponownie.":
      "Die Firmware dieses Boards ist zu alt, um eine ID wiederherzustellen. Flashe die neueste Firmware auf sensmos.com/flash und versuche es erneut.",
  "Ta płytka nie umie odtworzyć ID (firmware: %s). Zaflashuj najnowszy firmware na sensmos.com/flash i spróbuj ponownie.":
      "Dieses Board kann keine ID wiederherstellen (Firmware: %s). Flashe die neueste Firmware auf sensmos.com/flash und versuche es erneut.",
  "Usunięto nieaktywny wpis %s (node po reflashu)":
      "Inaktiven Eintrag %s entfernt (Node nach Reflash)",
  "Nie udało się zarejestrować noda": "Node-Registrierung fehlgeschlagen",
  "Urządzenie się resetuje — zaczekaj i spróbuj ponownie.":
      "Das Gerät startet neu — warte und versuche es erneut.",
  "Może potrwać do 30 sekund": "Kann bis zu 30 Sekunden dauern",
  "Gotowe!": "Fertig!",
  "Przejdź do panelu (%s)": "Zum Dashboard (%s)",
  "Przejdź do panelu": "Zum Dashboard",
  "Twoje urządzenia. Twoje dane. Twoja sieć.":
      "Deine Geräte. Deine Daten. Dein Netzwerk.",
  "Podłącz czujnik i monitoruj okolicę":
      "Sensor anschließen und die Umgebung überwachen",
  "Wymieniaj dane z sąsiadami": "Daten mit Nachbarn austauschen",
  "Alerty na telefon": "Alarme aufs Handy",
  "Połącz node": "Node verbinden",
  "Portfel powstaje przy pierwszym nodzie albo jest odzyskiwany z noda przez Bluetooth.":
      "Das Wallet wird mit dem ersten Node erstellt oder per Bluetooth vom Node wiederhergestellt.",

  // ── Ustawienia noda ──────────────────────────────────────────
  "Ustawienia noda": "Node-Einstellungen",
  "odebrane wiadomości na nodzie": "auf dem Node empfangene Nachrichten",
  "akcje na odebrane wiadomości (webhook, encje)":
      "Aktionen auf empfangene Nachrichten (Webhook, Entitäten)",
  "automatyzacje noda": "Node-Automatisierungen",
  "Lokalizacja": "Standort",
  "współrzędne noda": "Node-Koordinaten",
  "Lokalizacja noda": "Node-Standort",
  "Integracja (webhook)": "Integration (Webhook)",
  "URL wywoływany przy zdarzeniach noda":
      "URL, die bei Node-Ereignissen aufgerufen wird",
  "Zaufanie (trust)": "Vertrauen (Trust)",
  "ceremonia potwierdzająca fizyczne urządzenie":
      "Zeremonie zur Bestätigung des physischen Geräts",
  "Zmień PIN": "PIN ändern",
  "PIN dostępu do noda": "Zugriffs-PIN des Nodes",
  "Tryb serwisowy (Bluetooth)": "Servicemodus (Bluetooth)",
  "zmiana WiFi / odzyskiwanie portfela":
      "WLAN ändern / Wallet wiederherstellen",
  "Usuń node z listy": "Node von der Liste entfernen",
  "Usuwa node tylko z tej apki": "Entfernt den Node nur aus dieser App",
  "Usuń node z sieci (permanentnie)":
      "Node aus dem Netzwerk löschen (dauerhaft)",
  "Kasuje node i wszystkie jego dane z SENSMOS. Możesz go później dodać ponownie (onboarding przez Bluetooth). Zarobione GALU zostają w Twoim portfelu.":
      "Löscht den Node und alle seine Daten aus SENSMOS. Du kannst ihn später wieder hinzufügen (Bluetooth-Onboarding). Verdiente GALU bleiben in deinem Wallet.",
  "Usunąć node z sieci?": "Node aus dem Netzwerk löschen?",
  "Node %s i WSZYSTKIE jego dane zostaną trwale usunięte z SENSMOS. Możesz go później dodać ponownie (onboarding przez Bluetooth). Zarobione GALU pozostają w Twoim portfelu.":
      "Node %s und ALLE seine Daten werden dauerhaft aus SENSMOS gelöscht. Du kannst ihn später wieder hinzufügen (Bluetooth-Onboarding). Verdiente GALU bleiben in deinem Wallet.",
  "Usuń permanentnie": "Dauerhaft löschen",
  "Node usunięty z sieci": "Node aus dem Netzwerk gelöscht",
  "Błąd usuwania: %s": "Löschfehler: %s",
  "Brak portfela": "Kein Wallet",
  "Importujesz INNY portfel (%s) niż obecny (%s).\n\nTwoje nody pozostaną przypisane do obecnego portfela, dopóki nie dodasz ich ponownie przez Bluetooth (to zmieni właściciela i wymaga ponownej weryfikacji — bez resetu urządzenia). Zarobione GALU zostają przy portfelu, który je zarobił.":
      "Du importierst ein ANDERES Wallet (%s) als das aktuelle (%s).\n\nDeine Nodes bleiben dem aktuellen Wallet zugeordnet, bis du sie erneut über Bluetooth hinzufügst (das ändert den Besitzer und erfordert eine erneute Verifizierung — ohne Geräte-Reset). Verdiente GALU bleiben bei dem Wallet, das sie verdient hat.",

  "Moje nody w sieci": "Meine Nodes im Netzwerk",
  "Wszystkie nody zarejestrowane na Twój portfel (wg SENSMOS)":
      "Alle auf dein Wallet registrierten Nodes (laut SENSMOS)",
  "brak w tej apce": "nicht in dieser App",
  "nieaktywny": "inaktiv",
  "ID skopiowane: %s": "ID kopiert: %s",
  "Kopiuj ID noda": "Node-ID kopieren",
  "Kopiuj ID": "ID kopieren",
  "Importuj klucz prywatny": "Privaten Schlüssel importieren",
  "Importuj portfel": "Wallet importieren",
  "Monitoruj sieć i internet": "Netzwerk und Internet überwachen",
  "Korzystałeś już z SENSMOS?": "Hast du SENSMOS schon genutzt?",
  "Wyszukaj moje nody w sieci WiFi": "Meine Nodes im WLAN suchen",
  "Wyszukaj moje nody": "Meine Nodes suchen",
  "Node dodany": "Node hinzugefügt",
  "Zły PIN": "Falsche PIN",
  "Szukam noda...": "Node wird gesucht...",
  "Sprawdzam PIN...": "PIN wird geprüft...",
  "Wpisz IP noda — PIN podasz, gdy urządzenie się odnajdzie.":
      "Gib die Node-IP ein — die PIN folgt, sobald das Gerät gefunden ist.",
  "brak portfela": "kein Wallet",
  "Aplikacja nie ma przypisanego portfela":
      "Der App ist kein Wallet zugeordnet",
  "Zaimportuj go z klucza (zakładka Portfel) albo z noda (rozwiń swój node poniżej → Importuj portfel z noda).":
      "Importiere es aus einem Schlüssel (Tab Wallet) oder von einem Node (Node unten aufklappen -> Wallet vom Node importieren).",
  "import z klucza": "Import aus Schlüssel",
  "Klucz portfela (zaawansowane)": "Wallet-Schlüssel (fortgeschritten)",
  "Usunąć z tej apki?": "Aus dieser App entfernen?",
  "Node zniknie tylko z tego telefonu — zostaje w sieci i dalej nalicza nagrody. Żeby usunąć go z sieci, użyj „Usuń z sieci”.":
      "Der Node verschwindet nur von diesem Handy — er bleibt im Netzwerk und sammelt Belohnungen. Zum Entfernen aus dem Netzwerk nutze Aus dem Netzwerk löschen.",
  "Usuń z apki": "Aus der App entfernen",
  "import / eksport klucza prywatnego":
      "Import / Export des privaten Schlüssels",
  "Brak portfela w apce. Odzyskaj kopię zapisaną na tym nodzie.":
      "Kein Wallet in der App. Stelle die auf diesem Node gespeicherte Kopie wieder her.",
  "Importuj portfel z noda": "Wallet vom Node importieren",
  "Dodaj node": "Node hinzufügen",
  "tworzy nowy portfel": "erstellt ein neues Wallet",
  "masz już portfel (np. w MetaMask)? odzyskaj dostęp do swoich nodów":
      "hast du schon ein Wallet (z. B. MetaMask)? Stelle den Zugriff auf deine Nodes wieder her",
  "wklej klucz z MetaMask (0x… lub 64 hex)":
      "Schlüssel aus MetaMask einfügen (0x… oder 64 Hex)",
  "Wklej klucz prywatny (np. z MetaMask). Rób to tylko na swoim telefonie.":
      "Füge einen privaten Schlüssel ein (z. B. aus MetaMask). Nur auf deinem eigenen Handy tun.",
  "Importuj": "Importieren",
  "Nieprawidłowy klucz prywatny": "Ungültiger privater Schlüssel",
  "Inny portfel": "Anderes Wallet",
  "Zaimportuj mimo to": "Trotzdem importieren",
  "Portfel zaimportowany — Twoje nody działają dalej":
      "Wallet importiert — deine Nodes laufen weiter",
  "Portfel zaimportowany: %s": "Wallet importiert: %s",
  "Błąd importu: %s": "Importfehler: %s",
  "Odebrano nagrody": "Belohnungen abgeholt",
  "Wszystko już odebrane": "Alles bereits abgeholt",
  "Usunąć \"%s\"?": "\"%s\" löschen?",
  "Usunąć akcję dla \"%s\"?": "Aktion für \"%s\" löschen?",
  "Usuń z sieci": "Aus dem Netzwerk löschen",
  "Trwale usuwa node z Twoich urządzeń":
      "Entfernt den Node dauerhaft aus deinen Geräten",
  "Node POST-uje tu zdarzenia (message_received, batch_sent, sub_received, ws_connected). Puste = wyłączone.":
      "Der Node POSTet hier Ereignisse (message_received, batch_sent, sub_received, ws_connected). Leer = deaktiviert.",
  "Integracja wyłączona": "Integration deaktiviert",
  "Webhook zapisany": "Webhook gespeichert",
  "Nowy PIN (min. 4 cyfry)": "Neue PIN (mind. 4 Ziffern)",
  "PIN zmieniony": "PIN geändert",

  // ── Lokalizacja noda (GPS) ───────────────────────────────────
  "Włącz lokalizację (GPS) w telefonie": "Standort (GPS) am Handy einschalten",
  "Brak zgody na lokalizację": "Standortberechtigung verweigert",
  "Pozycja GPS pobrana ✓": "GPS-Position erfasst ✓",
  "Błąd GPS: %s": "GPS-Fehler: %s",
  "Najpierw pobierz pozycję GPS": "Zuerst die GPS-Position abrufen",
  "Lokalizacja potwierdzona i zapisana": "Standort bestätigt und gespeichert",
  "Stań przy nodzie i pobierz pozycję GPS — to potwierdza, że node jest naprawdę tutaj. Miasto uzupełni się samo.":
      "Stell dich neben den Node und rufe die GPS-Position ab — das bestätigt, dass der Node wirklich hier ist. Die Stadt wird automatisch ergänzt.",
  "Pobierz GPS ponownie": "GPS erneut abrufen",
  "Pobierz moją pozycję (GPS)": "Meine Position abrufen (GPS)",
  "POZYCJA GPS": "GPS-POSITION",
  "dokładność ±%s m": "Genauigkeit ±%s m",
  "Brak pozycji — naciśnij przycisk powyżej.":
      "Keine Position — tippe auf den Button oben.",
  "Rozmycie prywatności": "Privatsphäre-Unschärfe",
  "Na mapie ~200–800 m od prawdziwej pozycji (losowo)":
      "Auf der Karte ~200–800 m von der echten Position (zufällig)",
  "Na mapie dokładny adres noda": "Exakte Node-Adresse auf der Karte",
  "Zapisz lokalizację": "Standort speichern",

  // ── Node manager / lista nodów ───────────────────────────────
  "Dodaj": "Hinzufügen",
  "Szukaj": "Suchen",
  "Ręcznie": "Manuell",
  "Jak dodać node?": "Wie füge ich einen Node hinzu?",
  "ESP32 musi być włączony i w trybie konfiguracji (świeci LED)":
      "Der ESP32 muss eingeschaltet und im Konfigurationsmodus sein (LED leuchtet)",
  "Bluetooth musi być włączony na telefonie":
      "Bluetooth muss am Handy aktiviert sein",
  "Telefon musi być połączony z siecią WiFi z dostępem do internetu":
      "Das Handy muss mit einem WLAN mit Internetzugang verbunden sein",
  "WiFi, do której podłączysz node, musi być w zasięgu":
      "Das WLAN für den Node muss in Reichweite sein",
  "Przygotuj nazwę sieci (SSID) i hasło WiFi":
      "Halte WLAN-Namen (SSID) und Passwort bereit",
  "Dodaj nowy node przez BLE": "Neuen Node über BLE hinzufügen",
  "Szuka nodów SENSMOS w sieci WiFi.": "Sucht SENSMOS-Nodes im WLAN.",
  "Szukaj w sieci": "Im Netzwerk suchen",
  "Nie znaleziono nodów w sieci.": "Keine Nodes im Netzwerk gefunden.",
  "Dodany": "Hinzugefügt",
  "Wpisz IP i PIN gdy znasz adres noda.":
      "Gib IP und PIN ein, wenn du die Node-Adresse kennst.",
  "Adres IP noda": "Node-IP-Adresse",
  "Połącz i dodaj": "Verbinden und hinzufügen",
  "Wpisz adres IP": "IP-Adresse eingeben",
  "Brak odpowiedzi z %s.": "Keine Antwort von %s.",
  "Dodaję...": "Wird hinzugefügt...",
  "Panel": "Dashboard",
  "Odśwież": "Aktualisieren",
  "GALU saldo": "GALU-Guthaben",
  "Pokrycie": "Abdeckung",
  "Sąsiedzi": "Nachbarn",
  "Promień": "Radius",
  "Node niedostępny": "Node nicht erreichbar",
  "Brak nodów": "Keine Nodes",
  "Dodaj node przez BLE": "Node über BLE hinzufügen",

  // ── Zaufanie (trust) / tryb serwisowy ────────────────────────
  "Zaufanie noda": "Node-Vertrauen",
  "Przełączam node w tryb Bluetooth…":
      "Node wird in den Bluetooth-Modus geschaltet…",
  "Node nie odpowiada: %s": "Node antwortet nicht: %s",
  "Node restartuje się — szukam przez Bluetooth…":
      "Node startet neu — Suche über Bluetooth…",
  "Nie znalazłem noda przez Bluetooth.\nNode wróci sam do WiFi w ciągu 5 minut.":
      "Node über Bluetooth nicht gefunden.\nEr kehrt innerhalb von 5 Minuten selbst ins WLAN zurück.",
  "Połączono — przeprowadzam ceremonię…": "Verbunden — Zeremonie läuft…",
  "Autoryzacja BLE nieudana (PIN?)": "BLE-Autorisierung fehlgeschlagen (PIN?)",
  "Backend niedostępny — brak seedu ceremonii":
      "Backend nicht erreichbar — kein Zeremonie-Seed",
  "Rundy challenge (%s)…": "Challenge-Runden (%s)…",
  "Weryfikacja w sieci…": "Verifizierung im Netzwerk…",
  "Weryfikacja odrzucona: %s": "Verifizierung abgelehnt: %s",
  "Node zaufany — wraca do WiFi.":
      "Node vertrauenswürdig — kehrt ins WLAN zurück.",
  "Powtórz ceremonię": "Zeremonie wiederholen",
  "Przeprowadź ceremonię": "Zeremonie durchführen",
  "Ceremonia zakończona — node zaufany.":
      "Zeremonie abgeschlossen — Node vertrauenswürdig.",
  "Node zaufany": "Node vertrauenswürdig",
  "Node niezweryfikowany": "Node nicht verifiziert",
  "Ceremonia: %s": "Zeremonie: %s",
  "Przeprowadź ceremonię, aby potwierdzić,\nże to fizyczne urządzenie.":
      "Führe die Zeremonie durch, um zu bestätigen,\ndass dies ein physisches Gerät ist.",
  "Node restartuje się w tryb Bluetooth (zostaw go włączony).":
      "Der Node startet in den Bluetooth-Modus neu (eingeschaltet lassen).",
  "Telefon łączy się i wykonuje szybkie rundy challenge — dowód, że urządzenie jest fizycznie obok.":
      "Das Handy verbindet sich und führt schnelle Challenge-Runden aus — Beweis, dass das Gerät physisch in der Nähe ist.",
  "Node podpisuje atest swoim kluczem, Ty podpisujesz portfelem.":
      "Der Node signiert die Attestierung mit seinem Schlüssel, du signierst mit dem Wallet.",
  "Sieć weryfikuje oba podpisy i oznacza node jako zaufany. Node sam wraca do WiFi.":
      "Das Netzwerk prüft beide Signaturen und markiert den Node als vertrauenswürdig. Der Node kehrt selbst ins WLAN zurück.",
  "Tryb serwisowy": "Servicemodus",
  "Node nieosiągalny po sieci — przytrzymaj przycisk na nodzie 3 s, aż wejdzie w tryb Bluetooth…":
      "Node über das Netzwerk nicht erreichbar — halte die Taste am Node 3 s, bis er in den Bluetooth-Modus wechselt…",
  "Nie znalazłem noda przez Bluetooth.\nUpewnij się, że jest w trybie serwisowym (przycisk 3 s).":
      "Node über Bluetooth nicht gefunden.\nStelle sicher, dass er im Servicemodus ist (Taste 3 s).",
  "Zapisuję WiFi…": "WLAN wird gespeichert…",
  "WiFi zapisane — node restartuje się i łączy z siecią.":
      "WLAN gespeichert — der Node startet neu und verbindet sich.",
  "Pobieram kopię z noda…": "Sicherung wird vom Node geladen…",
  "Ten node nie ma kopii portfela": "Dieser Node hat keine Wallet-Sicherung",
  "Brak kopii": "Keine Sicherung",
  "Portfel odzyskany: %s": "Wallet wiederhergestellt: %s",
  "Wejdź w tryb serwisowy": "In den Servicemodus wechseln",
  "Zmień sieć WiFi": "WLAN-Netzwerk ändern",
  "wpisz nowe SSID i hasło — node przełączy się":
      "neues SSID und Passwort eingeben — der Node wechselt",
  "Odzyskaj portfel z noda": "Wallet vom Node wiederherstellen",
  "pobierz kopię portfela na ten telefon":
      "Wallet-Sicherung auf dieses Handy laden",
  "Po co tryb serwisowy?": "Wozu der Servicemodus?",
  "Zmiana WiFi i odzyskiwanie portfela działają tylko przez Bluetooth (bliskość fizyczna). Node przejdzie w tryb BLE — jeśli jest nieosiągalny po sieci, przytrzymaj przycisk na nodzie ok. 3 s.":
      "WLAN-Wechsel und Wallet-Wiederherstellung funktionieren nur über Bluetooth (physische Nähe). Der Node wechselt in den BLE-Modus — ist er über das Netzwerk nicht erreichbar, halte die Taste am Node ca. 3 s.",
  "Nowa sieć WiFi": "Neues WLAN-Netzwerk",
  "Nazwa sieci (SSID)": "Netzwerkname (SSID)",
  "Hasło": "Passwort",

  // ── Powiadomienia / Ustawienia / Encje / Lokalizacje / Ranking ─
  "Zapisano na %s/%s nodach": "Auf %s/%s Nodes gespeichert",
  "Powiadomienia": "Benachrichtigungen",
  "TOKEN PUSH (FCM)": "PUSH-TOKEN (FCM)",
  "wklej token FCM…": "FCM-Token einfügen…",
  "Włącz na nodach": "Auf Nodes aktivieren",
  "Wyłącz": "Deaktivieren",
  "STAN NA NODACH": "STATUS AUF DEN NODES",
  "włączone · %s…": "aktiviert · %s…",
  "wyłączone": "deaktiviert",
  "Token FCM jest pobierany automatycznie i rozsyłany na nody przy starcie aplikacji. To pole pokazuje aktualny token — możesz go też ręcznie wymusić na nodach. Node przekazuje go do backendu, który wysyła powiadomienia.":
      "Der FCM-Token wird automatisch geholt und beim App-Start an die Nodes verteilt. Dieses Feld zeigt den aktuellen Token — du kannst ihn auch manuell auf die Nodes erzwingen. Der Node leitet ihn ans Backend weiter, das die Benachrichtigungen sendet.",
  "Lokalizacja nodów": "Node-Standorte",
  "współrzędne wszystkich urządzeń": "Koordinaten aller Geräte",
  "token push, włącz/wyłącz na nodach":
      "Push-Token, auf Nodes ein-/ausschalten",
  "Aplikacja": "App",
  "Wersja": "Version",
  "Brak encji": "Keine Entitäten",
  "Publiczne": "Öffentlich",
  "Własne": "Eigene",
  "Zewnętrzne": "Extern",
  "Telemetria": "Telemetrie",
  "Radio LoRa": "LoRa-Funk",
  "Wiek: %s": "Alter: %s",
  "lokalna": "lokal",
  "Brak zapisanych nodów": "Keine gespeicherten Nodes",
  "Ustaw współrzędne każdego noda osobno — pozycja na mapie sieci i regiony scoringu.":
      "Setze die Koordinaten jedes Nodes einzeln — Position auf der Netzwerkkarte und Scoring-Regionen.",
  "Ranking miast": "Städte-Ranking",
  "%s nodów · %s online": "%s Nodes · %s online",

  // ── Pasek nawigacji / powiadomienia ──────────────────────────
  "Nowe powiadomienie\nsprawdź skrzynkę noda":
      "Neue Benachrichtigung\nprüfe den Node-Posteingang",

  // ── Komunikaty z serwisów (wyjątki → snackbar) ───────────────
  "Brak usługi SENSMOS": "SENSMOS-Dienst nicht gefunden",
  "Nie połączono": "Nicht verbunden",
  "Node nie pojawił się w sieci.\nSprawdź SSID i hasło WiFi.":
      "Der Node ist nicht im Netzwerk erschienen.\nPrüfe SSID und WLAN-Passwort.",
  "Node jest skonfigurowany i zarejestrowany, ale apka nie widzi go w tej sieci WiFi.\nTelefon jest prawdopodobnie w innej sieci niż node. Połącz telefon z tą samą siecią WiFi i dodaj node ręcznie (Szukaj nodów w sieci).":
      "Der Node ist eingerichtet und registriert, aber die App sieht ihn in diesem WLAN nicht.\nDein Telefon ist vermutlich in einem anderen Netzwerk als der Node. Verbinde das Telefon mit demselben WLAN und füge den Node manuell hinzu (Nodes im Netzwerk suchen).",
  "Błędny PIN lub uszkodzona kopia": "Falsche PIN oder beschädigte Sicherung",

  // ── Lokalizacja / weryfikacja / prywatność ───────────────────
  "Lokalizacja i weryfikacja": "Standort & Verifizierung",
  "ceremonia BLE + GPS — ustawia pozycję i potwierdza urządzenie":
      "BLE-+-GPS-Zeremonie — setzt die Position und verifiziert das Gerät",
  "PRYWATNOŚĆ": "PRIVATSPHÄRE",
  "Na mapie ~200–800 m od prawdziwej pozycji (losowo).":
      "Auf der Karte ~200–800 m von der echten Position (zufällig).",
  "Na mapie dokładny adres noda.": "Exakte Node-Adresse auf der Karte.",
  "Rozmycie włączone — na mapie ~200–800 m od pozycji":
      "Unschärfe an — auf der Karte ~200–800 m von der Position",
  "Rozmycie wyłączone — na mapie dokładny adres":
      "Unschärfe aus — exakte Adresse auf der Karte",
  "Najpierw ustaw lokalizację (ceremonia powyżej).":
      "Setze zuerst den Standort (Zeremonie oben).",
  "Wymaga firmware 0.27+ — zaktualizuj node.":
      "Erfordert Firmware 0.27+ — aktualisiere den Node.",
  "Wymaga firmware 0.25+ — zaktualizuj node.":
      "Erfordert Firmware 0.25+ — aktualisiere den Node.",
  "Tryb prywatny (ghost)": "Privater Modus (Ghost)",
  "Ukryty z mapy, 0 nagród. Dane działają lokalnie; za subskrypcje płacisz.":
      "Von der Karte verborgen, 0 Belohnungen. Daten funktionieren lokal; Abos kosten weiterhin.",
  "Tryb prywatny włączony — node ukryty z mapy":
      "Privater Modus an — Node von Karte und Belohnungen ausgeblendet",
  "Tryb prywatny wyłączony": "Privater Modus aus",
  "Pobieram pozycję GPS...": "GPS-Position wird abgerufen...",
  "Zaraz poprosimy o lokalizację (GPS) — potwierdza, że node jest fizycznie tutaj. Bez niej node działa, ale zarabia znacznie mniej.":
      "Gleich fragen wir nach dem Standort (GPS) — er bestätigt, dass der Node physisch hier ist. Ohne ihn läuft der Node, verdient aber deutlich weniger.",
  "Brak lokalizacji — node niewidoczny na mapie i nie nalicza nagród.":
      "Kein Standort — Node nicht auf der Karte sichtbar und sammelt keine Belohnungen.",
  "Ustaw lokalizację": "Standort festlegen",
  "Połącz się z siecią noda, aby ustawić lokalizację.":
      "Verbinde dich mit dem Netzwerk des Nodes, um den Standort festzulegen.",
  "Połącz się z siecią WiFi noda, aby zobaczyć encje i zmienić ustawienia.":
      "Verbinde dich mit dem WLAN des Nodes, um Entitäten zu sehen und Einstellungen zu ändern.",

  // ── Widok noda: chmura vs sieć lokalna ───────────────────────
  "raportuje": "meldet",
  "Raportują": "Melden",
  "cisza": "still",
  "brak danych z chmury": "keine Cloud-Daten",
  "W sieci": "Im Netzwerk",
  "Zdalnie": "Remote",
  "przed chwilą": "gerade eben",

  // ── Node-Kopplung (Schlüssel im Telefon, Kanal ausschließlich über LAN) ──
  "Zdalny dostęp": "Fernzugriff",
  "Zapamiętaj hasło na tym telefonie": "Passwort auf diesem Telefon merken",
  "sparowany — terminal i panel HA działają z dowolnego miejsca":
      "gekoppelt — Terminal und HA-Panel funktionieren von überall",
  "NIESPAROWANY — sparuj teraz, będąc w sieci noda":
      "NICHT GEKOPPELT — jetzt koppeln, solange du im Netzwerk des Nodes bist",
  "Sparuj": "Koppeln",
  "Sparuj node": "Node koppeln",
  "Node sparowany.": "Node gekoppelt.",
  "Node sparowany — możesz się połączyć.":
      "Node gekoppelt — du kannst dich jetzt verbinden.",
  "Node niesparowany": "Node nicht gekoppelt",
  "Najpierw sparuj node powyżej.": "Kopple zuerst den Node oben.",
  "Nie znam tego noda na tym telefonie.":
      "Dieses Telefon kennt diesen Node nicht.",
  "Zdalny dostęp wymaga jednorazowego sparowania w tej samej sieci WiFi co node.":
      "Fernzugriff erfordert eine einmalige Kopplung im selben WLAN wie der Node.",
  "Zdalny dostęp wymaga jednorazowego sparowania: telefon zapisze w nodzie tajny klucz, którego nasz serwer nigdy nie zobaczy. Bez niego nikt — łącznie z nami — nie otworzy tunelu do Twojej sieci.\n\nMusisz być teraz w tej samej sieci WiFi co node.":
      "Fernzugriff erfordert eine einmalige Kopplung: Das Telefon speichert einen geheimen Schlüssel auf dem Node, den unser Server nie sieht. Ohne ihn kann niemand — auch wir nicht — einen Tunnel in dein Netzwerk öffnen.\n\nDu musst jetzt im selben WLAN wie der Node sein.",
  "Wyłączyć zdalny dostęp?": "Fernzugriff deaktivieren?",
  "Node skasuje wszystkie klucze — terminal i panel HA przestaną działać ze WSZYSTKICH telefonów, także innych domowników. Ponowne włączenie wymaga bycia w sieci noda.":
      "Der Node löscht alle Schlüssel — Terminal und HA-Panel funktionieren dann auf ALLEN Telefonen nicht mehr, auch bei anderen im Haushalt. Zum Wiedereinschalten musst du im Netzwerk des Nodes sein.",
  "Zdalny dostęp wyłączony.": "Fernzugriff deaktiviert.",
  "Zły PIN noda.": "Falsche Node-PIN.",
  "Nie widzę noda w tej sieci — połącz telefon z tym samym WiFi co node.":
      "Node in diesem Netzwerk nicht gefunden — verbinde das Telefon mit demselben WLAN wie den Node.",
  "Node nie ma zapisanych kluczy (przeflashowany?) — sparuj go ponownie, będąc w jego sieci WiFi.":
      "Der Node hat keine gespeicherten Schlüssel (neu geflasht?) — kopple ihn erneut in seinem WLAN.",
  "Nowa płytka przejęła ID noda — zdalny dostęp wymaga ponownego sparowania: Ustawienia noda → Zdalny dostęp, będąc w jego sieci WiFi.":
      "Eine neue Platine hat die ID dieses Nodes übernommen — Fernzugriff erfordert erneute Kopplung: Node-Einstellungen → Fernzugriff, im WLAN des Nodes.",
  "Odtwarzam parowanie...": "Kopplung wird wiederhergestellt...",
  "Uwaga: to lekka wersja proxy, nie pełny tunel — jedno połączenie naraz, bez WebSocketów i strumieni. Proste panele HTTP zadziałają, ciężkie aplikacje nie.":
      "Hinweis: das ist ein leichtes Proxy, kein voller Tunnel — eine Verbindung auf einmal, keine WebSockets oder Streams. Einfache HTTP-Panels funktionieren, schwere Apps nicht.",
  "Zdalny dostęp sparowany ponownie.": "Fernzugriff erneut gekoppelt.",
  "Node odrzucił parowanie (HTTP %s).":
      "Der Node hat die Kopplung abgelehnt (HTTP %s).",
  "Node odrzucił żądanie (HTTP %s).":
      "Der Node hat die Anfrage abgelehnt (HTTP %s).",
  "Node nie jest sparowany z tym telefonem — sparuj go, będąc w tej samej sieci WiFi.":
      "Dieser Node ist nicht mit diesem Telefon gekoppelt — kopple ihn im selben WLAN.",
  "Wymagane sparowanie": "Kopplung erforderlich",
  "Rozumiem": "Verstanden",
  "Wymaga sparowania noda — tylko w jego sieci WiFi":
      "Erfordert Node-Kopplung — nur in seinem WLAN",
  "Node niesparowany — tunel nie ruszy. Sparuj, będąc w jego sieci WiFi.":
      "Node nicht gekoppelt — der Tunnel startet nicht. Koppeln, solange du in seinem WLAN bist.",
  "Ta integracja otwiera tunel do Twojej sieci, a zgodę na to daje sam node — nie nasz serwer. Trzeba zapisać w nim klucz, będąc w tej samej sieci WiFi: Ustawienia noda → Zdalny dostęp.\n\nIntegrację dodam już teraz, ale połączy się dopiero po sparowaniu.":
      "Diese Integration öffnet einen Tunnel in dein Netzwerk, und das erlaubt nur der Node selbst — nicht unser Server. Dafür musst du einen Schlüssel auf ihm speichern, während du im selben WLAN bist: Node-Einstellungen → Fernzugriff.\n\nIch füge die Integration jetzt hinzu, aber sie verbindet sich erst nach der Kopplung.",
  // ── 1.5.39/40: MQTT + LoRa awaryjne + push przez BE ──────────
  "MQTT (lokalny broker)": "MQTT (lokaler Broker)",
  "publikacja statusu i encji do Mosquitto / Home Assistant":
      "Status und Entitäten an Mosquitto / Home Assistant veröffentlichen",
  "LoRa awaryjne": "LoRa-Notfall",
  "encje nadawane radiem przy padzie internetu":
      "Entitäten, die bei Internetausfall per Funk gesendet werden",
  // ── 1.5.51: sekcja LoRa (odbiór/wysyłka/inbox) + Wydatki usług ──
  "awaryjne, odbiór czujników, wysyłka, inbox":
      "Notfall, Sensor-Empfang, Senden, Inbox",
  "Ten node nie ma radia LoRa (albo firmware bez LoRa).":
      "Dieser Node hat kein LoRa-Funkmodul (oder Firmware ohne LoRa).",
  "Encje nadawane beaconem przy padzie internetu + komendy z Panelu Emergency.":
      "Entitäten, die bei Internetausfall gesendet werden + Befehle aus dem Notfall-Panel.",
  "Odbiór ramek (czujniki LoRa)": "Frame-Empfang (LoRa-Sensoren)",
  "dzień użycia": "Nutzungstag",
  "Fraza-klucz zostaje TYLKO na nodzie — tę samą wpisz w swoje czujniki. Serwer przekazuje ramki na ślepo.":
      "Die Schlüsselphrase bleibt NUR auf dem Node — gib dieselbe in deine Sensoren ein. Der Server leitet Frames blind weiter.",
  "klucz ustawiony — wpisz, by zmienić":
      "Schlüssel gesetzt — tippen zum Ändern",
  "fraza-klucz": "Schlüsselphrase",
  "klucz ustawiony": "Schlüssel gesetzt",
  "brak klucza": "kein Schlüssel",
  "Przyjmuj ramki jawne (bez szyfrowania)": "Unverschlüsselte Frames annehmen",
  "Uwaga: jawną ramkę może nadać każdy, kto zna adres noda.":
      "Hinweis: einen unverschlüsselten Frame kann jeder senden, der die Node-Adresse kennt.",
  "Wyślij ramkę": "Frame senden",
  "adresat (id8)": "Empfänger (id8)",
  "treść (do 128 B)": "Inhalt (bis 128 B)",
  "Podaj dst (8 hex) i treść": "dst (8 Hex) und Inhalt eingeben",
  "Zakolejkowane — nadanie w ciągu kilku(nastu) sekund":
      "In Warteschlange — Senden innerhalb von Sekunden",
  "Inbox LoRa": "LoRa-Inbox",
  "Pusto — ramki i komendy odebrane przez LoRa pojawią się tutaj.":
      "Leer — über LoRa empfangene Frames und Befehle erscheinen hier.",
  "Wydatki usług": "Dienst-Ausgaben",
  "ryczałty dobowe — ostatnie 30 dni": "Tagespauschalen — letzte 30 Tage",
  "Brak naliczeń — płatne funkcje nie były używane.":
      "Keine Abbuchungen — bezahlte Funktionen wurden nicht genutzt.",
  "LoRa: odbiór ramek (AES)": "LoRa: Frame-Empfang (AES)",
  "LoRa: odbiór ramek jawnych": "LoRa: unverschlüsselter Frame-Empfang",
  "LoRa: wysyłka ramek": "LoRa: Frame-Versand",
  "Tunel (SSH / HA / panel)": "Tunnel (SSH / HA / Panel)",
  "Nie można połączyć z nodem: %s": "Node nicht erreichbar: %s",
  "Ten node nie obsługuje MQTT — zaktualizuj firmware do 0.90 lub nowszego.":
      "Dieser Node unterstützt kein MQTT — aktualisiere die Firmware auf 0.90 oder neuer.",
  "Podaj adres brokera": "Broker-Adresse eingeben",
  "Zapisano — node łączy się z brokerem":
      "Gespeichert — der Node verbindet sich mit dem Broker",
  "Połączony z brokerem · wysłano %s wiadomości":
      "Mit dem Broker verbunden · %s Nachrichten gesendet",
  "Łączenie... %s": "Verbinde... %s",
  "Włączone": "Aktiviert",
  "Wyłączone": "Deaktiviert",
  "Node publikuje do brokera w Twojej sieci: status (online/offline), diagnostykę, encje (z auto-wykryciem w Home Assistant) i wiadomości. Działa też bez internetu — temat net/wan mówi, czy internet w domu żyje.":
      "Der Node veröffentlicht an einen Broker in deinem Netzwerk: Status (online/offline), Diagnose, Entitäten (automatisch von Home Assistant erkannt) und Nachrichten. Funktioniert auch ohne Internet — das Topic net/wan sagt dir, ob das Internet zu Hause lebt.",
  "Adres brokera (IP w LAN)": "Broker-Adresse (LAN-IP)",
  "Użytkownik (opcjonalnie)": "Benutzer (optional)",
  "Hasło (opcjonalnie)": "Passwort (optional)",
  "Zapisywanie...": "Speichern...",
  "Ten node nie obsługuje trybu awaryjnego — wymaga firmware 0.91+ na płytce z radiem LoRa (SX1262, wariant -lora).":
      "Dieser Node unterstützt den Notfallmodus nicht — er braucht Firmware 0.91+ auf einer Platine mit LoRa-Funk (SX1262, Variante -lora).",
  "Zapisano — node nada te encje przy awarii":
      "Gespeichert — der Node sendet diese Entitäten bei einem Ausfall",
  "TRYB AWARYJNY AKTYWNY — node nadaje te encje przez LoRa":
      "NOTFALLMODUS AKTIV — der Node sendet diese Entitäten über LoRa",
  "Gdy node straci internet, dołączy wybrane encje (max %s) do ramki radiowej LoRa. Jeśli usłyszy go sąsiedni node albo brama, dostaniesz powiadomienie z ostatnimi wartościami — mimo że Twój dom jest offline.":
      "Verliert der Node das Internet, hängt er die gewählten Entitäten (max. %s) an seinen LoRa-Funkrahmen. Hört ihn ein Nachbar-Node oder ein Gateway, bekommst du eine Benachrichtigung mit den letzten Werten — obwohl dein Zuhause offline ist.",
  "Node nie ma jeszcze żadnych encji.": "Der Node hat noch keine Entitäten.",
  "Maksymalnie %s encje": "Höchstens %s Entitäten",
  "Zapisz (%s/%s)": "Speichern (%s/%s)",
  "Zarejestrowane w SENSMOS": "Bei SENSMOS registriert",
  "Brak tokenu FCM (usługi Google niedostępne?)":
      "Kein FCM-Token (Google-Dienste nicht verfügbar?)",
  "Niezarejestrowane": "Nicht registriert",
  "Zarejestruj ponownie": "Erneut registrieren",
  "Rejestrowanie...": "Registriere...",
  "Token zarejestrowany — powiadomienia aktywne na tym urządzeniu.":
      "Token registriert — Benachrichtigungen sind auf diesem Gerät aktiv.",
  "Rejestracja nie powiodła się — sprawdź internet i spróbuj ponownie.":
      "Registrierung fehlgeschlagen — prüfe deine Internetverbindung und versuche es erneut.",
  "Powiadomienia rejestrują się automatycznie przy starcie aplikacji — jedna rejestracja obejmuje wszystkie Twoje nody (akcje skryptów, wiadomości, alarm o utracie łączności przez LoRa). Wyłączysz je w systemowych ustawieniach powiadomień.":
      "Benachrichtigungen registrieren sich automatisch beim App-Start — eine Registrierung deckt alle deine Nodes ab (Skript-Aktionen, Nachrichten, der LoRa-Verbindungsverlust-Alarm). Abschalten kannst du sie in den System-Benachrichtigungseinstellungen.",
  "Brak powiadomień": "Keine Benachrichtigungen",
  // ── 1.5.42: plugin Raport łącza ──────────────────────────────
  "Raport łącza": "Verbindungsbericht",
  "Łącze": "Verbindung",
  "Okres": "Zeitraum",
  "ostatnie %s dni": "letzte %s Tage",
  "Przerwy w dostępie do internetu": "Internetausfälle",
  "Łączny czas bez internetu": "Gesamtzeit ohne Internet",
  "Najdłuższa przerwa": "Längster Ausfall",
  "Pomiar niezależny, 24/7, stempel czasu NTP":
      "Unabhängige Messung, 24/7, NTP-Zeitstempel",
  "%s dni": "%s Tage",
  "Twój internet (wina dostawcy)": "Dein Internet (Schuld des Anbieters)",
  "przerw": "Ausfälle",
  "bez internetu": "ohne Internet",
  "najdłuższa": "längster",
  "Pozostałe %s przerw to chwilowe prace po stronie SENSMOS — nie liczą się do raportu.":
      "Die übrigen %s Unterbrechungen waren kurze SENSMOS-Wartungen — sie zählen nicht zum Bericht.",
  "Raport skopiowany — wklej go do reklamacji":
      "Bericht kopiert — füge ihn in deine Beschwerde ein",
  "Kopiuj raport": "Bericht kopieren",
  "Brak zaników w tym okresie — łącze działało bez przerw. 🎉":
      "Keine Ausfälle in diesem Zeitraum — die Verbindung lief ohne Unterbrechung. 🎉",
  "internet nie działał (wina dostawcy)":
      "Internet war down (Schuld des Anbieters)",
  "serwis SENSMOS — nie liczy się do raportu":
      "SENSMOS-Wartung — zählt nicht zum Bericht",
  // ── 1.5.43: plugin Panel LAN ─────────────────────────────────
  "Panel LAN": "LAN-Panel",
  "HTTP w LAN": "HTTP im LAN",
  "Dodaj panel": "Panel hinzufügen",
  "Edytuj panel": "Panel bearbeiten",
  "Nazwa": "Name",
  "Adres w LAN": "LAN-Adresse",
  "Tylko HTTP. Ciężkie panele (UniFi, HA) nie zadziałają — tunel jest wolny.":
      "Nur HTTP. Schwere Panels (UniFi, HA) funktionieren nicht — der Tunnel ist langsam.",
  "Dodaj panele WWW z sieci noda (router, drukarka, Pi-hole…) — otworzysz je stąd z dowolnego miejsca, przez tunel.":
      "Füge Web-Panels aus dem Netzwerk des Nodes hinzu (Router, Drucker, Pi-hole…) — du öffnest sie von überall, durch den Tunnel.",
  "Otwieram tunel do noda…": "Öffne den Tunnel zum Node…",
  "Podaj adres w LAN": "Gib die LAN-Adresse ein",
  "LoRa awaryjne — słyszany radiem": "LoRa-Notfall — per Funk gehört",
  "LoRa awaryjne — bez internetu, słyszany %s temu przez %s":
      "LoRa-Notfall — kein Internet, vor %s gehört von %s",
  // ── Panel Emergency (model v2) ──
  "Panel Emergency": "Emergency-Panel",
  "Panel Emergency — encje i komenda": "Emergency-Panel — Entitäten & Befehl",
  "Node bez internetu — nadaje przez LoRa": "Node offline — sendet über LoRa",
  "Node ma łączność z serwerem (WS)": "Node ist mit dem Server verbunden (WS)",
  "Ostatnia ramka %s temu · usłyszał %s":
      "Letzter Frame vor %s · gehört von %s",
  "Brak ramek emergency — czekam na pierwszy beacon":
      "Noch keine Notfall-Frames — warte auf den ersten Beacon",
  "Ostatni kontakt WS: %s temu": "Letzter WS-Kontakt: vor %s",
  "Encje awaryjne": "Notfall-Entitäten",
  "Nie wybrano encji awaryjnych (Ustawienia noda → LoRa awaryjne)":
      "Keine Notfall-Entitäten gewählt (Node-Einstellungen → Notfall-LoRa)",
  "odebrano %s temu": "empfangen vor %s",
  "Komenda do noda": "Befehl an den Node",
  "Max 8 znaków. Node przekaże ją do inboxu, MQTT/HA i webhooka (jeśli ustawiony).":
      "Max. 8 Zeichen. Der Node leitet ihn an Inbox, MQTT/HA und den Webhook (falls gesetzt) weiter.",
  "Webhook przy komendzie (opcjonalny)": "Webhook bei Befehl (optional)",
  "Gdy node odbierze komendę przez LoRa, wyśle POST na ten adres w Twojej sieci (np. UniFi Protect). Komenda trafia też do inboxu i MQTT/HA.":
      "Wenn der Node einen Befehl über LoRa empfängt, sendet er einen POST an diese Adresse in deinem Netzwerk (z. B. UniFi Protect). Der Befehl geht auch an Inbox und MQTT/HA.",
  "Wyślij przez LoRa": "Über LoRa senden",
  "Komenda w kolejce — poleci przez najbliższy przekaźnik":
      "Befehl in der Warteschlange — geht über das nächste Relais raus",
  "Historia komend": "Befehlsverlauf",
  "ODEBRANA przez node": "Vom Node EMPFANGEN",
  "wysłana": "gesendet",
  "nieudana": "fehlgeschlagen",
  "w kolejce": "in Warteschlange",
  "Wpisz komendę: 1-8 znaków ASCII, bez spacji":
      "Befehl eingeben: 1-8 ASCII-Zeichen, ohne Leerzeichen",
  "Złe hasło": "Falsches Passwort",
  "%s temu": "vor %s",
  "Tryb LoRa uzbraja się ~2 min po padzie; ramka leci co ~4 min":
      "Der LoRa-Modus aktiviert sich ~2 Min. nach dem Ausfall; ein Frame geht alle ~4 Min. raus",
  "Komenda LoRa jest dostępna, gdy node straci łączność z serwerem":
      "Der LoRa-Befehl ist verfügbar, wenn der Node die Serververbindung verliert",
  "LoRa awaryjne — ostatni epizod %s temu":
      "LoRa-Notfall — letzte Episode vor %s",
  "Limit komend wyczerpany — spróbuj za ~%s min":
      "Befehlslimit erreicht — versuch es in ~%s Min. erneut",
  "Komendy w tej godzinie: %s/%s — airtime LoRa jest wspólny":
      "Befehle in dieser Stunde: %s/%s — LoRa-Airtime wird geteilt",

  // ── 1.5.52: token ownera, lista celów SSH, widgety ──────────
  "Błędne hasło portfela.": "Falsches Wallet-Passwort.",
  "Pytamy ostatni raz: apka zapamięta osobny klucz dostępu do tuneli, więc portfel może zostać zamknięty.":
      "Wir fragen zum letzten Mal: Die App merkt sich einen separaten Tunnel-Zugriffsschlüssel, das Wallet kann also gesperrt bleiben.",
  "Nie udało się wydać tokenu dostępu.":
      "Zugriffstoken konnte nicht ausgestellt werden.",
  "Podaj adres w sieci noda.": "Gib eine Adresse im Netzwerk des Nodes ein.",
  "Nowe połączenie": "Neue Verbindung",
  "Edytuj połączenie": "Verbindung bearbeiten",
  "Maszyna w sieci noda — otworzysz ją stąd z dowolnego miejsca, przez tunel.":
      "Ein Rechner im Netzwerk des Nodes — von überall erreichbar, durch den Tunnel.",
  "Cel widgetu „Terminal\"": "Ziel des „Terminal“-Widgets",
  "Widget na pulpicie otworzy od razu to połączenie, bez pytania.":
      "Das Homescreen-Widget öffnet diese Verbindung sofort, ohne Nachfrage.",
  "Cel widgetu na pulpicie": "Ziel des Homescreen-Widgets",
  "Połączenie jednorazowe": "Einmalige Verbindung",
  "Podaj adres w LAN.": "Gib eine Adresse im LAN ein.",
  "Cel widgetu „Panel HA\"": "Ziel des „HA-Panel“-Widgets",
  "Widget na pulpicie otworzy od razu ten node, bez pytania.":
      "Das Homescreen-Widget öffnet diesen Node sofort, ohne Nachfrage.",
  "Wybierz node — plugin zostanie do niego podpięty.":
      "Wähle einen Node — das Plugin wird ihm hinzugefügt.",
  "Dodaj połączenie": "Verbindung hinzufügen",
  "Nazwa celu": "Name des Ziels",
  "Panel WWW w sieci noda — router, drukarka, Pi-hole. Otworzysz go stąd z dowolnego miejsca, przez tunel.":
      "Ein Web-Panel im Netzwerk des Nodes — Router, Drucker, Pi-hole. Von überall erreichbar, durch den Tunnel.",
  "Dodaj maszyny z sieci noda (serwer, NAS, Raspberry) — otworzysz je stąd z dowolnego miejsca, przez tunel.":
      "Füge Rechner aus dem Netzwerk des Nodes hinzu (Server, NAS, Raspberry) — von überall erreichbar, durch den Tunnel.",
  "Powiadomienia aktywne": "Benachrichtigungen sind an",
  "Nieaktywne — dotknij, aby włączyć": "Aus — zum Einschalten tippen",
  "Nie udało się włączyć powiadomień.":
      "Benachrichtigungen konnten nicht aktiviert werden.",
  "Nowy PIN musi mieć co najmniej 4 znaki.":
      "Die neue PIN muss mindestens 4 Zeichen haben.",
  "Zły obecny PIN. Jeśli zmieniałeś go z innego telefonu, wpisz tamten; po przeflashowaniu noda PIN wraca do 123456.":
      "Falsche aktuelle PIN. Wenn du sie von einem anderen Telefon geändert hast, gib diese ein; nach einem Neu-Flash des Nodes ist die PIN wieder 123456.",
  "Za dużo prób — node blokuje zmianę na 30 sekund.":
      "Zu viele Versuche — der Node sperrt die Änderung für 30 Sekunden.",
  "Node odrzucił zmianę (HTTP %s).":
      "Der Node hat die Änderung abgelehnt (HTTP %s).",
  "Nie widzę noda pod %s — połącz telefon z tą samą siecią WiFi.":
      "Keine Antwort von %s — verbinde das Telefon mit demselben WLAN.",
  "PIN chroni lokalne API noda: ustawienia, skrypty, MQTT i tryb serwisowy. Zmiana działa tylko w sieci noda.":
      "Die PIN schützt die lokale API des Nodes: Einstellungen, Skripte, MQTT und Servicemodus. Ändern geht nur im Netzwerk des Nodes.",
  "Obecny PIN": "Aktuelle PIN",
  "Nowy PIN (min. 4 znaki)": "Neue PIN (mindestens 4 Zeichen)",
  "Po zmianie inne telefony z tym nodem zachowają stary PIN — trzeba go tam poprawić w tym samym miejscu.":
      "Nach der Änderung behalten andere Telefone mit diesem Node die alte PIN — dort an derselben Stelle korrigieren.",
  "Node ma za stare oprogramowanie — zaktualizuj je.":
      "Die Firmware des Nodes ist zu alt — bitte aktualisiere sie.",
  "Node ma za stare oprogramowanie (%s) — zaktualizuj je do 1.01 lub nowszego.":
      "Die Firmware des Nodes ist zu alt (%s) — aktualisiere sie auf 1.01 oder neuer.",
  "Ramka odrzucona — zerwane szyfrowanie tunelu.":
      "Frame abgelehnt — die Tunnel-Verschlüsselung ist gebrochen.",
  "Zapisuję PIN…": "PIN wird gespeichert…",
  "Ustaw nowy PIN": "Neue PIN setzen",
  "gdy PIN się rozjechał albo go nie pamiętasz":
      "wenn die PIN auseinandergelaufen ist oder du sie nicht mehr weißt",
  "Nowy PIN": "Neue PIN",
  "Połączenie serwisowe jest już autoryzowane — starego PIN-u nie trzeba znać.":
      "Die Serviceverbindung ist bereits autorisiert — die alte PIN musst du nicht kennen.",
  "PIN ustawiony. Inne telefony z tym nodem trzeba poprawić osobno.":
      "PIN gesetzt. Andere Telefone mit diesem Node musst du separat korrigieren.",
  "Ustawiam PIN na nodzie...": "PIN wird auf dem Node gesetzt...",
  "Bez PIN-u sprzed zmiany nie odczytam kopii portfela z noda.":
      "Ohne die PIN von vor der Änderung kann ich die Wallet-Kopie vom Node nicht lesen.",
  "PIN sprzed zmiany": "PIN von vor der Änderung",
  "Kopia portfela na nodzie jest zaszyfrowana PIN-em, który obowiązywał w chwili jej zapisu. Podaj tamten PIN — nowy jest już ustawiony i zostaje.":
      "Die Wallet-Kopie auf dem Node ist mit der PIN verschlüsselt, die beim Speichern galt. Gib diese PIN ein — die neue ist bereits gesetzt und bleibt.",
  "Poprzedni PIN": "Vorherige PIN",
  "Pomiń": "Überspringen",
  "Odczytaj": "Auslesen",
  "Wiadomość": "Nachricht",
  "Zwiń do paska": "In die Leiste einklappen",

  // ── 1.5.57: Store (Dysk) ──────────────────────────────
  "Zmniejsz o 1 GB (−%s GALU/dobę)": "Um 1 GB verkleinern (−%s GALU/Tag)",
  "Zmniejszam…": "Verkleinere…",
  "Wykupić pakiet %s GB za %s GALU na dobę?":
      "%s-GB-Paket für %s GALU pro Tag kaufen?",
  "Opłata nalicza się za każdą dobę, także przy pustym pakiecie. Pakiet zamkniesz w każdej chwili.":
      "Berechnet wird jeder Tag, auch bei leerem Paket. Du kannst es jederzeit schließen.",
  "Zamykam pakiet…": "Paket wird geschlossen…",
  "Zamknij pakiet": "Paket schließen",
  "Zamknąć pakiet?": "Paket schließen?",
  "Usunie %s plików u sprzedawców. Opłaty kończą się z tą dobą, ponowny zakup zaczyna od zera.":
      "Löscht %s Dateien bei den Anbietern. Die Gebühren enden mit heute; ein Neukauf beginnt von vorn.",
  "Pakiet zamknięty": "Paket geschlossen",
  "Dodatki": "Erweiterungen",
  "Brama LoRa": "LoRa-Gateway",
  "meldunków: %s": "Meldungen: %s",
  "od %s": "seit %s",
  "offline": "offline",
  "oferowane %s GB · zajęte %s GB": "angeboten %s GB · %s GB belegt",
  "kopii u Ciebie: %s · dowody 7 dni: %s ✓ %s ✗":
      "Kopien bei dir: %s · Beweise 7 Tage: %s ✓ %s ✗",
  "zarobek 7 dni: %s · łącznie: %s GALU":
      "Verdienst 7 Tage: %s · gesamt: %s GALU",
  "Odłączyć %s?": "%s trennen?",
  "Token przystawki zostanie odebrany, agent natychmiast traci dostęp.":
      "Das Token wird entzogen; der Agent verliert sofort den Zugriff.",
  "Odłącz": "Trennen",
  "Odłączono": "Getrennt",
  "Miejsce na pliki u innych właścicieli nodów, szyfrowane w telefonie.":
      "Platz für deine Dateien bei anderen Node-Besitzern, auf dem Telefon verschlüsselt.",
  "Kup miejsce": "Speicher kaufen",
  "plików: %s · %s GALU na dobę": "Dateien: %s · %s GALU pro Tag",
  "Zaległość: %s dni — wysyłki wstrzymane, doładuj GALU":
      "Rückstand: %s Tage — Uploads pausiert, GALU aufladen",
  "Ukryj kartę": "Karte ausblenden",
  "Karta ukryta — włączysz ją w Ustawieniach":
      "Karte ausgeblendet — in den Einstellungen wieder einschalten",
  "Storage na ekranie nodów": "Storage auf dem Node-Bildschirm",
  "karta pakietu pod listą nodów": "Paketkarte unter der Node-Liste",
  "Obiekt bez klucza (wysyłka testowa) — nie da się odszyfrować":
      "Objekt ohne Schlüssel (Test-Upload) — nicht entschlüsselbar",
  "Dysk": "Speicher",
  "Miejsce w sieci": "Platz im Netzwerk",
  "Sprzedawców online: %s": "Anbieter online: %s",
  "Wolnych pakietów: %s": "Freie Pakete: %s",
  "Tryb testowy": "Testmodus",
  "Wykup pakiet %s GB (%s GALU/dobę)": "%s-GB-Paket kaufen (%s GALU/Tag)",
  "Brak wolnego miejsca — wróć później":
      "Kein freier Platz — später wiederkommen",
  "Pakiet %s GB · zajęte %s GB": "Paket %s GB · %s GB belegt",
  "%s GALU na dobę · kopii: %s": "%s GALU pro Tag · Kopien: %s",
  "Dokup 1 GB (+%s GALU/dobę)": "1 GB dazukaufen (+%s GALU/Tag)",
  "Dodaj plik": "Datei hinzufügen",
  "Brak plików": "Noch keine Dateien",
  "kopii: %s": "Kopien: %s",
  "Wykupuję pakiet…": "Paket wird gekauft…",
  "Dokupuję…": "Platz wird dazugekauft…",
  "Szyfrowanie…": "Verschlüsselung…",
  "Pobieranie…": "Herunterladen…",
  "Odszyfrowywanie…": "Entschlüsselung…",
  "Pobrano: %s": "Gespeichert: %s",
  "Plik jest pusty": "Die Datei ist leer",
  "Za duży plik do pobrania na telefon (limit %s MB)":
      "Zu groß zum Herunterladen aufs Telefon (Limit %s MB)",
  "Usunąć %s?": "%s löschen?",
  "Portfel wymagany": "Wallet erforderlich",

  // ── dopisane 2026-09-09: brakowało tłumaczeń, obcojęzyczny user widział polski tekst ──
  "%s GB · %s GALU na dobę": "%s GB · %s GALU pro Tag",
  "Do wyboru teraz: %s GB": "Jetzt verfügbar: %s GB",
  "LoRa": "LoRa",
  "OK": "OK",
  "Sprzedawców gotowych: %s · wolne w sieci: %s GB":
      "Bereite Anbieter: %s · frei im Netz: %s GB",
  "Twoje pliki szyfruje telefon kluczem z portfela. Sprzedawcy trzymają szyfrogram w %s kopiach u różnych właścicieli i nie mogą go odczytać.":
      "Dein Telefon verschlüsselt die Dateien mit einem Schlüssel aus deiner Wallet. Anbieter halten den Geheimtext in %s Kopien bei verschiedenen Besitzern und können ihn nicht lesen.",
  "Wykup %s GB": "%s GB kaufen",
  "Zobacz, ile miejsca ma sieć": "Sieh, wie viel Platz das Netz hat",
  // ── archiwum pomiarów 2026-09-09 ──
  "Archiwum pomiarów": "Messarchiv",
  "Pomiary z Twoich nodów kasujemy po 48 godzinach. Włącz, a raz na dobę wylądują w tym pakiecie — zaszyfrowane Twoim kluczem, więc my ich nie odczytamy. Rok historii jednego noda to kilka MB.":
      "Messwerte deiner Nodes löschen wir nach 48 Stunden. Schalte das ein, und einmal täglich landen sie in diesem Paket — mit deinem Schlüssel verschlüsselt, wir können sie also nicht lesen. Ein Jahr Historie eines Nodes sind wenige MB.",
  "Wstrzymane: %s — przestaw przełącznik, żeby wznowić.":
      "Angehalten: %s — Schalter umlegen, um fortzufahren.",
  "Ostatnia zapisana doba: %s": "Zuletzt archivierter Tag: %s",
  "Pierwsza paczka pojawi się po najbliższej pełnej dobie.":
      "Das erste Paket erscheint nach dem nächsten vollen Tag.",
  "Włączam archiwum…": "Archiv wird eingeschaltet…",
  "Wyłączam archiwum…": "Archiv wird ausgeschaltet…",
  // ── konto bez noda 2026-09-09 ──
  "Chcę tylko miejsce na pliki": "Ich will nur Platz für Dateien",
  "Zakładamy portfel, node nie jest potrzebny.":
      "Wir legen eine Wallet an; ein Node ist nicht nötig.",
  "Portfel gotowy: %s. Zapisz klucz (Portfel → Klucz prywatny) — bez noda to jedyna kopia.":
      "Wallet bereit: %s. Sichere den Schlüssel (Wallet → Privater Schlüssel) — ohne Node ist das die einzige Kopie.",
  "albo bez własnego sprzętu": "oder ganz ohne eigene Hardware",
  "GALU dostaniesz od kogoś, kto ma nody, albo wpłacisz je w portfelu.":
      "GALU bekommst du von jemandem mit Nodes, oder du zahlst es in deiner Wallet ein.",
  // ── obietnice na ekranie powitalnym 2026-09-09 ──
  "Twoja domowa sieć z dowolnego miejsca — bez VPN-u":
      "Dein Heimnetz von überall — ohne VPN",
  "Home Assistant bez abonamentu": "Home Assistant ohne Abo",
  "LoRa działa, gdy internet nie działa":
      "LoRa funktioniert, wenn das Internet ausfällt",
  "Zaszyfrowane miejsce na pliki u innych":
      "Verschlüsselter Platz für Dateien bei anderen",
  "Zatrzymaj": "Stoppen",
  "Księgowanie odbioru…": "Abholung wird gebucht…",
  "Wysłano: %s": "Gesendet: %s",
  "bezpośrednio": "direkt",
  "przez serwer": "über den Server",
  "Dostępna nowsza wersja: sensmos-store.py":
      "Neuere Version verfügbar: sensmos-store.py",
  "Nie udało się sprawdzić stanu pakietu": "Paketstatus nicht abrufbar",
  "To nie znaczy, że coś zginęło — Twoje pliki leżą u sprzedawców niezależnie od tego połączenia. Spróbuj za chwilę.":
      "Das heißt nicht, dass etwas verloren ist — deine Dateien liegen unabhängig von dieser Verbindung auf den Platten der Anbieter. Versuch es gleich noch einmal.",
  "Sprawdzam…": "Prüfe…",
  "Sparowane urządzenia": "Gekoppelte Geräte",
  "komputery i Home Assistant z dostępem do konta": "Computer und Home Assistant mit Zugang zu diesem Konto",
  "Sparuj urządzenie": "Gerät koppeln",
  "to urządzenie": "dieses Gerät",
  "Dostęp znika natychmiast. Jeśli to token tego telefonu, powiadomienia i tunele odłączą się do czasu ponownego zalogowania.":
      "Der Zugang endet sofort. Ist das der Token dieses Telefons, fallen Benachrichtigungen und Tunnel aus, bis es sich neu anmeldet.",
  "Urządzenie sparowane z kontem wchodzi tokenem, nie portfelem. Portfel zostaje w telefonie i nigdy go nie opuszcza.":
      "Ein gekoppeltes Gerät kommt mit einem Token hinein, nicht mit der Wallet. Die Wallet bleibt auf diesem Telefon und verlässt es nie.",
  "Nic jeszcze nie sparowano.": "Noch nichts gekoppelt.",
  "bez nazwy": "ohne Namen",
  "ostatnio: %s": "zuletzt: %s",
  "Urządzenie, które parujesz (np. komputer albo Home Assistant), pokaże kod. Wpisz go tutaj — albo zeskanuj, jeśli widać kod QR.":
      "Das Gerät, das du koppelst (z. B. ein Computer oder Home Assistant), zeigt einen Code an. Tippe ihn hier ein — oder scanne ihn, falls ein QR-Code angezeigt wird.",
  "Kod z urządzenia": "Code vom Gerät",
  "Zeskanuj": "Scannen",
  "Zeskanuj kod": "Code scannen",
  "Sprawdź kod": "Code prüfen",
  "„%s\" prosi o dostęp do konta": "„%s“ bittet um Zugang zum Konto",
  "Zaznacz, co temu urządzeniu wolno. Możesz to odebrać w każdej chwili.":
      "Kreuze an, was dieses Gerät darf. Du kannst es jederzeit zurücknehmen.",
  "Może czytać pliki": "Darf Dateien lesen",
  "Bez tego urządzenie wyśle pliki i zobaczy listę, ale nie otworzy żadnego. Odłączenie odbiera dostęp do konta, ale NIE odbiera klucza, który już dostało.":
      "Ohne das kann das Gerät hochladen und die Liste sehen, aber nichts öffnen. Das Entkoppeln nimmt den Kontozugang zurück, NICHT jedoch den bereits übergebenen Schlüssel.",
  "Szukam…": "Suche…",
  "Paruję…": "Koppeln…",
  "Włącz lokalizację w telefonie": "Schalte die Standortbestimmung am Telefon ein",
  "Pozycja jest za daleko od miejsca, z którego łączy się brama (%s). Brama jest sparowana, ale bez pozycji nie zarabia.": "Die Position ist zu weit von dem Ort entfernt, von dem aus sich das Gateway verbindet (%s). Das Gateway ist gekoppelt, verdient aber ohne Position nichts.",
  "Pozycja jest w innym kraju niż łącze bramy. Brama jest sparowana, ale bez pozycji nie zarabia.": "Die Position liegt in einem anderen Land als der Anschluss des Gateways. Das Gateway ist gekoppelt, verdient aber ohne Position nichts.",
  "Nie udało się ustawić pozycji (%s).": "Position konnte nicht gesetzt werden (%s).",
  "EUI bramy to 16 znaków szesnastkowych": "Die Gateway-EUI besteht aus 16 Hexadezimalzeichen",
  "Podaj pozycję bramy": "Gib die Position des Gateways an",
  "Brama nie wysyła teraz danych do sensmos.com:1700. Dopisz ten adres w forwarderze bramy i spróbuj za minutę.": "Das Gateway sendet gerade nicht an sensmos.com:1700. Trage diese Adresse im Forwarder des Gateways ein und versuche es in einer Minute erneut.",
  "Ta brama jest już sparowana z innym portfelem.": "Dieses Gateway ist bereits mit einer anderen Wallet gekoppelt.",
  "Brama sparowana": "Gateway gekoppelt",
  "Brama LoRaWAN": "LoRaWAN-Gateway",
  "Dodaj bramę LoRaWAN": "LoRaWAN-Gateway hinzufügen",
  "W panelu bramy (np. Crankk → Forwards To) dopisz serwer sensmos.com:1700. Gdy brama zacznie do nas wysyłać, wpisz tu jej EUI. Brama słyszy nody Sensmos, nadaje beacon i zarabia jak node.": "Trage im Panel des Gateways (z. B. Crankk → Forwards To) den Server sensmos.com:1700 ein. Sobald das Gateway an uns sendet, gib hier seine EUI ein. Das Gateway hört Sensmos-Nodes, sendet einen Beacon und verdient wie ein Node.",
  "EUI bramy": "Gateway-EUI",
  "Nazwa (opcjonalnie)": "Name (optional)",
  "np. brama na dachu": "z. B. Gateway auf dem Dach",
  "Szerokość": "Breitengrad",
  "Długość": "Längengrad",
  "Jestem przy bramie — użyj pozycji telefonu": "Ich bin beim Gateway — Position des Telefons verwenden",
  "Pozycja musi zgadzać się z krajem i okolicą, z której łączy się brama.": "Die Position muss zu Land und Gegend passen, aus der sich das Gateway verbindet.",
  "Sparuj z portfelem": "Mit Wallet koppeln",
  "Bez pozycji — brama nie zarabia. Ustaw pozycję.": "Keine Position — das Gateway verdient nichts. Lege die Position fest.",
  "Nazwa i pozycja": "Name und Position",
  "Odepnij bramę": "Gateway entkoppeln",
  "Dodaj bramę LoRaWAN (np. Crankk)": "LoRaWAN-Gateway hinzufügen (z. B. Crankk)",
  "Nowa pozycja odrzucona — zostaje poprzednia, brama dalej zarabia.": "Neue Position abgelehnt — die bisherige bleibt, das Gateway verdient weiter.",
  "Wpisana pozycja jest za daleko od miejsca, z którego łączy się brama (%s). Przyjęliśmy przybliżoną pozycję z łącza.": "Die eingegebene Position ist zu weit von dem Ort entfernt, von dem aus sich das Gateway verbindet (%s). Wir haben eine ungefähre Position aus seinem Anschluss übernommen.",
  "Wpisana pozycja jest w innym kraju niż łącze bramy. Przyjęliśmy przybliżoną pozycję z łącza.": "Die eingegebene Position liegt in einem anderen Land als der Anschluss des Gateways. Wir haben eine ungefähre Position aus seinem Anschluss übernommen.",
  "Podaj obie współrzędne albo zostaw obie puste": "Gib beide Koordinaten an oder lass beide leer",
  "Pozycja jest opcjonalna — bez niej bierzemy przybliżoną z łącza bramy. Wpisana musi zgadzać się z krajem i okolicą łącza.": "Die Position ist optional — ohne sie nehmen wir eine ungefähre aus dem Anschluss des Gateways. Eine eingegebene Position muss zu Land und Gegend dieses Anschlusses passen.",
  "Pozycja: wpisana": "Position: eingegeben",
  "Pozycja: przybliżona z łącza bramy": "Position: ungefähr, aus dem Anschluss des Gateways",
  "Bez pozycji — brama nie zarabia.": "Keine Position — das Gateway verdient nichts.",
  "Słyszy nodów: %s · słyszą ją: %s (24 h)": "Hört Nodes: %s · gehört von: %s (24 h)",
  "Ramki Sensmos (24 h): %s": "Sensmos-Frames (24 h): %s",
  "Beacon: jeszcze nie nadany": "Beacon: noch nicht gesendet",
  "Beacon: przed chwilą": "Beacon: gerade eben",
  "Beacon: %s temu": "Beacon: vor %s",
  "brama odrzuciła (%s)": "vom Gateway abgelehnt (%s)",
  "Zarobek: %s GALU": "Verdient: %s GALU",
  "Odpiąć bramę?": "Gateway entkoppeln?",
  "Brama %s zniknie z Twojego portfela i przestanie zarabiać. Możesz ją później sparować ponownie po EUI. Zarobione GALU zostają w portfelu.": "Gateway %s wird aus deinem Wallet entfernt und verdient nichts mehr. Du kannst es später über seine EUI erneut koppeln. Bereits verdiente GALU bleiben in deinem Wallet.",
  "Brama odpięta": "Gateway entkoppelt",
  "Zapisano": "Gespeichert",
  "Zegar telefonu odbiega o ponad godzinę — włącz automatyczny czas i spróbuj ponownie.": "Die Uhr deines Telefons weicht um mehr als eine Stunde ab — schalte die automatische Uhrzeit ein und versuche es erneut.",
  "Nie udało się sparować bramy (%s).": "Gateway konnte nicht gekoppelt werden (%s).",
};

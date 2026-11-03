/// Czy urządzenie umie tunel do LAN (terminal, panel HA, panele LAN).
///
/// Node ESP32: od FW > 0.70 (RemoteTerminal: on-demand tunel + PIN gate). Wersja bywa z sufiksem
/// gałęzi ('0.80-lora6', '0.80-fsk3') — bierzemy sam prefiks major.minor, inaczej node z LoRy
/// wyglądał na starszy niż 0.70 i miał zablokowane integracje.
///
/// Sensmos Hub (nod w Dockerze) zgłasza 'hub-0.1.1' — własna numeracja, tunel i parowanie ma od
/// pierwszego wydania. Porównywanie go z progiem FW noda blokowało dodanie panelu HA przez Hub.
bool tunnelCapable(dynamic fw) {
  final s = fw?.toString().trim().toLowerCase() ?? '';
  if (s.startsWith('hub-')) return true;
  final m = RegExp(r'^\d+\.\d+').firstMatch(s);
  final v = m == null ? null : double.tryParse(m.group(0)!);
  return v != null && v > 0.70;
}

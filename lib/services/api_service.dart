import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../models/map_data.dart';

/// ApiService — publiczne dane z BE (mapa, ranking, statystyki).
/// Read-only, nie wymaga noda ani auth.
class ApiService {
  final _client = http.Client();

  Future<Map<String, dynamic>> _get(String path) async {
    final res = await _client.get(Uri.parse('${Config.beUrl}$path'),
        headers: const {'X-App-Key': Config.appKey});
    if (res.statusCode != 200) {
      throw Exception('API $path → ${res.statusCode}');
    }
    return jsonDecode(res.body);
  }

  /// Nody na mapie
  Future<List<MapNode>> mapNodes() async {
    final j = await _get('/v1/map/nodes');
    return (j['nodes'] as List? ?? [])
        .map((e) => MapNode.fromJson(e))
        .toList();
  }

  /// Szczegóły noda (lazy load po kliknięciu)
  Future<Map<String, dynamic>> nodeData(String deviceId) =>
      _get('/v1/map/nodes/$deviceId/data');

  /// Dostępne warstwy heatmap
  Future<Map<String, dynamic>> layers() => _get('/v1/map/layers');

  /// Punkty warstwy (IDW)
  Future<Map<String, dynamic>> layer(String entityId) =>
      _get('/v1/map/layer/$entityId');

  /// Ranking miast

  /// Ranking nodów

  /// Ranking regionów

  /// Globalne statystyki
}

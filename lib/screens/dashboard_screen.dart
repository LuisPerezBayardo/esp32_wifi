import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// =======================================================
/// CONFIG (AJUSTA ESTO A TU PROYECTO)
/// =======================================================
class AppConfig {
  // MQTT
  static const String mqttHost = '192.168.1.10';
  static const int mqttPort = 1883;

  // Backend HTTP (para alertas + comandos de actuadores)
  static const String backendBaseUrl = 'http://192.168.1.10:3000';
  static const String apiVersion = 'v1';

  // PlantId (debe coincidir con tus topics industrial/{plantId}/...)
  static const String plantId = 'plant_01';

  // SharedPreferences keys (ajústalos a los que ya usas en login)
  static const String spAccessTokenKey = 'access_token';
  static const String spCanControlActuatorsKey = 'canControlActuators';
}

/// =======================================================
/// MODELOS (UI)
/// =======================================================
class SensorSnapshot {
  final String sensorType; // temperature/humidity/...
  double value;
  String unit;
  DateTime timestamp;

  SensorSnapshot({
    required this.sensorType,
    required this.value,
    required this.unit,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'sensorType': sensorType,
        'value': value,
        'unit': unit,
        'timestamp': timestamp.toIso8601String(),
      };
}

class ActuatorSnapshot {
  final String actuatorId;
  dynamic state; // bool/num
  String? type; // relay/pwm/servo...
  String? name;

  ActuatorSnapshot({
    required this.actuatorId,
    this.state,
    this.type,
    this.name,
  });

  Map<String, dynamic> toJson() => {
        'actuatorId': actuatorId,
        'state': state,
        'type': type,
        'name': name,
      };
}

class DeviceSnapshot {
  final String deviceId;

  String name;
  String plantId;
  String chamberId;

  String status; // online/offline
  DateTime? lastHeartbeat;

  int? rssi;
  String? firmwareVersion;
  int? freeHeap;
  int? uptimeSec;

  final Map<String, SensorSnapshot> sensors = {};
  final Map<String, ActuatorSnapshot> actuators = {};

  DeviceSnapshot({
    required this.deviceId,
    required this.plantId,
    required this.chamberId,
    this.name = 'ESP32 Device',
    this.status = 'offline',
  });

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'name': name,
        'plantId': plantId,
        'chamberId': chamberId,
        'status': status,
        'lastHeartbeat': lastHeartbeat?.toIso8601String(),
        'rssi': rssi,
        'firmwareVersion': firmwareVersion,
        'freeHeap': freeHeap,
        'uptimeSec': uptimeSec,
        'sensors': sensors.map((k, v) => MapEntry(k, v.toJson())),
        'actuators': actuators.map((k, v) => MapEntry(k, v.toJson())),
      };
}

/// =======================================================
/// ALERTAS (DTO + API)
/// =======================================================
class AlertDto {
  final String id;
  final String plantId;
  final String chamberId;
  final String? deviceId;

  final String severity; // info | warning | critical
  final String status; // active | acknowledged | escalated | resolved

  final String title;
  final String message;

  final String? sensorType;
  final num? value;
  final String? unit;

  final DateTime? triggeredAt;

  AlertDto({
    required this.id,
    required this.plantId,
    required this.chamberId,
    required this.deviceId,
    required this.severity,
    required this.status,
    required this.title,
    required this.message,
    required this.sensorType,
    required this.value,
    required this.unit,
    required this.triggeredAt,
  });

  factory AlertDto.fromJson(Map<String, dynamic> j) {
    return AlertDto(
      id: (j['_id'] ?? j['id'] ?? '').toString(),
      plantId: (j['plantId'] ?? '').toString(),
      chamberId: (j['chamberId'] ?? '').toString(),
      deviceId: j['deviceId']?.toString(),
      severity: (j['severity'] ?? 'info').toString(),
      status: (j['status'] ?? 'active').toString(),
      title: (j['title'] ?? '').toString(),
      message: (j['message'] ?? '').toString(),
      sensorType: j['sensorType']?.toString(),
      value: j['value'] as num?,
      unit: j['unit']?.toString(),
      triggeredAt: j['triggeredAt'] != null ? DateTime.tryParse(j['triggeredAt'].toString()) : null,
    );
  }
}

class AlertsSummary {
  final Map<String, Map<String, int>> summary; // severity -> status -> count
  final int total;

  AlertsSummary({required this.summary, required this.total});

  factory AlertsSummary.fromJson(Map<String, dynamic> j) {
    final Map<String, dynamic> sum = (j['summary'] ?? {}) as Map<String, dynamic>;
    final parsed = <String, Map<String, int>>{};
    for (final sev in sum.keys) {
      final m = (sum[sev] ?? {}) as Map<String, dynamic>;
      parsed[sev] = {
        'active': (m['active'] ?? 0) as int,
        'acknowledged': (m['acknowledged'] ?? 0) as int,
        'escalated': (m['escalated'] ?? 0) as int,
      };
    }
    return AlertsSummary(
      summary: parsed,
      total: (j['total'] ?? 0) as int,
    );
  }

  int get criticalActiveOrEscalated {
    final m = summary['critical'] ?? const {'active': 0, 'escalated': 0};
    return (m['active'] ?? 0) + (m['escalated'] ?? 0);
  }
}

class AlertsApi {
  AlertsApi({required this.baseUrl, required this.apiVersion});

  final String baseUrl;
  final String apiVersion;

  Uri _u(String path, [Map<String, String>? q]) {
    final uri = Uri.parse('$baseUrl/api/$apiVersion$path');
    return q == null ? uri : uri.replace(queryParameters: q);
  }

  Future<AlertsSummary> getSummary({
    required String token,
    required String plantId,
  }) async {
    // GET /alerts/summary?plantId=...
    final resp = await http.get(
      _u('/alerts/summary', {'plantId': plantId}),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (resp.statusCode != 200) {
      throw Exception('alerts summary failed: ${resp.statusCode} ${resp.body}');
    }

    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final data = (body['data'] ?? {}) as Map<String, dynamic>;
    return AlertsSummary.fromJson(data);
  }

  Future<List<AlertDto>> getActiveAlerts({
    required String token,
    required String plantId,
    required String chamberId,
  }) async {
    // GET /alerts/active?plantId=...&chamberId=...
    final resp = await http.get(
      _u('/alerts/active', {'plantId': plantId, 'chamberId': chamberId}),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (resp.statusCode != 200) {
      throw Exception('alerts active failed: ${resp.statusCode} ${resp.body}');
    }

    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final data = (body['data'] ?? {}) as Map<String, dynamic>;
    final list = (data['alerts'] ?? []) as List<dynamic>;
    return list.map((e) => AlertDto.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> acknowledge({
    required String token,
    required String alertId,
  }) async {
    final resp = await http.post(
      _u('/alerts/$alertId/acknowledge'),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (resp.statusCode != 200) {
      throw Exception('ack failed: ${resp.statusCode} ${resp.body}');
    }
  }

  Future<void> resolve({
    required String token,
    required String alertId,
    String? note,
  }) async {
    final resp = await http.post(
      _u('/alerts/$alertId/resolve'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode({'note': note}),
    );

    if (resp.statusCode != 200) {
      throw Exception('resolve failed: ${resp.statusCode} ${resp.body}');
    }
  }
}

/// =======================================================
/// ACTUATORS API (QUICK ACTIONS DESDE DASHBOARD)
/// =======================================================
class ActuatorsApi {
  ActuatorsApi({required this.baseUrl, required this.apiVersion});

  final String baseUrl;
  final String apiVersion;

  Uri _u(String path) => Uri.parse('$baseUrl/api/$apiVersion$path');

  Future<void> toggle({
    required String token,
    required String plantId,
    required String chamberId,
    required String actuatorId,
  }) async {
    final resp = await http.post(
      _u('/actuators/plants/$plantId/chambers/$chamberId/actuators/$actuatorId/toggle'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (resp.statusCode != 200) throw Exception('toggle failed: ${resp.statusCode} ${resp.body}');
  }

  Future<void> turnOn({
    required String token,
    required String plantId,
    required String chamberId,
    required String actuatorId,
  }) async {
    final resp = await http.post(
      _u('/actuators/plants/$plantId/chambers/$chamberId/actuators/$actuatorId/on'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (resp.statusCode != 200) throw Exception('on failed: ${resp.statusCode} ${resp.body}');
  }

  Future<void> turnOff({
    required String token,
    required String plantId,
    required String chamberId,
    required String actuatorId,
  }) async {
    final resp = await http.post(
      _u('/actuators/plants/$plantId/chambers/$chamberId/actuators/$actuatorId/off'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (resp.statusCode != 200) throw Exception('off failed: ${resp.statusCode} ${resp.body}');
  }
}

/// =======================================================
/// DASHBOARD SCREEN (MQTT + ALERTAS INDUSTRIALES)
/// =======================================================
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final AlertsApi _alertsApi = AlertsApi(
    baseUrl: AppConfig.backendBaseUrl,
    apiVersion: AppConfig.apiVersion,
  );

  final ActuatorsApi _actuatorsApi = ActuatorsApi(
    baseUrl: AppConfig.backendBaseUrl,
    apiVersion: AppConfig.apiVersion,
  );

  MqttServerClient? _mqtt;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _mqttSub;

  bool _mqttConnecting = true;
  String? _mqttError;

  String? _token;
  bool _canControlActuators = false;

  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  // deviceId -> snapshot
  final Map<String, DeviceSnapshot> _devices = {};

  // chamberId -> active alerts list
  final Map<String, List<AlertDto>> _activeAlertsByChamber = {};
  AlertsSummary? _summary;

  Timer? _offlineTimer;
  Timer? _alertsTimer;
  bool _loadingAlerts = false;

  @override
  void initState() {
    super.initState();
    _initSessionAndStart();
  }

  @override
  void dispose() {
    _offlineTimer?.cancel();
    _alertsTimer?.cancel();
    _mqttSub?.cancel();
    _mqtt?.disconnect();
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _matchesSearch(DeviceSnapshot d) {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return true;

    final name = d.name.toLowerCase();
    final id = d.deviceId.toLowerCase();
    final rssiStr = (d.rssi?.toString() ?? '').toLowerCase();

    // Soporta buscar "55" y que encuentre "-55"
    final rssiAbsStr = (d.rssi != null) ? d.rssi!.abs().toString() : '';

    return name.contains(q) || id.contains(q) || rssiStr.contains(q) || rssiAbsStr.contains(q);
  }



  Future<void> _initSessionAndStart() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(AppConfig.spAccessTokenKey);
    _canControlActuators = prefs.getBool(AppConfig.spCanControlActuatorsKey) ?? false;

    await _connectMqtt();
    _startTimers();
  }

  void _startTimers() {
    // Marca offline si heartbeat > 2 min
    _offlineTimer?.cancel();
    _offlineTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final now = DateTime.now();
      bool changed = false;
      for (final d in _devices.values) {
        final hb = d.lastHeartbeat;
        if (hb == null) continue;
        final online = now.difference(hb) < const Duration(minutes: 2);
        final s = online ? 'online' : 'offline';
        if (d.status != s) {
          d.status = s;
          changed = true;
        }
      }
      if (changed && mounted) setState(() {});
    });

    // Polling industrial de alertas (resumen + activas)
    _alertsTimer?.cancel();
    _alertsTimer = Timer.periodic(const Duration(seconds: 10), (_) => _refreshAlertsAll());
    _refreshAlertsAll();
  }

  Future<void> _connectMqtt() async {
    setState(() {
      _mqttConnecting = true;
      _mqttError = null;
    });

    final clientId = 'flutter_dashboard_${DateTime.now().millisecondsSinceEpoch}';
    final c = MqttServerClient.withPort(AppConfig.mqttHost, clientId, AppConfig.mqttPort);
    c.keepAlivePeriod = 20;
    c.logging(on: false);

    c.onDisconnected = () {
      if (!mounted) return;
      setState(() => _mqttError = 'MQTT desconectado');
    };

    try {
      _mqtt = c;

      c.connectionMessage = MqttConnectMessage()
          .withClientIdentifier(clientId)
          .startClean()
          .withWillQos(MqttQos.atLeastOnce);

      await c.connect();
      if (c.connectionStatus?.state != MqttConnectionState.connected) {
        throw Exception('MQTT not connected: ${c.connectionStatus}');
      }

      _subscribeMqtt(c);

      _mqttSub = c.updates?.listen(_handleMqttMessages);

      setState(() => _mqttConnecting = false);
    } catch (e) {
      setState(() {
        _mqttConnecting = false;
        _mqttError = 'No se pudo conectar a MQTT: $e';
      });
      c.disconnect();
    }
  }

  void _subscribeMqtt(MqttServerClient c) {
    final base = 'industrial/${AppConfig.plantId}';

    // 🔥 IMPORTANTE: heartbeat va bajo chambers/.../devices/... según tu backend
    // industrial/{plantId}/chambers/{chamberId}/devices/{deviceId}/heartbeat
    // (así lo parsea client.js del backend) :contentReference[oaicite:6]{index=6}
    c.subscribe('$base/chambers/+/devices/+/heartbeat', MqttQos.atLeastOnce);

    // Sensores: industrial/{plantId}/chambers/{chamberId}/sensors/{sensorType}
    c.subscribe('$base/chambers/+/sensors/+', MqttQos.atLeastOnce);

    // Status de actuadores: industrial/{plantId}/chambers/{chamberId}/actuators/{actuatorId}/status
    c.subscribe('$base/chambers/+/actuators/+/status', MqttQos.atLeastOnce);
  }

  void _handleMqttMessages(List<MqttReceivedMessage<MqttMessage>> messages) {
    bool changed = false;

    for (final m in messages) {
      final topic = m.topic;
      final payloadMsg = m.payload as MqttPublishMessage;
      final payloadStr = MqttPublishPayload.bytesToStringAsString(payloadMsg.payload.message);

      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(payloadStr) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }

      final parts = topic.split('/');
      if (parts.length < 6) continue;
      if (parts[0] != 'industrial') continue;

      final plantId = parts[1];

      // industrial/{plantId}/chambers/{chamberId}/...
      if (parts[2] != 'chambers') continue;

      final chamberId = parts[3];

      // sensors
      if (parts.length >= 6 && parts[4] == 'sensors') {
        final sensorType = parts[5];
        changed |= _applySensor(plantId, chamberId, sensorType, payload);
        continue;
      }

      // actuators status
      if (parts.length >= 7 && parts[4] == 'actuators') {
        final actuatorId = parts[5];
        final action = parts[6];
        if (action == 'status') {
          changed |= _applyActuatorStatus(plantId, chamberId, actuatorId, payload);
        }
        continue;
      }

      // devices heartbeat
      if (parts.length >= 7 && parts[4] == 'devices') {
        final deviceId = parts[5];
        final action = parts[6];
        if (action == 'heartbeat') {
          changed |= _applyHeartbeat(plantId, chamberId, deviceId, payload);
        }
        continue;
      }
    }

    if (changed && mounted) setState(() {});
  }

  bool _applyHeartbeat(String plantId, String chamberId, String deviceId, Map<String, dynamic> p) {
    final d = _devices.putIfAbsent(
      deviceId,
      () => DeviceSnapshot(deviceId: deviceId, plantId: plantId, chamberId: chamberId, name: 'Device $deviceId'),
    );

    d.plantId = plantId;
    d.chamberId = chamberId;

    d.lastHeartbeat = DateTime.now();
    d.status = 'online';

    d.rssi = _asInt(p['rssi']);
    d.firmwareVersion = p['firmwareVersion']?.toString();
    d.freeHeap = _asInt(p['freeHeap']);
    d.uptimeSec = _asInt(p['uptime']);

    if (p['name'] != null) d.name = p['name'].toString();

    return true;
  }

  bool _applySensor(String plantId, String chamberId, String sensorType, Map<String, dynamic> p) {
    final deviceId = p['deviceId']?.toString() ?? 'unknown_device';

    final d = _devices.putIfAbsent(
      deviceId,
      () => DeviceSnapshot(deviceId: deviceId, plantId: plantId, chamberId: chamberId, name: 'Device $deviceId'),
    );

    d.plantId = plantId;
    d.chamberId = chamberId;

    final value = _asDouble(p['value']) ?? 0.0;
    final unit = p['unit']?.toString() ?? _defaultUnit(sensorType);

    d.sensors[sensorType] = SensorSnapshot(
      sensorType: sensorType,
      value: value,
      unit: unit,
      timestamp: DateTime.now(),
    );

    return true;
  }

  bool _applyActuatorStatus(String plantId, String chamberId, String actuatorId, Map<String, dynamic> p) {
    final deviceId = p['deviceId']?.toString() ?? 'unknown_device';

    final d = _devices.putIfAbsent(
      deviceId,
      () => DeviceSnapshot(deviceId: deviceId, plantId: plantId, chamberId: chamberId, name: 'Device $deviceId'),
    );

    d.plantId = plantId;
    d.chamberId = chamberId;

    final a = d.actuators.putIfAbsent(actuatorId, () => ActuatorSnapshot(actuatorId: actuatorId));
    a.state = p['state'] ?? p['value'];
    if (p['type'] != null) a.type = p['type'].toString();
    if (p['name'] != null) a.name = p['name'].toString();

    return true;
  }

  /// =======================================================
  /// ALERTAS: polling industrial
  /// =======================================================
  Future<void> _refreshAlertsAll() async {
    if (_token == null) return;
    if (_loadingAlerts) return;

    setState(() => _loadingAlerts = true);

    try {
      // 1) Summary global (campana AppBar)
      final summary = await _alertsApi.getSummary(
        token: _token!,
        plantId: AppConfig.plantId,
      );

      // 2) Active alerts por chamber detectado
      final chambers = _devices.values.map((d) => d.chamberId).toSet().toList();

      final Map<String, List<AlertDto>> next = {};
      for (final chamberId in chambers) {
        final alerts = await _alertsApi.getActiveAlerts(
          token: _token!,
          plantId: AppConfig.plantId,
          chamberId: chamberId,
        );
        next[chamberId] = alerts;
      }

      if (!mounted) return;
      setState(() {
        _summary = summary;
        _activeAlertsByChamber
          ..clear()
          ..addAll(next);
      });
    } catch (_) {
      // No matamos el dashboard si falla alertas
    } finally {
      if (mounted) setState(() => _loadingAlerts = false);
    }
  }

  List<AlertDto> _alertsForDevice(DeviceSnapshot d) {
    final chamberAlerts = _activeAlertsByChamber[d.chamberId] ?? const [];

    // Si hay deviceId en las alertas, filtramos por deviceId. Si no, mostramos por chamber.
    final anyDeviceId = chamberAlerts.any((a) => (a.deviceId ?? '').isNotEmpty);
    if (!anyDeviceId) return chamberAlerts;

    return chamberAlerts.where((a) => a.deviceId == d.deviceId).toList();
  }

  int _severityRank(String s) {
    switch (s) {
      case 'critical':
        return 3;
      case 'warning':
        return 2;
      default:
        return 1;
    }
  }

  (String worstSeverity, int count) _alertState(DeviceSnapshot d) {
    final list = _alertsForDevice(d);
    if (list.isEmpty) return ('info', 0);
    list.sort((a, b) => _severityRank(b.severity).compareTo(_severityRank(a.severity)));
    return (list.first.severity, list.length);
  }

  Color _sevColor(BuildContext context, String severity) {
    final cs = Theme.of(context).colorScheme;
    if (severity == 'critical') return cs.error;
    if (severity == 'warning') return cs.tertiary;
    return cs.outline;
  }

  Future<void> _ackAlert(AlertDto a) async {
    if (_token == null) return;
    await _alertsApi.acknowledge(token: _token!, alertId: a.id);
    await _refreshAlertsAll();
  }

  Future<void> _resolveAlert(AlertDto a) async {
    if (_token == null) return;
    await _alertsApi.resolve(token: _token!, alertId: a.id, note: 'Resolved from Dashboard');
    await _refreshAlertsAll();
  }

  void _openAlertsCenter() {
    final all = <AlertDto>[];
    for (final v in _activeAlertsByChamber.values) {
      all.addAll(v);
    }

    all.sort((a, b) {
      final sr = _severityRank(b.severity).compareTo(_severityRank(a.severity));
      if (sr != 0) return sr;
      final ta = a.triggeredAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final tb = b.triggeredAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return tb.compareTo(ta);
    });

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) {
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Centro de alertas',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (_loadingAlerts) const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  IconButton(
                    tooltip: 'Refrescar',
                    onPressed: _refreshAlertsAll,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Summary compacto
              if (_summary != null)
                _SummaryStrip(summary: _summary!, sevColor: (s) => _sevColor(context, s)),

              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 8),

              Expanded(
                child: all.isEmpty
                    ? const Center(child: Text('Sin alertas activas.'))
                    : ListView.separated(
                        itemCount: all.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final a = all[i];
                          final c = _sevColor(context, a.severity);

                          return ListTile(
                            leading: Icon(Icons.notifications_active, color: c),
                            title: Text(a.title.isEmpty ? 'Alerta' : a.title),
                            subtitle: Text(
                              '${a.message}\nPlant: ${a.plantId}  Chamber: ${a.chamberId}  Device: ${a.deviceId ?? "-"}  Status: ${a.status}',
                            ),
                            isThreeLine: true,
                            trailing: Wrap(
                              spacing: 8,
                              children: [
                                OutlinedButton(
                                  onPressed: a.status == 'resolved' ? null : () async => _ackAlert(a),
                                  child: const Text('ACK'),
                                ),
                                ElevatedButton(
                                  onPressed: a.status == 'resolved' ? null : () async => _resolveAlert(a),
                                  child: const Text('RESOLVE'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// =======================================================
  /// ACTUATOR QUICK ACTIONS
  /// =======================================================
  Future<void> _doActuatorAction({
    required Future<void> Function() action,
    required String okMsg,
  }) async {
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(okMsg)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  /// =======================================================
  /// NAV: device_detail_screen
  /// =======================================================
  void _openDeviceDetail(DeviceSnapshot d) {
    Navigator.pushNamed(
      context,
      '/device_detail',
      arguments: {
        'plantId': d.plantId,
        'chamberId': d.chamberId,
        'deviceId': d.deviceId,
        'device': d.toJson(),
      },
    );
  }

  /// =======================================================
  /// HELPERS
  /// =======================================================
  int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  double? _asDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  String _defaultUnit(String sensorType) {
    switch (sensorType) {
      case 'temperature':
        return '°C';
      case 'humidity':
        return '%';
      case 'pressure':
        return 'hPa';
      case 'co2':
        return 'ppm';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _devices.values
      .where(_matchesSearch)
      .toList()
    ..sort((a, b) => a.deviceId.compareTo(b.deviceId));

    final criticalBadge = _summary?.criticalActiveOrEscalated ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          // Campana global industrial
          InkWell(
            onTap: _openAlertsCenter,
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Center(child: Icon(Icons.notifications)),
                  if (criticalBadge > 0)
                    Positioned(
                      right: -6,
                      top: 10,
                      child: _Badge(
                        value: '$criticalBadge',
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),

          IconButton(
            tooltip: 'Perfil',
            icon: const Icon(Icons.person),
            onPressed: () => Navigator.pushNamed(context, '/profile'),
          ),
          IconButton(
            tooltip: 'Preferencias',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.pushNamed(context, '/preferences'),
          ),
          IconButton(
            tooltip: 'Administración',
            icon: const Icon(Icons.admin_panel_settings),
            onPressed: () => Navigator.pushNamed(context, '/admin'),
          ),
        ],
      ),
      body: _mqttConnecting
          ? const Center(child: CircularProgressIndicator())
          : _mqttError != null
              ? _ErrorPanel(message: _mqttError!, onRetry: _connectMqtt)
              : _devices.isEmpty
                  ? const _EmptyState()
                  : RefreshIndicator(
                      onRefresh: () async {
                        await _connectMqtt();
                        await _refreshAlertsAll();
                      },
                      child: ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(12),
                        itemCount: list.length + 1,
                        itemBuilder: (_, i) {
                          if (i == 0) {
                            // 🔎 Search bar (primer elemento del listview)
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: TextField(
                                controller: _searchCtrl,
                                textInputAction: TextInputAction.search,
                                decoration: InputDecoration(
                                  prefixIcon: const Icon(Icons.search),
                                  suffixIcon: _searchQuery.isEmpty
                                      ? null
                                      : IconButton(
                                          tooltip: 'Limpiar',
                                          icon: const Icon(Icons.clear),
                                          onPressed: () {
                                            _searchCtrl.clear();
                                            setState(() => _searchQuery = '');
                                          },
                                        ),
                                  hintText: 'Buscar por nombre, ID o RSSI...',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                onChanged: (v) => setState(() => _searchQuery = v),
                              ),
                            );
                          }

                          final d = list[i-1];
                          final isOnline = d.status == 'online';

                          final (worstSev, alertsCount) = _alertState(d);
                          final hasAlerts = alertsCount > 0;

                          // Sensor principal
                          SensorSnapshot? mainSensor;
                          if (d.sensors.isNotEmpty) {
                            mainSensor = d.sensors['temperature'] ?? d.sensors.values.first;
                          }

                          // Actuador principal
                          ActuatorSnapshot? mainAct;
                          if (d.actuators.isNotEmpty) {
                            mainAct = d.actuators.values.first;
                          }

                          final alertColor = _sevColor(context, worstSev);

                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Header
                                  Row(
                                    children: [
                                      Icon(isOnline ? Icons.wifi : Icons.wifi_off, size: 20),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          '${d.name} • ${d.deviceId}',
                                          style: Theme.of(context).textTheme.titleMedium,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (d.rssi != null) ...[
                                        const SizedBox(width: 8),
                                        Text('RSSI ${d.rssi} dBm', style: Theme.of(context).textTheme.bodySmall),
                                      ],
                                      const SizedBox(width: 8),

                                      // Indicador de alertas por dispositivo (badge)
                                      InkWell(
                                        onTap: () {
                                          // abre el centro; ya están filtrables ahí
                                          _openAlertsCenter();
                                        },
                                        borderRadius: BorderRadius.circular(999),
                                        child: Padding(
                                          padding: const EdgeInsets.all(6),
                                          child: Stack(
                                            clipBehavior: Clip.none,
                                            children: [
                                              Icon(
                                                hasAlerts ? Icons.notifications_active : Icons.notifications_off,
                                                color: hasAlerts ? alertColor : Theme.of(context).colorScheme.outline,
                                              ),
                                              if (hasAlerts)
                                                Positioned(
                                                  right: -6,
                                                  top: -6,
                                                  child: _Badge(value: '$alertsCount', color: alertColor),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Plant: ${d.plantId}   Chamber: ${d.chamberId}',
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                  const SizedBox(height: 10),

                                  // Sensor + Actuator
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: _InfoBox(
                                          title: 'Sensor',
                                          child: mainSensor == null
                                              ? const Text('Sin lecturas todavía')
                                              : Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        '${mainSensor.sensorType}: ${mainSensor.value.toStringAsFixed(2)} ${mainSensor.unit}',
                                                      ),
                                                    ),
                                                    IconButton(
                                                      tooltip: hasAlerts ? 'Estado: ALARMADO' : 'Estado: OK',
                                                      icon: Icon(hasAlerts ? Icons.notification_important : Icons.notifications_off),
                                                      onPressed: () {
                                                        final msg = hasAlerts ? 'Estado: ALARMADO' : 'Estado: OK';
                                                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                                                      },
                                                    )
                                                  ],
                                                ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _InfoBox(
                                          title: 'Actuador',
                                          child: mainAct == null
                                              ? const Text('Sin actuadores detectados')
                                              : Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      '${mainAct.name ?? mainAct.actuatorId} • state: ${mainAct.state}',
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                    const SizedBox(height: 8),

                                                    // Quick actions (industrial): ON / OFF / TOGGLE
                                                    if (_token != null && _canControlActuators)
                                                      Wrap(
                                                        spacing: 8,
                                                        runSpacing: 8,
                                                        children: [
                                                          OutlinedButton(
                                                            onPressed: () => _doActuatorAction(
                                                              action: () => _actuatorsApi.turnOn(
                                                                token: _token!,
                                                                plantId: d.plantId,
                                                                chamberId: d.chamberId,
                                                                actuatorId: mainAct!.actuatorId,
                                                              ),
                                                              okMsg: 'ON enviado',
                                                            ),
                                                            child: const Text('ON'),
                                                          ),
                                                          OutlinedButton(
                                                            onPressed: () => _doActuatorAction(
                                                              action: () => _actuatorsApi.turnOff(
                                                                token: _token!,
                                                                plantId: d.plantId,
                                                                chamberId: d.chamberId,
                                                                actuatorId: mainAct!.actuatorId,
                                                              ),
                                                              okMsg: 'OFF enviado',
                                                            ),
                                                            child: const Text('OFF'),
                                                          ),
                                                          ElevatedButton(
                                                            onPressed: () => _doActuatorAction(
                                                              action: () => _actuatorsApi.toggle(
                                                                token: _token!,
                                                                plantId: d.plantId,
                                                                chamberId: d.chamberId,
                                                                actuatorId: mainAct!.actuatorId,
                                                              ),
                                                              okMsg: 'TOGGLE enviado',
                                                            ),
                                                            child: const Text('TOGGLE'),
                                                          ),
                                                        ],
                                                      )
                                                    else
                                                      Text(
                                                        'Sin permiso para controlar actuadores',
                                                        style: Theme.of(context).textTheme.bodySmall,
                                                      ),
                                                  ],
                                                ),
                                        ),
                                      ),
                                    ],
                                  ),

                                  const SizedBox(height: 12),

                                  // Ver detalles
                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton(
                                          onPressed: () => _openDeviceDetail(d),
                                          child: const Text('Ver detalles'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}

/// =======================================================
/// UI helpers
/// =======================================================
class _Badge extends StatelessWidget {
  final String value;
  final Color color;

  const _Badge({required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        value,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onError,
            ),
      ),
    );
  }
}

class _SummaryStrip extends StatelessWidget {
  final AlertsSummary summary;
  final Color Function(String severity) sevColor;

  const _SummaryStrip({required this.summary, required this.sevColor});

  int _get(String sev, String status) => summary.summary[sev]?[status] ?? 0;

  @override
  Widget build(BuildContext context) {
    Widget chip(String sev) {
      final c = sevColor(sev);
      final active = _get(sev, 'active');
      final ack = _get(sev, 'acknowledged');
      final esc = _get(sev, 'escalated');

      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 10, color: c),
            const SizedBox(width: 8),
            Text(
              sev.toUpperCase(),
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(width: 10),
            Text('A:$active  ACK:$ack  ESC:$esc'),
          ],
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip('critical'),
        chip('warning'),
        chip('info'),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text('TOTAL: ${summary.total}'),
        ),
      ],
    );
  }
}

class _InfoBox extends StatelessWidget {
  final String title;
  final Widget child;

  const _InfoBox({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Aún no llegan mensajes MQTT.\n\n'
          'Verifica que tus ESP32 publiquen a:\n'
          'industrial/{plantId}/chambers/{chamberId}/devices/{deviceId}/heartbeat\n'
          'industrial/{plantId}/chambers/{chamberId}/sensors/{sensorType}\n'
          'industrial/{plantId}/chambers/{chamberId}/actuators/{actuatorId}/status',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _ErrorPanel({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => onRetry(),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}

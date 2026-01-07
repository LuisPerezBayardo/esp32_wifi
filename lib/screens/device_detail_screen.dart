import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/mqtt_service.dart';

class DeviceDetailScreen extends StatefulWidget {
  const DeviceDetailScreen({super.key});

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  // =============================
  // CONFIG BACKEND (AJUSTA)
  // =============================
  static const String _backendHost = '10.0.2.2';
  static const int _backendPort = 3000;
  static const String _apiVersion = 'v1';

  Uri _url(String path) =>
      Uri.parse('http://$_backendHost:$_backendPort/api/$_apiVersion$path');

  /// ⚠️ AJUSTA ESTO cuando confirmes tus routes/controllers
  /// Backend esperado:
  /// - GET    /devices/{deviceId}
  /// - PATCH  /devices/{deviceId}
  /// - DELETE /devices/{deviceId}
  String _devicePath(String deviceId) => '/devices/$deviceId';

  // =============================
  // MQTT (Realtime)
  // =============================
  final MqttService _mqtt = MqttService.instance;
  StreamSubscription<MqttMessageEvent>? _mqttSub;

  // Wildcards (recibimos todo y filtramos por deviceId/plant/chamber)
  static const String _mqttSensorsWildcard = 'industrial/+/chambers/+/sensors/#';
  static const String _mqttActuatorStatusWildcard =
      'industrial/+/chambers/+/actuators/+/status';

  // =============================
  // USER PERMISSIONS (/auth/profile)
  // =============================
  
  String _role = '';
  Map<String, dynamic> _permissions = const {};
  // ignore: unused_field
  bool _loadingUser = true;

  bool _canOpenDeviceDetails() {
    if (_role == 'admin' || _role == 'supervisor') return true;
    return _permissions['canManageDevices'] == true;
  }

  bool _canEditDevice() {
    if (_role == 'admin' || _role == 'supervisor') return true;
    return _permissions['canManageDevices'] == true;
  }

  bool _canDeleteDevice() {
    if (_role == 'admin') return true;
    return _permissions['canManageDevices'] == true;
  }

  bool _canControlActuators() {
    if (_role == 'admin' || _role == 'supervisor') return true;
    return _permissions['canControlActuators'] == true;
  }

  // =============================
  // STATE
  // =============================
  bool _loading = true;
  bool _saving = false;
  String? _error;

  late final String _deviceId; // OJO: esto es Device.deviceId del backend :contentReference[oaicite:5]{index=5}
  Map<String, dynamic> _device = {};

  // Edición (campos que sí existen en Device) :contentReference[oaicite:6]{index=6}
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _tagsCtrl = TextEditingController(); // coma-separado
  final _buildingCtrl = TextEditingController();
  final _floorCtrl = TextEditingController();
  final _zoneCtrl = TextEditingController();
  bool _otaEnabled = true;

  // Sensores/Actuadores (config del device)
  List<Map<String, dynamic>> _sensors = [];
  List<Map<String, dynamic>> _actuators = [];

  // Realtime cache:
  // sensorType -> {value, unit, timestamp, alertTriggered}
  final Map<String, Map<String, dynamic>> _latestReadings = {};

  // actuatorId -> status/state
  final Map<String, dynamic> _actuatorStates = {};

  @override
  void initState() {
    super.initState();

    // deviceId viene por arguments: {'deviceId': 'ESP32-001'}
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final args = ModalRoute.of(context)?.settings.arguments;
      final map = (args is Map) ? args : null;
      final id = map?['deviceId']?.toString();

      if (id == null || id.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'No se recibió deviceId para abrir detalles.';
        });
        return;
      }

      _deviceId = id;
      _boot();
    });
  }

  @override
  void dispose() {
    _mqttSub?.cancel();
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _tagsCtrl.dispose();
    _buildingCtrl.dispose();
    _floorCtrl.dispose();
    _zoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await _loadUserPermissions();
      if (!_canOpenDeviceDetails()) {
        setState(() {
          _loading = false;
          _error = 'No tienes permisos para ver detalles de dispositivos.';
        });
        return;
      }

      await _loadDevice();
      _startRealtime();

      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<String?> _getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('access_token');
  }

  Map<String, dynamic>? _decodeJson(String s) {
    try {
      final d = jsonDecode(s);
      return (d is Map<String, dynamic>) ? d : null;
    } catch (_) {
      return null;
    }
  }

  // =============================
  // USER (/auth/profile)
  // =============================
  Future<void> _loadUserPermissions() async {
    setState(() => _loadingUser = true);

    final token = await _getToken();
    if (token == null || token.isEmpty) {
      throw Exception('No hay sesión activa. Inicia sesión de nuevo.');
    }

    final res = await http.get(
      _url('/auth/profile'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    ).timeout(const Duration(seconds: 10));

    final json = _decodeJson(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(json?['error']?.toString() ??
          json?['message']?.toString() ??
          res.body);
    }

    final data = (json?['data'] is Map<String, dynamic>) ? json!['data'] : json;
    final user = (data is Map<String, dynamic> && data['user'] is Map<String, dynamic>)
        ? data['user'] as Map<String, dynamic>
        : (data is Map<String, dynamic> ? data : <String, dynamic>{});

    setState(() {
      _role = (user['role'] ?? '').toString();
      _permissions = (user['permissions'] is Map<String, dynamic>)
          ? user['permissions'] as Map<String, dynamic>
          : <String, dynamic>{};
      _loadingUser = false;
    });
  }

  // =============================
  // DEVICE HTTP (GET/PATCH/DELETE)
  // =============================
  Future<void> _loadDevice() async {
    final token = await _getToken();
    if (token == null || token.isEmpty) throw Exception('Sesión inválida.');

    final res = await http.get(
      _url(_devicePath(_deviceId)),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    ).timeout(const Duration(seconds: 10));

    final json = _decodeJson(res.body);

    if (res.statusCode == 404) {
      throw Exception(
        'No existe GET ${_devicePath(_deviceId)} en backend. Ajusta _devicePath() a tu ruta real.',
      );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(json?['error']?.toString() ??
          json?['message']?.toString() ??
          res.body);
    }

    // Soportar varias formas:
    // - { data: { device: {...} } }
    // - { device: {...} }
    // - { ...deviceFields }
    final data = (json?['data'] is Map<String, dynamic>) ? json!['data'] : json;
    final device = (data is Map<String, dynamic> && data['device'] is Map<String, dynamic>)
        ? data['device'] as Map<String, dynamic>
        : (data is Map<String, dynamic> ? data : <String, dynamic>{});

    // Alineación con Device schema :contentReference[oaicite:7]{index=7}
    setState(() {
      _device = device;

      _nameCtrl.text = (device['name'] ?? '').toString();
      _descCtrl.text = (device['description'] ?? '').toString();

      final tags = (device['tags'] is List) ? (device['tags'] as List).map((e) => e.toString()).toList() : <String>[];
      _tagsCtrl.text = tags.join(', ');

      final loc = (device['location'] is Map<String, dynamic>)
          ? device['location'] as Map<String, dynamic>
          : <String, dynamic>{};
      _buildingCtrl.text = (loc['building'] ?? '').toString();
      _floorCtrl.text = (loc['floor'] ?? '').toString();
      _zoneCtrl.text = (loc['zone'] ?? '').toString();

      _otaEnabled = device['otaEnabled'] != false;

      _sensors = (device['sensors'] is List)
          ? (device['sensors'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : <Map<String, dynamic>>[];

      _actuators = (device['actuators'] is List)
          ? (device['actuators'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : <Map<String, dynamic>>[];

      // Pre-cargar states de actuadores desde el inventario (actuator.state)
      for (final a in _actuators) {
        final actuatorId = (a['actuatorId'] ?? '').toString();
        if (actuatorId.isNotEmpty && !_actuatorStates.containsKey(actuatorId)) {
          _actuatorStates[actuatorId] = a['state'];
        }
      }
    });
  }

  Future<void> _saveDevice() async {
    if (!_canEditDevice()) {
      _snack('No tienes permisos para editar dispositivos.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final token = await _getToken();
      if (token == null || token.isEmpty) throw Exception('Sesión inválida.');

      final tags = _tagsCtrl.text
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      // Campos que existen en Device schema :contentReference[oaicite:8]{index=8}
      final body = <String, dynamic>{
        'name': _nameCtrl.text.trim(),
        'description': _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
        'tags': tags,
        'otaEnabled': _otaEnabled,
        'location': {
          'building': _buildingCtrl.text.trim().isEmpty ? null : _buildingCtrl.text.trim(),
          'floor': _floorCtrl.text.trim().isEmpty ? null : _floorCtrl.text.trim(),
          'zone': _zoneCtrl.text.trim().isEmpty ? null : _zoneCtrl.text.trim(),
        }
      };

      final res = await http.patch(
        _url(_devicePath(_deviceId)),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 10));

      final json = _decodeJson(res.body);

      if (res.statusCode == 404) {
        throw Exception('No existe PATCH ${_devicePath(_deviceId)} en backend.');
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception(json?['error']?.toString() ??
            json?['message']?.toString() ??
            res.body);
      }

      await _loadDevice();
      if (!mounted) return;

      setState(() => _saving = false);
      _snack('Dispositivo actualizado');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _deleteDevice() async {
    if (!_canDeleteDevice()) {
      _snack('No tienes permisos para eliminar dispositivos.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Eliminar dispositivo'),
        content: const Text('Esta acción no se puede deshacer. ¿Deseas continuar?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final token = await _getToken();
      if (token == null || token.isEmpty) throw Exception('Sesión inválida.');

      final res = await http.delete(
        _url(_devicePath(_deviceId)),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 10));

      final json = _decodeJson(res.body);

      if (res.statusCode == 404) {
        throw Exception('No existe DELETE ${_devicePath(_deviceId)} en backend.');
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception(json?['error']?.toString() ??
            json?['message']?.toString() ??
            res.body);
      }

      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Dispositivo eliminado');
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  // =============================
  // REALTIME MQTT
  // =============================
  void _startRealtime() {
    if (!_mqtt.isConnected) return;

    _mqtt.subscribe(_mqttSensorsWildcard);
    _mqtt.subscribe(_mqttActuatorStatusWildcard);

    _mqttSub?.cancel();
    _mqttSub = _mqtt.messagesStream.listen((evt) {
      final payload = _decodeJson(evt.payload) ?? const <String, dynamic>{};

      // SensorReading típico incluye deviceId :contentReference[oaicite:9]{index=9}
      final payloadDeviceId = (payload['deviceId'] ?? '').toString();
      if (payloadDeviceId.isNotEmpty && payloadDeviceId != _deviceId) return;

      // Si no trae deviceId, filtramos por plant/chamber si se puede
      final plantId = (_device['plantId'] ?? '').toString();
      final chamberId = (_device['chamberId'] ?? '').toString();

      if (payload['plantId'] != null && payload['plantId'].toString() != plantId) return;
      if (payload['chamberId'] != null && payload['chamberId'].toString() != chamberId) return;

      // Sensores: industrial/{plantId}/chambers/{chamberId}/sensors/{sensorType}
      if (evt.topic.contains('/sensors/')) {
        final sensorType = (payload['sensorType'] ?? _sensorTypeFromTopic(evt.topic)).toString();
        final valueAny = payload['value'];
        final unit = (payload['unit'] ?? '').toString();
        final ts = (payload['timestamp'] ?? '').toString();
        final alertTriggered = payload['alertTriggered'] == true; // SensorReading schema :contentReference[oaicite:10]{index=10}

        final value = (valueAny is num) ? valueAny.toDouble() : double.tryParse(valueAny?.toString() ?? '');

        if (sensorType.isNotEmpty) {
          setState(() {
            _latestReadings[sensorType] = {
              'value': value,
              'unit': unit,
              'timestamp': ts,
              'alertTriggered': alertTriggered,
            };
          });
        }
      }

      // Actuador status: industrial/{plantId}/chambers/{chamberId}/actuators/{actuatorId}/status
      if (evt.topic.contains('/actuators/') && evt.topic.endsWith('/status')) {
        final actuatorId = (payload['actuatorId'] ?? _actuatorIdFromTopic(evt.topic)).toString();
        final state = payload['state'] ?? payload['status'] ?? payload['value'];
        if (actuatorId.isNotEmpty) {
          setState(() {
            _actuatorStates[actuatorId] = state;
          });
        }
      }
    });
  }

  String _sensorTypeFromTopic(String topic) {
    final idx = topic.indexOf('/sensors/');
    if (idx < 0) return '';
    final s = topic.substring(idx + '/sensors/'.length);
    return s.split('/').first;
  }

  String _actuatorIdFromTopic(String topic) {
    final idx = topic.indexOf('/actuators/');
    if (idx < 0) return '';
    final s = topic.substring(idx + '/actuators/'.length);
    return s.split('/').first;
  }

  // =============================
  // MQTT COMMANDS (alineado a ActuatorService)
  // =============================
  Future<void> _sendActuatorCommand(Map<String, dynamic> actuator, dynamic command,
      {int? durationMs, int? pwmValue}) async {
    if (!_canControlActuators()) {
      _snack('No tienes permisos para controlar actuadores.');
      return;
    }
    if (!_mqtt.isConnected) {
      _snack('MQTT no conectado.');
      return;
    }

    // Device schema trae plantId/chamberId :contentReference[oaicite:11]{index=11}
    final plantId = (_device['plantId'] ?? '').toString();
    final chamberId = (_device['chamberId'] ?? '').toString();

    final actuatorId = (actuator['actuatorId'] ?? '').toString();
    final gpio = actuator['gpio'];

    if (plantId.isEmpty || chamberId.isEmpty || actuatorId.isEmpty) {
      _snack('Falta plantId/chamberId/actuatorId para enviar comando.');
      return;
    }

    // Topic EXACTO usado por backend ActuatorService :contentReference[oaicite:12]{index=12}
    final topic =
        'industrial/$plantId/chambers/$chamberId/actuators/$actuatorId/command';

    // Payload alineado al backend (y al ESP32 si lo esperan así)
    // ActuatorService publica: {commandId, actuatorId, command, gpio, timestamp, options:{...}} :contentReference[oaicite:13]{index=13}
    final payload = <String, dynamic>{
      'commandId': _uuidV4(),
      'actuatorId': actuatorId,
      'command': command,
      'gpio': gpio,
      'timestamp': DateTime.now().toIso8601String(),
      'options': <String, dynamic>{
        if (durationMs != null) 'duration': durationMs,
        if (pwmValue != null) 'pwmValue': pwmValue,
      }
    };

    _mqtt.publish(topic, jsonEncode(payload));
    _snack('Comando enviado a $actuatorId: $command');
  }

  // Sin dependencia externa
  String _uuidV4() {
    final r = Random.secure();
    String hex(int n) => n.toRadixString(16).padLeft(2, '0');
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant
    final b = bytes;
    return '${hex(b[0])}${hex(b[1])}${hex(b[2])}${hex(b[3])}-'
        '${hex(b[4])}${hex(b[5])}-'
        '${hex(b[6])}${hex(b[7])}-'
        '${hex(b[8])}${hex(b[9])}-'
        '${hex(b[10])}${hex(b[11])}${hex(b[12])}${hex(b[13])}${hex(b[14])}${hex(b[15])}';
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // =============================
  // UI
  // =============================
  @override
  Widget build(BuildContext context) {
    final canEdit = _canEditDevice();
    final canDelete = _canDeleteDevice();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Detalle del dispositivo'),
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            onPressed: (_loading || _saving) ? null : _boot,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _boot,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_loading) _infoCard('Cargando dispositivo...'),
            if (_error != null) _errorCard(_error!),

            if (!_loading && _error == null) ...[
              _headerCard(),

              const SizedBox(height: 12),
              _sectionTitle('Realtime'),
              const SizedBox(height: 8),
              _realtimeSensorsCard(),
              const SizedBox(height: 10),
              _realtimeActuatorsCard(),

              const SizedBox(height: 12),
              _sectionTitle('Editar dispositivo'),
              const SizedBox(height: 8),
              _editCard(enabled: canEdit),

              const SizedBox(height: 12),
              _sectionTitle('Campos (raw)'),
              const SizedBox(height: 8),
              _rawJsonCard(),

              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: (canEdit && !_saving) ? _saveDevice : null,
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined),
                      label: Text(_saving ? 'Guardando...' : 'Guardar cambios'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: BorderSide(color: Colors.red.shade300),
                      ),
                      onPressed: (canDelete && !_saving) ? _deleteDevice : null,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Eliminar'),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 10),
              Text(
                'DeviceId: $_deviceId • MQTT: ${_mqtt.isConnected ? "conectado" : "no conectado"}',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _headerCard() {
    final name = (_device['name'] ?? 'ESP32').toString();
    final status = (_device['status'] ?? '-').toString();
    final rssi = _device['rssi'];
    final rssiText = (rssi is num) ? rssi.toInt().toString() : (rssi?.toString() ?? '-');

    final plantId = (_device['plantId'] ?? '-').toString();
    final chamberId = (_device['chamberId'] ?? '-').toString();

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$name • $status',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text('deviceId: $_deviceId', style: Theme.of(context).textTheme.bodySmall),
            Text('plantId: $plantId • chamberId: $chamberId',
                style: Theme.of(context).textTheme.bodySmall),
            Text('RSSI: $rssiText dBm', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            Text(
              'Hardware: ${(_device['hardwareModel'] ?? 'ESP32')} • FW: ${(_device['firmwareVersion'] ?? '-')}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              'IP: ${(_device['ipAddress'] ?? '-')} • MAC: ${(_device['macAddress'] ?? '-')}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _realtimeSensorsCard() {
    // Device.sensors[].type viene del schema (temperature/humidity/...) :contentReference[oaicite:14]{index=14}
    if (_sensors.isEmpty) {
      return _infoCard('Este dispositivo no tiene sensores configurados.');
    }

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Sensores', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            ..._sensors.map((s) {
              final type = (s['type'] ?? 'custom').toString();
              final sensorId = (s['sensorId'] ?? '').toString();

              final latest = _latestReadings[type];
              final value = latest?['value'];
              final unit = (latest?['unit'] ?? '').toString();
              final alert = latest?['alertTriggered'] == true; // SensorReading.alertTriggered :contentReference[oaicite:15]{index=15}

              final displayVal = (value is num) ? value.toString() : (value?.toString() ?? '-');

              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.sensors_outlined,
                    color: alert ? Colors.orange : null),
                title: Text('$type${sensorId.isNotEmpty ? " • $sensorId" : ""}'),
                subtitle: Text('Valor: $displayVal $unit'),
                trailing: IconButton(
                  tooltip: alert ? 'ALARMADO' : 'OK',
                  icon: Icon(
                    Icons.warning_amber_rounded,
                    color: alert ? Colors.orange : Colors.grey.withOpacity(0.4),
                  ),
                  onPressed: () => _snack('Estado: ${alert ? "ALARMADO" : "OK"}'),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _realtimeActuatorsCard() {
    // Device.actuators[] viene del schema (relay/pwm/servo/...) :contentReference[oaicite:16]{index=16}
    if (_actuators.isEmpty) {
      return _infoCard('Este dispositivo no tiene actuadores configurados.');
    }

    final canControl = _canControlActuators();

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Actuadores', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            ..._actuators.map((a) {
              final actuatorId = (a['actuatorId'] ?? '').toString();
              final name = (a['name'] ?? 'Actuator').toString();
              final type = (a['type'] ?? 'relay').toString(); // relay/pwm/servo/... :contentReference[oaicite:17]{index=17}
              final gpio = a['gpio'];

              final state = _actuatorStates.containsKey(actuatorId)
                  ? _actuatorStates[actuatorId]
                  : a['state'];

              return Card(
                elevation: 0,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$name • $type • gpio $gpio • id $actuatorId',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text('Estado: ${state ?? "-"}',
                          style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 10),

                      if (type == 'relay' || type == 'valve' || type == 'motor' || type == 'led') ...[
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: canControl ? () => _sendActuatorCommand(a, 'ON') : null,
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('ON'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: canControl ? () => _sendActuatorCommand(a, 'OFF') : null,
                                icon: const Icon(Icons.stop),
                                label: const Text('OFF'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: canControl ? () => _sendActuatorCommand(a, 'TOGGLE') : null,
                                icon: const Icon(Icons.swap_horiz),
                                label: const Text('TOGGLE'),
                              ),
                            ),
                          ],
                        ),
                      ] else if (type == 'pwm') ...[
                        // PWM: enviamos valor 0-255 (como lo normaliza backend) :contentReference[oaicite:18]{index=18}
                        _PwmControl(
                          enabled: canControl,
                          onSend: (val) => _sendActuatorCommand(a, val, pwmValue: val),
                        ),
                      ] else if (type == 'servo') ...[
                        _ServoControl(
                          enabled: canControl,
                          onSend: (angle) => _sendActuatorCommand(a, angle),
                        ),
                      ] else ...[
                        Text(
                          'Tipo de actuador no soportado en UI aún.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],

                      if (!canControl) ...[
                        const SizedBox(height: 6),
                        Text('Control restringido por permisos.',
                            style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                      ],
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _editCard({required bool enabled}) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            TextField(
              controller: _nameCtrl,
              enabled: enabled && !_saving,
              decoration: const InputDecoration(
                labelText: 'Nombre',
                prefixIcon: Icon(Icons.edit_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descCtrl,
              enabled: enabled && !_saving,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Descripción',
                prefixIcon: Icon(Icons.description_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tagsCtrl,
              enabled: enabled && !_saving,
              decoration: const InputDecoration(
                labelText: 'Tags (separadas por coma)',
                prefixIcon: Icon(Icons.tag_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),

            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('OTA habilitado'),
              value: _otaEnabled,
              onChanged: (!enabled || _saving) ? null : (v) => setState(() => _otaEnabled = v),
            ),

            const SizedBox(height: 12),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Ubicación', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _buildingCtrl,
              enabled: enabled && !_saving,
              decoration: const InputDecoration(
                labelText: 'Building',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _floorCtrl,
              enabled: enabled && !_saving,
              decoration: const InputDecoration(
                labelText: 'Floor',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _zoneCtrl,
              enabled: enabled && !_saving,
              decoration: const InputDecoration(
                labelText: 'Zone',
                border: OutlineInputBorder(),
              ),
            ),

            if (!enabled) ...[
              const SizedBox(height: 10),
              Text('Edición restringida por permisos.',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _rawJsonCard() {
    final pretty = const JsonEncoder.withIndent('  ').convert(_device);
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: SelectableText(pretty),
      ),
    );
  }

  Widget _sectionTitle(String t) =>
      Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900));

  Widget _infoCard(String msg) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(Icons.info_outline),
            const SizedBox(width: 10),
            Expanded(child: Text(msg)),
          ],
        ),
      ),
    );
  }

  Widget _errorCard(String msg) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Error', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text(msg, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: _boot,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================
// Widgets auxiliares
// =============================
class _PwmControl extends StatefulWidget {
  final bool enabled;
  final void Function(int value) onSend;
  const _PwmControl({required this.enabled, required this.onSend});

  @override
  State<_PwmControl> createState() => _PwmControlState();
}

class _PwmControlState extends State<_PwmControl> {
  double _value = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Slider(
          value: _value,
          min: 0,
          max: 255,
          divisions: 255,
          onChanged: widget.enabled ? (v) => setState(() => _value = v) : null,
        ),
        Row(
          children: [
            Expanded(child: Text('PWM: ${_value.round()}')),
            ElevatedButton(
              onPressed: widget.enabled ? () => widget.onSend(_value.round()) : null,
              child: const Text('Enviar'),
            ),
          ],
        ),
      ],
    );
  }
}

class _ServoControl extends StatefulWidget {
  final bool enabled;
  final void Function(int angle) onSend;
  const _ServoControl({required this.enabled, required this.onSend});

  @override
  State<_ServoControl> createState() => _ServoControlState();
}

class _ServoControlState extends State<_ServoControl> {
  double _angle = 90;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Slider(
          value: _angle,
          min: 0,
          max: 180,
          divisions: 180,
          onChanged: widget.enabled ? (v) => setState(() => _angle = v) : null,
        ),
        Row(
          children: [
            Expanded(child: Text('Ángulo: ${_angle.round()}°')),
            ElevatedButton(
              onPressed: widget.enabled ? () => widget.onSend(_angle.round()) : null,
              child: const Text('Enviar'),
            ),
          ],
        ),
      ],
    );
  }
}

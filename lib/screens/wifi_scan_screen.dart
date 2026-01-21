import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config/app_config.dart';
import '../services/mqtt_rpc_client.dart';
import '../services/session_store.dart';
import '../models/admin_models.dart';

class WifiScanScreen extends StatefulWidget {
  const WifiScanScreen({super.key});

  @override
  State<WifiScanScreen> createState() => _WifiScanScreenState();
}

class _WifiScanScreenState extends State<WifiScanScreen> {
  final _info = NetworkInfo();

  SessionData? _session;
  bool _loadingSession = true;
  String? _error;

  bool get _isAdmin => (_session?.user.role ?? '') == 'admin';
  bool get _canManageDevices => _session?.user.permissions.canManageDevices == true || _isAdmin;

  // MQTT RPC
  late final MqttRpcClient _rpc;

  // Scan state
  bool _scanning = false;
  String? _wifiName;
  String? _ip;
  String? _subnet; // e.g. 192.168.1
  final List<_LanHost> _found = [];
  final Set<String> _seenIps = {};

  @override
  void initState() {
    super.initState();

    _rpc = MqttRpcClient(
      brokerHost: AppConfig.mqttHost,
      brokerPort: AppConfig.mqttPort,
      clientIdPrefix: 'flutter_wifi_scan',
      username: AppConfig.mqttUsername,
      password: AppConfig.mqttPassword,
      requestTopicBuilder: (clientId) => '${AppConfig.mqttBaseTopic}/$clientId/admin/req',
      responseTopicBuilder: (clientId) => '${AppConfig.mqttBaseTopic}/$clientId/admin/res',
    );

    _bootstrap();
  }

  @override
  void dispose() {
    _rpc.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loadingSession = true;
      _error = null;
    });

    try {
      final session = await SessionStore.instance.read();
      if (session == null) throw Exception('No hay sesión. Inicia sesión de nuevo.');
      _session = session;

      await _ensurePermissions();

      // Cargar datos WiFi
      _wifiName = await _info.getWifiName();
      _ip = await _info.getWifiIP();

      if (_ip == null || _ip!.isEmpty) {
        throw Exception('No pude obtener tu IP local. ¿Estás conectado a Wi-Fi?');
      }

      _subnet = _ip!.split('.').take(3).join('.');
      await _rpc.connect();

      setState(() => _loadingSession = false);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loadingSession = false;
      });
    }
  }

  Future<void> _ensurePermissions() async {
    // Para obtener SSID/IP y escanear red local suele requerir permisos de ubicación
    // (depende del OS). Pedimos lo mínimo.
    final loc = await Permission.locationWhenInUse.request();
    if (!loc.isGranted) {
      throw Exception('Permiso de ubicación requerido para obtener info de Wi-Fi / red local.');
    }

    // En Android 13+ puede pedir "nearby wifi devices" para WiFi SSID
    if (Platform.isAndroid) {
      // Este permiso existe en permission_handler como Permission.nearbyWifiDevices (según versión).
      // Si tu versión no lo trae, ignora este bloque.
      try {
        final p = await Permission.nearbyWifiDevices.request();
        // Si lo niega, igual podemos seguir (depende del dispositivo).
        // No lo hacemos fatal.
        if (!p.isGranted) {}
      } catch (_) {}
    }
  }

  Future<void> _scanLan() async {
    if (_scanning) return;
    if (_subnet == null) return;

    setState(() {
      _scanning = true;
      _found.clear();
      _seenIps.clear();
    });

    try {
      // Escaneo tipo ARP: hacemos ping a 1..254 y luego leemos tabla ARP
      // Para evitar saturar, usamos concurrencia limitada.
      final futures = <Future<void>>[];

      // Ajusta el rango si quieres (por ejemplo 1..50 para rápido)
      for (int i = 1; i <= 254; i++) {
        final ip = '$_subnet.$i';
        futures.add(_ping(ip));
        // limitar concurrencia
        if (futures.length >= 32) {
          await Future.wait(futures);
          futures.clear();
        }
      }
      if (futures.isNotEmpty) await Future.wait(futures);

      // Leer tabla ARP
      final arpHosts = await _readArpTable();
      for (final h in arpHosts) {
        if (_seenIps.add(h.ip)) {
          _found.add(h);
        }
      }

      // Ordenar
      _found.sort((a, b) => a.ip.compareTo(b.ip));
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) {
        setState(() => _scanning = false);
      }
    }
  }

  Future<void> _ping(String ip) async {
    try {
      // Ping rápido; en Android suele funcionar. En iOS puede estar restringido.
      // Si falla, igual ARP puede llenarse por otros medios, pero normalmente el ping ayuda.
      final result = await Process.run(
        Platform.isWindows ? 'ping' : 'ping',
        Platform.isWindows
            ? ['-n', '1', '-w', '250', ip]
            : ['-c', '1', '-W', '1', ip],
      );
      // ignoramos salida
      if (result.exitCode == 0) {}
    } catch (_) {
      // ignorar
    }
  }

  Future<List<_LanHost>> _readArpTable() async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run('arp', ['-a']);
        return _parseWindowsArp(r.stdout?.toString() ?? '');
      } else if (Platform.isAndroid || Platform.isLinux) {
        final r = await Process.run('ip', ['neigh']);
        final text = (r.stdout?.toString() ?? '');
        final hosts = _parseIpNeigh(text);
        if (hosts.isNotEmpty) return hosts;

        // fallback arp -a
        final r2 = await Process.run('arp', ['-a']);
        return _parseUnixArp(r2.stdout?.toString() ?? '');
      } else if (Platform.isMacOS || Platform.isIOS) {
        final r = await Process.run('arp', ['-a']);
        return _parseUnixArp(r.stdout?.toString() ?? '');
      } else {
        return [];
      }
    } catch (_) {
      return [];
    }
  }

  List<_LanHost> _parseWindowsArp(String text) {
    // Formato típico:
    //  192.168.1.1           00-11-22-33-44-55     dynamic
    final lines = text.split('\n');
    final out = <_LanHost>[];
    for (final line in lines) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2 && parts[0].contains('.') && parts[1].contains('-')) {
        final ip = parts[0];
        final mac = parts[1].toUpperCase();
        if (_subnet != null && ip.startsWith(_subnet!)) {
          out.add(_LanHost(ip: ip, mac: mac));
        }
      }
    }
    return out;
  }

  List<_LanHost> _parseUnixArp(String text) {
    // Formato típico:
    // ? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]
    final lines = text.split('\n');
    final out = <_LanHost>[];
    for (final line in lines) {
      final m = RegExp(r'\((\d+\.\d+\.\d+\.\d+)\)\s+at\s+([0-9a-fA-F:]{17})').firstMatch(line);
      if (m != null) {
        final ip = m.group(1)!;
        final mac = m.group(2)!.toUpperCase();
        if (_subnet != null && ip.startsWith(_subnet!)) {
          out.add(_LanHost(ip: ip, mac: mac));
        }
      }
    }
    return out;
  }

  List<_LanHost> _parseIpNeigh(String text) {
    // Formato ip neigh:
    // 192.168.1.1 dev wlan0 lladdr aa:bb:cc:dd:ee:ff REACHABLE
    final lines = text.split('\n');
    final out = <_LanHost>[];
    for (final line in lines) {
      final m = RegExp(r'^(\d+\.\d+\.\d+\.\d+)\s+dev\s+\S+\s+lladdr\s+([0-9a-fA-F:]{17})').firstMatch(line.trim());
      if (m != null) {
        final ip = m.group(1)!;
        final mac = m.group(2)!.toUpperCase();
        if (_subnet != null && ip.startsWith(_subnet!)) {
          out.add(_LanHost(ip: ip, mac: mac));
        }
      }
    }
    return out;
  }

  Future<void> _registerDeviceFromHost(_LanHost host) async {
    if (!_canManageDevices) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No tienes permiso para agregar dispositivos.')),
      );
      return;
    }

    // En industrial real: deviceId viene del ESP32 (por MQTT heartbeat),
    // aquí hacemos uno provisional basado en MAC/IP para “alta”.
    final deviceId = 'esp_${host.mac.replaceAll(':', '').replaceAll('-', '')}'.toLowerCase();

    final req = AdminDeviceCreate(
      deviceId: deviceId,
      name: 'ESP32 $deviceId',
      plantId: AppConfig.plantId, // tu plantId global
      chamberId: 'ch_01', // <-- puedes cambiarlo o hacerlo selectable después
      kind: 'sensor',
    );

    try {
      final res = await _rpc.requestJson(
        payload: {
          "type": "admin.devices.create",
          "token": _session!.token,
          "data": {
            ...req.toJson(),
            "ip": host.ip,
            "mac": host.mac,
          },
        },
        timeout: const Duration(seconds: 12),
      );

      if (res["success"] != true) {
        throw Exception(res["error"] ?? "No se pudo registrar el dispositivo");
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Dispositivo registrado: $deviceId ✅')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingSession) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Wi-Fi Scan')),
        body: _ErrorPanel(message: _error!, onRetry: _bootstrap),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Wi-Fi Scan'),
        actions: [
          IconButton(
            tooltip: 'Re-scan',
            onPressed: _scanning ? null : _scanLan,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Red actual', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text('Wi-Fi: ${_wifiName ?? "-"}'),
                  Text('IP: ${_ip ?? "-"}'),
                  Text('Subnet: ${_subnet ?? "-"}.*'),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _scanning ? null : _scanLan,
                          icon: _scanning
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.wifi_find),
                          label: Text(_scanning ? 'Escaneando...' : 'Escanear red'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _canManageDevices
                        ? 'Puedes registrar dispositivos desde aquí.'
                        : 'Solo lectura: no tienes permiso para agregar dispositivos.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          Text('Dispositivos detectados', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),

          if (_found.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text('Aún no hay resultados. Presiona "Escanear red".'),
              ),
            )
          else
            ..._found.map((h) => Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    leading: const Icon(Icons.device_hub),
                    title: Text(h.ip),
                    subtitle: Text('MAC: ${h.mac}'),
                    trailing: _canManageDevices
                        ? ElevatedButton(
                            onPressed: () => _registerDeviceFromHost(h),
                            child: const Text('Agregar'),
                          )
                        : null,
                  ),
                )),
        ],
      ),
    );
  }
}

class _LanHost {
  final String ip;
  final String mac;

  _LanHost({required this.ip, required this.mac});
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

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
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}

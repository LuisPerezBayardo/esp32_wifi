import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../app/theme_controller.dart';

class PreferencesScreen extends StatefulWidget {
  const PreferencesScreen({super.key});

  @override
  State<PreferencesScreen> createState() => _PreferencesScreenState();
}

class _PreferencesScreenState extends State<PreferencesScreen> {
  // =============================
  // CONFIG BACKEND
  // =============================
  static const String _backendHost = '10.0.2.2'; // 👈 Ajusta
  static const int _backendPort = 3000;
  static const String _apiVersion = 'v1';

  Uri _url(String path) =>
      Uri.parse('http://$_backendHost:$_backendPort/api/$_apiVersion$path');

  bool _loading = true;
  bool _saving = false;
  String? _error;

  // --- Notif prefs (backend) ---
  bool _emailNotif = true;
  bool _pushNotif = true;
  bool _smsNotif = false;

  bool _alertCritical = true;
  bool _alertWarning = true;
  bool _alertInfo = false;
  bool _alertDeviceOffline = true;

  bool _quietEnabled = false;
  TimeOfDay _quietStart = const TimeOfDay(hour: 22, minute: 0);
  TimeOfDay _quietEnd = const TimeOfDay(hour: 7, minute: 0);

  @override
  void initState() {
    super.initState();
    _loadFromBackend();
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

  String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  TimeOfDay _parseTime(String? hhmm, TimeOfDay fallback) {
    if (hhmm == null || !hhmm.contains(':')) return fallback;
    final parts = hhmm.split(':');
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts.length > 1 ? parts[1] : '');
    if (h == null || m == null) return fallback;
    return TimeOfDay(hour: h.clamp(0, 23), minute: m.clamp(0, 59));
  }

  Future<void> _loadFromBackend() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
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
        throw Exception(json?['error']?.toString() ?? json?['message']?.toString() ?? res.body);
      }

      final data = (json?['data'] is Map<String, dynamic>) ? json!['data'] : json;
      final user = (data is Map<String, dynamic> && data['user'] is Map<String, dynamic>)
          ? data['user'] as Map<String, dynamic>
          : (data is Map<String, dynamic> ? data : <String, dynamic>{});

      final np = (user['notificationPreferences'] is Map<String, dynamic>)
          ? user['notificationPreferences'] as Map<String, dynamic>
          : <String, dynamic>{};

      final alertTypes = (np['alertTypes'] is Map<String, dynamic>)
          ? np['alertTypes'] as Map<String, dynamic>
          : <String, dynamic>{};

      final quiet = (np['quietHours'] is Map<String, dynamic>)
          ? np['quietHours'] as Map<String, dynamic>
          : <String, dynamic>{};

      setState(() {
        _emailNotif = np['email'] != false;
        _pushNotif = np['push'] != false;
        _smsNotif = np['sms'] == true;

        _alertCritical = alertTypes['critical'] != false;
        _alertWarning = alertTypes['warning'] != false;
        _alertInfo = alertTypes['info'] == true;
        _alertDeviceOffline = alertTypes['deviceOffline'] != false;

        _quietEnabled = quiet['enabled'] == true;
        _quietStart = _parseTime(quiet['start']?.toString(), _quietStart);
        _quietEnd = _parseTime(quiet['end']?.toString(), _quietEnd);

        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _saveToBackend() async {
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final token = await _getToken();
      if (token == null || token.isEmpty) {
        throw Exception('No hay sesión activa. Inicia sesión de nuevo.');
      }

      // Esto debe coincidir con User.notificationPreferences del backend :contentReference[oaicite:4]{index=4}
      final body = {
        'notificationPreferences': {
          'email': _emailNotif,
          'push': _pushNotif,
          'sms': _smsNotif,
          'alertTypes': {
            'critical': _alertCritical,
            'warning': _alertWarning,
            'info': _alertInfo,
            'deviceOffline': _alertDeviceOffline,
          },
          'quietHours': {
            'enabled': _quietEnabled,
            'start': _formatTime(_quietStart), // "22:00"
            'end': _formatTime(_quietEnd),     // "07:00"
          },
        }
      };

      final res = await http.patch(
        _url('/auth/profile'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 10));

      final json = _decodeJson(res.body);

      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception(json?['error']?.toString() ?? json?['message']?.toString() ?? res.body);
      }

      if (!mounted) return;
      setState(() => _saving = false);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Preferencias guardadas')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _pickQuietStart() async {
    final picked = await showTimePicker(context: context, initialTime: _quietStart);
    if (picked == null) return;
    setState(() => _quietStart = picked);
  }

  Future<void> _pickQuietEnd() async {
    final picked = await showTimePicker(context: context, initialTime: _quietEnd);
    if (picked == null) return;
    setState(() => _quietEnd = picked);
  }

  Future<void> _resetPreferences() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Restablecer preferencias'),
        content: const Text(
          'Esto regresará el tema a "Sistema" y las notificaciones a valores por defecto.\n\n'
          '¿Deseas continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restablecer'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // 1) Tema: local → Sistema
    await ThemeController.instance.setMode(ThemeMode.system);

    // 2) Notificaciones: backend → defaults del schema :contentReference[oaicite:1]{index=1}
    setState(() {
      _emailNotif = true;
      _pushNotif = true;
      _smsNotif = false;

      _alertCritical = true;
      _alertWarning = true;
      _alertInfo = false;
      _alertDeviceOffline = true;

      _quietEnabled = false;
      _quietStart = const TimeOfDay(hour: 22, minute: 0);
      _quietEnd = const TimeOfDay(hour: 7, minute: 0);
    });

    // Guardar en backend
    await _saveToBackend();
  }





















  @override
  Widget build(BuildContext context) {
    final themeMode = ThemeController.instance.mode;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Preferencias'),
        actions: [
          IconButton(
            tooltip: 'Guardar',
            onPressed: (_loading || _saving) ? null : _saveToBackend,
            icon: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadFromBackend,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_loading) _infoCard('Cargando preferencias...'),
            if (_error != null) _errorCard(_error!),

            _sectionTitle('Apariencia'),
            const SizedBox(height: 8),
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              child: Column(
                children: [
                  RadioListTile<ThemeMode>(
                    value: ThemeMode.system,
                    groupValue: themeMode,
                    title: const Text('Sistema'),
                    subtitle: const Text('Usa el tema del teléfono'),
                    onChanged: (_) => ThemeController.instance.setMode(ThemeMode.system),
                  ),
                  RadioListTile<ThemeMode>(
                    value: ThemeMode.light,
                    groupValue: themeMode,
                    title: const Text('Claro'),
                    onChanged: (_) => ThemeController.instance.setMode(ThemeMode.light),
                  ),
                  RadioListTile<ThemeMode>(
                    value: ThemeMode.dark,
                    groupValue: themeMode,
                    title: const Text('Oscuro'),
                    onChanged: (_) => ThemeController.instance.setMode(ThemeMode.dark),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),
            _sectionTitle('Notificaciones'),
            const SizedBox(height: 8),

            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('Email'),
                    subtitle: const Text('Recibir alertas por correo'),
                    value: _emailNotif,
                    onChanged: _loading ? null : (v) => setState(() => _emailNotif = v),
                  ),
                  SwitchListTile(
                    title: const Text('Push'),
                    subtitle: const Text('Recibir notificaciones en el teléfono'),
                    value: _pushNotif,
                    onChanged: _loading ? null : (v) => setState(() => _pushNotif = v),
                  ),
                  SwitchListTile(
                    title: const Text('SMS'),
                    subtitle: const Text('Recibir alertas por SMS (si está habilitado)'),
                    value: _smsNotif,
                    onChanged: _loading ? null : (v) => setState(() => _smsNotif = v),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),
            _sectionTitle('Tipos de alerta'),
            const SizedBox(height: 8),

            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('Críticas'),
                    value: _alertCritical,
                    onChanged: _loading ? null : (v) => setState(() => _alertCritical = v),
                  ),
                  SwitchListTile(
                    title: const Text('Warning'),
                    value: _alertWarning,
                    onChanged: _loading ? null : (v) => setState(() => _alertWarning = v),
                  ),
                  SwitchListTile(
                    title: const Text('Info'),
                    value: _alertInfo,
                    onChanged: _loading ? null : (v) => setState(() => _alertInfo = v),
                  ),
                  SwitchListTile(
                    title: const Text('Dispositivo offline'),
                    subtitle: const Text('Aviso cuando un device deja de reportar'),
                    value: _alertDeviceOffline,
                    onChanged: _loading ? null : (v) => setState(() => _alertDeviceOffline = v),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),
            _sectionTitle('Horario silencioso'),
            const SizedBox(height: 8),

            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('Activar horario silencioso'),
                    subtitle: const Text('Reduce notificaciones fuera de horario'),
                    value: _quietEnabled,
                    onChanged: _loading ? null : (v) => setState(() => _quietEnabled = v),
                  ),
                  ListTile(
                    enabled: _quietEnabled && !_loading,
                    leading: const Icon(Icons.nightlight_outlined),
                    title: const Text('Inicio'),
                    trailing: Text(_formatTime(_quietStart)),
                    onTap: (_quietEnabled && !_loading) ? _pickQuietStart : null,
                  ),
                  ListTile(
                    enabled: _quietEnabled && !_loading,
                    leading: const Icon(Icons.wb_sunny_outlined),
                    title: const Text('Fin'),
                    trailing: Text(_formatTime(_quietEnd)),
                    onTap: (_quietEnabled && !_loading) ? _pickQuietEnd : null,
                  ),
                ],
              ),
            ),


            const SizedBox(height: 12),

            SizedBox(
              height: 48,
              child: OutlinedButton.icon(
                onPressed: (_loading || _saving) ? null : _resetPreferences,
                icon: const Icon(Icons.restart_alt),
                label: const Text('Restablecer preferencias'),
              ),
            ),

            const SizedBox(height: 14),
            SizedBox(
              height: 48,
              child: ElevatedButton.icon(
                onPressed: (_loading || _saving) ? null : _saveToBackend,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Guardar preferencias'),
              ),
            ),

            const SizedBox(height: 12),
            Text(
              'Backend: GET/PATCH /api/$_apiVersion/auth/profile',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String t) =>
      Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800));

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
            const Text('Error', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(msg, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: _loadFromBackend,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}

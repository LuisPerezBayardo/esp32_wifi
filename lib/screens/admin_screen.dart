import 'dart:async';
//import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/mqtt_rpc_client.dart';
import '../services/session_store.dart';
import '../config/app_config.dart';
import '../models/admin_models.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  final _usersSearchCtrl = TextEditingController();

  bool _loading = true;
  String? _error;

  SessionData? _session;

  // Permisos efectivos
  bool get _isAdmin => (_session?.user.role ?? '') == 'admin';
  bool get _canManageUsers => _session?.user.permissions.canManageUsers == true || _isAdmin;
  bool get _canManageDevices => _session?.user.permissions.canManageDevices == true || _isAdmin;

  // Datos
  List<AdminUser> _users = [];
  bool _usersLoading = false;

  late final MqttRpcClient _rpc;

  @override
  void initState() {
    super.initState();
    _rpc = MqttRpcClient(
      brokerHost: AppConfig.mqttHost,
      brokerPort: AppConfig.mqttPort,
      clientIdPrefix: 'flutter_admin',
      username: AppConfig.mqttUsername,
      password: AppConfig.mqttPassword,
      // Topics RPC (request/response)
      requestTopicBuilder: (clientId) => '${AppConfig.mqttBaseTopic}/$clientId/admin/req',
      responseTopicBuilder: (clientId) => '${AppConfig.mqttBaseTopic}/$clientId/admin/res',
    );

    _bootstrap();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final session = await SessionStore.instance.read();
      if (session == null) {
        throw Exception('No hay sesión. Vuelve a iniciar sesión.');
      }

      _session = session;

      // Conectar MQTT (solo una vez)
      await _rpc.connect();

      setState(() => _loading = false);

      // Si tiene permiso, carga usuarios
      if (_canManageUsers) {
        await _loadUsers();
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _usersSearchCtrl.dispose();
    _rpc.dispose();
    super.dispose();
  }

  Future<void> _loadUsers() async {
    if (!_canManageUsers) return;

    setState(() {
      _usersLoading = true;
      _error = null;
    });

    try {
      final res = await _rpc.requestJson(
        payload: {
          "type": "admin.users.list",
          "token": _session!.token, // tu backend MQTT debe validar esto
          "data": {},
        },
        timeout: const Duration(seconds: 10),
      );

      if (res["success"] != true) {
        throw Exception(res["error"] ?? "No se pudieron cargar usuarios");
      }

      final list = (res["data"]?["users"] as List?) ?? const [];
      final parsed = list.map((e) => AdminUser.fromJson(Map<String, dynamic>.from(e))).toList();

      setState(() => _users = parsed);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _usersLoading = false);
    }
  }

  Future<void> _updateUserPermissions(AdminUser user, AdminPermissions perms) async {
    if (!_canManageUsers) return;

    try {
      final res = await _rpc.requestJson(
        payload: {
          "type": "admin.users.updatePermissions",
          "token": _session!.token,
          "data": {
            "userId": user.id,
            "permissions": perms.toJson(),
          }
        },
        timeout: const Duration(seconds: 10),
      );

      if (res["success"] != true) {
        throw Exception(res["error"] ?? "No se pudieron actualizar permisos");
      }

      // refrescar lista (o actualizar local)
      await _loadUsers();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Permisos actualizados ✅')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _createDevice(AdminDeviceCreate req) async {
    if (!_canManageDevices) return;

    try {
      final res = await _rpc.requestJson(
        payload: {
          "type": "admin.devices.create",
          "token": _session!.token,
          "data": req.toJson(),
        },
        timeout: const Duration(seconds: 12),
      );

      if (res["success"] != true) {
        throw Exception(res["error"] ?? "No se pudo crear el dispositivo");
      }

      if (mounted) {
        Navigator.pop(context); // cerrar sheet
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Dispositivo creado ✅')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  void _openAddDeviceSheet() {
    if (!_canManageDevices) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No tienes permiso para administrar dispositivos')),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AddDeviceSheet(onCreate: _createDevice),
    );
  }

  List<AdminUser> get _filteredUsers {
    final q = _usersSearchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _users;

    return _users.where((u) {
      final hay = [
        u.email,
        u.firstName,
        u.lastName,
        u.role,
      ].join(' ').toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Administración')),
        body: _ErrorPanel(message: _error!, onRetry: _bootstrap),
      );
    }

    final canEnterAdmin = _isAdmin || _canManageUsers || _canManageDevices;

    if (!canEnterAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Administración')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Acceso denegado.\n\nTu cuenta no tiene permisos para entrar a Administración.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Administración'),
        actions: [
          IconButton(
            tooltip: 'Recargar',
            onPressed: () async {
              if (_canManageUsers) await _loadUsers();
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // ====== Bloque: acciones rápidas ======
          Text('Acciones', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),

          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.add_box),
                  title: const Text('Agregar nuevo dispositivo'),
                  subtitle: Text(_canManageDevices
                      ? 'Crear un dispositivo (alta en backend)'
                      : 'Sin permiso (canManageDevices)'),
                  onTap: _canManageDevices ? _openAddDeviceSheet : null,
                ),
                const Divider(height: 0),
                ListTile(
                  leading: const Icon(Icons.wifi_find),
                  title: const Text('Escanear dispositivos WiFi'),
                  subtitle: const Text('Ir a la pantalla de escaneos'),
                  onTap: () => Navigator.pushNamed(context, '/wifi_scans'),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ====== Bloque: usuarios ======
          Text('Usuarios', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),

          if (!_canManageUsers)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text('Tu cuenta no tiene permiso para administrar usuarios (canManageUsers).'),
              ),
            )
          else ...[
            TextField(
              controller: _usersSearchCtrl,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Buscar por email/nombre/rol...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                suffixIcon: _usersSearchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Limpiar',
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() => _usersSearchCtrl.clear()),
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),

            if (_usersLoading)
              const Center(child: Padding(padding: EdgeInsets.all(10), child: CircularProgressIndicator()))
            else if (_filteredUsers.isEmpty)
              const Card(child: Padding(padding: EdgeInsets.all(12), child: Text('No hay usuarios para mostrar.')))
            else
              ..._filteredUsers.map((u) => _UserCard(
                    user: u,
                    onEditPermissions: () async {
                      final updated = await showDialog<AdminPermissions>(
                        context: context,
                        builder: (_) => _PermissionsDialog(initial: u.permissions),
                      );
                      if (updated != null) {
                        await _updateUserPermissions(u, updated);
                      }
                    },
                  )),
          ],

          const SizedBox(height: 24),

          // ====== Nota técnica ======
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Nota:\n'
                '- Roles y permisos en backend: role = admin/supervisor/operator/viewer y flags como canManageUsers/canManageDevices. '
                'Estos campos existen en tu modelo User. :contentReference[oaicite:1]{index=1}\n'
                '- Este AdminScreen usa MQTT tipo RPC. Debes implementar en backend los handlers para:\n'
                '   • admin.users.list\n'
                '   • admin.users.updatePermissions\n'
                '   • admin.devices.create\n'
                'Los topics request/response deben coincidir con AppConfig.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UserCard extends StatelessWidget {
  const _UserCard({
    required this.user,
    required this.onEditPermissions,
  });

  final AdminUser user;
  final VoidCallback onEditPermissions;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.person, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${user.firstName} ${user.lastName} • ${user.email}',
                    style: Theme.of(context).textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Chip(label: Text(user.role)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _permChip(context, 'Users', user.permissions.canManageUsers),
                _permChip(context, 'Devices', user.permissions.canManageDevices),
                _permChip(context, 'Actuators', user.permissions.canControlActuators),
                _permChip(context, 'Thresholds', user.permissions.canEditThresholds),
                _permChip(context, 'Export', user.permissions.canExportData),
                _permChip(context, 'ViewAllPlants', user.permissions.canViewAllPlants),
              ],
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: onEditPermissions,
                icon: const Icon(Icons.admin_panel_settings),
                label: const Text('Editar permisos'),
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _permChip(BuildContext context, String label, bool value) {
    final cs = Theme.of(context).colorScheme;
    return Chip(
      avatar: Icon(value ? Icons.check_circle : Icons.cancel,
          size: 16, color: value ? cs.primary : cs.outline),
      label: Text('$label: ${value ? "ON" : "OFF"}'),
    );
  }
}

class _PermissionsDialog extends StatefulWidget {
  const _PermissionsDialog({required this.initial});

  final AdminPermissions initial;

  @override
  State<_PermissionsDialog> createState() => _PermissionsDialogState();
}

class _PermissionsDialogState extends State<_PermissionsDialog> {
  late AdminPermissions p;

  @override
  void initState() {
    super.initState();
    p = widget.initial.copy();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Editar permisos'),
      content: SingleChildScrollView(
        child: Column(
          children: [
            SwitchListTile(
              value: p.canManageUsers,
              onChanged: (v) => setState(() => p = p.copyWith(canManageUsers: v)),
              title: const Text('canManageUsers'),
            ),
            SwitchListTile(
              value: p.canManageDevices,
              onChanged: (v) => setState(() => p = p.copyWith(canManageDevices: v)),
              title: const Text('canManageDevices'),
            ),
            SwitchListTile(
              value: p.canControlActuators,
              onChanged: (v) => setState(() => p = p.copyWith(canControlActuators: v)),
              title: const Text('canControlActuators'),
            ),
            SwitchListTile(
              value: p.canEditThresholds,
              onChanged: (v) => setState(() => p = p.copyWith(canEditThresholds: v)),
              title: const Text('canEditThresholds'),
            ),
            SwitchListTile(
              value: p.canExportData,
              onChanged: (v) => setState(() => p = p.copyWith(canExportData: v)),
              title: const Text('canExportData'),
            ),
            SwitchListTile(
              value: p.canViewAllPlants,
              onChanged: (v) => setState(() => p = p.copyWith(canViewAllPlants: v)),
              title: const Text('canViewAllPlants'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        ElevatedButton(onPressed: () => Navigator.pop(context, p), child: const Text('Guardar')),
      ],
    );
  }
}

class _AddDeviceSheet extends StatefulWidget {
  const _AddDeviceSheet({required this.onCreate});

  final Future<void> Function(AdminDeviceCreate req) onCreate;

  @override
  State<_AddDeviceSheet> createState() => _AddDeviceSheetState();
}

class _AddDeviceSheetState extends State<_AddDeviceSheet> {
  final _formKey = GlobalKey<FormState>();

  final _deviceId = TextEditingController();
  final _name = TextEditingController();
  final _plantId = TextEditingController();
  final _chamberId = TextEditingController();

  String _kind = 'sensor'; // sensor | actuator
  bool _saving = false;

  @override
  void dispose() {
    _deviceId.dispose();
    _name.dispose();
    _plantId.dispose();
    _chamberId.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    try {
      await widget.onCreate(
        AdminDeviceCreate(
          deviceId: _deviceId.text.trim(),
          name: _name.text.trim(),
          plantId: _plantId.text.trim(),
          chamberId: _chamberId.text.trim(),
          kind: _kind,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, bottom: bottom + 16, top: 8),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Agregar dispositivo', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),

            TextFormField(
              controller: _deviceId,
              decoration: const InputDecoration(labelText: 'deviceId (único)', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'deviceId requerido' : null,
            ),
            const SizedBox(height: 10),

            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Nombre', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Nombre requerido' : null,
            ),
            const SizedBox(height: 10),

            TextFormField(
              controller: _plantId,
              decoration: const InputDecoration(labelText: 'plantId', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'plantId requerido' : null,
            ),
            const SizedBox(height: 10),

            TextFormField(
              controller: _chamberId,
              decoration: const InputDecoration(labelText: 'chamberId', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'chamberId requerido' : null,
            ),
            const SizedBox(height: 10),

            DropdownButtonFormField<String>(
              value: _kind,
              decoration: const InputDecoration(labelText: 'Tipo', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'sensor', child: Text('Sensor')),
                DropdownMenuItem(value: 'actuator', child: Text('Actuador')),
              ],
              onChanged: (v) => setState(() => _kind = v ?? 'sensor'),
            ),
            const SizedBox(height: 14),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _submit,
                icon: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save),
                label: const Text('Crear'),
              ),
            ),
          ],
        ),
      ),
    );
  }
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

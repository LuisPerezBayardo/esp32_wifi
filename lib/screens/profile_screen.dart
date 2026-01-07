import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  // =============================
  // CONFIG (ajusta si cambia tu backend)
  // =============================
  static const String _backendHost = '10.0.2.2'; // Android emulator
  static const int _backendPort = 3000;
  static const String _apiVersion = 'v1';

  Uri _url(String path) =>
      Uri.parse('http://$_backendHost:$_backendPort/api/$_apiVersion$path');

  final _formKey = GlobalKey<FormState>();

  // Campos editables (NO afectan autenticación)
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _avatarCtrl = TextEditingController();

  // Campos solo lectura
  String _email = '';
  String _role = '';
  bool _isEmailVerified = false;
  bool _isActive = true;

  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _phoneCtrl.dispose();
    _avatarCtrl.dispose();
    super.dispose();
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

  Future<void> _loadProfile() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final token = await _getToken();
      if (token == null || token.isEmpty) {
        throw Exception('No hay sesión activa. Inicia sesión de nuevo.');
      }

      // GET /auth/profile  :contentReference[oaicite:3]{index=3}
      final res = await http.get(
        _url('/auth/profile'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 10));

      final json = _decodeJson(res.body);

      if (res.statusCode < 200 || res.statusCode >= 300) {
        final msg = json?['error']?.toString() ??
            json?['message']?.toString() ??
            'HTTP ${res.statusCode}: ${res.body}';
        throw Exception(msg);
      }

      // Soportar varios formatos de respuesta:
      // - { success:true, data:{ user:{...} } }
      // - { user:{...} }
      // - { ...userFields }
      final data =
          (json?['data'] is Map<String, dynamic>) ? json!['data'] : json;
      final user = (data is Map<String, dynamic> &&
              data['user'] is Map<String, dynamic>)
          ? data['user'] as Map<String, dynamic>
          : (data is Map<String, dynamic> ? data : <String, dynamic>{});

      setState(() {
        _email = (user['email'] ?? '').toString();
        _role = (user['role'] ?? '').toString();
        _isEmailVerified = user['isEmailVerified'] == true;
        _isActive = user['isActive'] != false;

        _firstNameCtrl.text = (user['firstName'] ?? '').toString();
        _lastNameCtrl.text = (user['lastName'] ?? '').toString();
        _phoneCtrl.text = (user['phone'] ?? '').toString();
        _avatarCtrl.text = (user['avatar'] ?? '').toString();

        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _saveProfile() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final token = await _getToken();
      if (token == null || token.isEmpty) {
        throw Exception('No hay sesión activa. Inicia sesión de nuevo.');
      }

      // PATCH /auth/profile  :contentReference[oaicite:4]{index=4}
      // Solo mandamos campos que NO afectan autenticación:
      final body = <String, dynamic>{
        'firstName': _firstNameCtrl.text.trim(),
        'lastName': _lastNameCtrl.text.trim(),
        'phone': _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
        'avatar': _avatarCtrl.text.trim().isEmpty ? null : _avatarCtrl.text.trim(),
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
        final msg = json?['error']?.toString() ??
            json?['message']?.toString() ??
            'HTTP ${res.statusCode}: ${res.body}';
        throw Exception(msg);
      }

      if (!mounted) return;
      setState(() => _saving = false);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Perfil actualizado')),
      );

      // Recargar por si el backend normaliza/transforma datos
      await _loadProfile();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }


  // =============================
  // ELIMINAR CUENTA (AJUSTA A TU BACKEND)
  // =============================
  // ⚠️ Actualmente NO existe en tus rutas (falta implementarlo). :contentReference[oaicite:1]{index=1}
  // Opciones comunes en backend:
  // - DELETE /auth/profile
  // - DELETE /auth/account
  // - POST /auth/deactivate (soft delete)
  static const String _deletePath = '/auth/profile';

  Future<void> _deleteProfile() async {
    final token = await _getToken();
    if (token == null || token.isEmpty) {
      throw Exception('No hay sesión activa. Inicia sesión de nuevo.');
    }

    final res = await http.delete(
      _url(_deletePath),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    ).timeout(const Duration(seconds: 10));

    final json = _decodeJson(res.body);

    if (res.statusCode == 404) {
      throw Exception(
        'El backend no tiene implementado DELETE $_deletePath todavía. '
        'Hay que agregar ese endpoint en el backend.',
      );
    }

    if (res.statusCode < 200 || res.statusCode >= 300) {
      final msg = json?['error']?.toString() ??
          json?['message']?.toString() ??
          'HTTP ${res.statusCode}: ${res.body}';
      throw Exception(msg);
    }
  }























  @override
  Widget build(BuildContext context) {
    final canInteract = !_loading && !_saving;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Perfil'),
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            onPressed: _saving ? null : _loadProfile,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadProfile,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _headerCard(),

            const SizedBox(height: 14),

            if (_loading) _infoCard('Cargando perfil...'),
            if (_error != null) _errorCard(_error!),

            if (!_loading) ...[
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _firstNameCtrl,
                      enabled: canInteract,
                      decoration: const InputDecoration(
                        labelText: 'Nombre(s)',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) {
                          return 'Requerido';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),

                    TextFormField(
                      controller: _lastNameCtrl,
                      enabled: canInteract,
                      decoration: const InputDecoration(
                        labelText: 'Apellidos',
                        prefixIcon: Icon(Icons.badge_outlined),
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) {
                          return 'Requerido';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),

                    TextFormField(
                      controller: _phoneCtrl,
                      enabled: canInteract,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Teléfono (opcional)',
                        prefixIcon: Icon(Icons.phone_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),

                    TextFormField(
                      controller: _avatarCtrl,
                      enabled: canInteract,
                      decoration: const InputDecoration(
                        labelText: 'Avatar URL (opcional)',
                        prefixIcon: Icon(Icons.image_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),

                    const SizedBox(height: 16),

                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton.icon(
                        onPressed: canInteract ? _saveProfile : null,
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

                    const SizedBox(height: 18),

                    // =============================
                    // ZONA PELIGROSA
                    // =============================
                    Card(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Zona peligrosa',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Eliminar tu perfil borrará tu cuenta. Esta acción no se puede deshacer.',
                              style: TextStyle(color: Colors.red.shade700),
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.red,
                                  side: BorderSide(color: Colors.red.shade400),
                                ),
                                onPressed: (_loading || _saving) ? null : () async {
                                  final confirmed = await showDialog<bool>(
                                    context: context,
                                    builder: (_) => AlertDialog(
                                      title: const Text('¿Eliminar perfil?'),
                                      content: const Text(
                                        'Esta acción es irreversible.\n\n'
                                        '¿Seguro que quieres eliminar tu cuenta?',
                                      ),
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
                                    await _deleteProfile();

                                    // Si se elimina bien: limpiamos tokens y regresamos al login
                                    final prefs = await SharedPreferences.getInstance();
                                    await prefs.remove('access_token');
                                    await prefs.remove('refresh_token');

                                    if (!mounted) return;
                                    Navigator.pushNamedAndRemoveUntil(context, '/login', (r) => false);
                                  } catch (e) {
                                    if (!mounted) return;
                                    setState(() {
                                      _saving = false;
                                      _error = e.toString();
                                    });
                                  }
                                },
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('Eliminar perfil'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),


                    const SizedBox(height: 12),
                    Text(
                      'Endpoint: GET/PATCH /api/$_apiVersion/auth/profile',
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _headerCard() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const CircleAvatar(
              radius: 22,
              child: Icon(Icons.person),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _email.isEmpty ? 'Tu perfil' : _email,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Rol: ${_role.isEmpty ? "-" : _role}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    'Email verificado: ${_isEmailVerified ? "Sí" : "No"} • Cuenta activa: ${_isActive ? "Sí" : "No"}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

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
            const Text('Error', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(msg, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: _loadProfile,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}

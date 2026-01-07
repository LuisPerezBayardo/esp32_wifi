import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();

  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  bool _loading = false;
  bool _obscure = true;
  String? _error;
  String? _success;

  // =============================
  // CONFIG QUE DEBE COINCIDIR
  // =============================
  // Backend default:
  // Port: 3000
  // API: /api/v1
  // -----------------------------
  // Ajusta el host según tu entorno:
  // Android Emulator  → 10.0.2.2
  // iOS Simulator     → localhost
  // Celular físico    → IP de tu PC (ej: 192.168.1.50)
  static const String _backendHost = '10.0.2.2'; // 👈 AJUSTA
  static const int _backendPort = 3000;
  static const String _apiVersion = 'v1';

  Uri _url(String path) =>
      Uri.parse('http://$_backendHost:$_backendPort/api/$_apiVersion$path');

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _signup() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _error = null;
      _success = null;
    });

    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _loading = true);

    try {
      final username = _userCtrl.text.trim();
      final password = _passCtrl.text;

      // 🚀 Backend route real:
      // POST /api/v1/auth/register
      final res = await http
          .post(
            _url('/auth/register'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              // ⚠️ Si el backend espera "email" en vez de "username",
              // cambia aquí a:
              // "email": username,
              "username": username,
              "password": password,
            }),
          )
          .timeout(const Duration(seconds: 10));

      final bodyText = res.body;
      Map<String, dynamic>? json;
      try {
        final decoded = jsonDecode(bodyText);
        if (decoded is Map<String, dynamic>) json = decoded;
      } catch (_) {}

      if (res.statusCode < 200 || res.statusCode >= 300) {
        final errMsg = json?['error']?.toString() ??
            json?['message']?.toString() ??
            'HTTP ${res.statusCode}: $bodyText';
        throw Exception(errMsg);
      }

      final success = json?['success'];
      if (success == false) {
        throw Exception(json?['error']?.toString() ?? 'No se pudo crear usuario');
      }

      if (!mounted) return;

      setState(() {
        _loading = false;
        _success = 'Cuenta creada correctamente. Ahora puedes iniciar sesión.';
      });

    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPress = !_loading;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Crear cuenta'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _loading ? null : () => Navigator.pop(context),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.person_add_alt_1_outlined, size: 64),
                const SizedBox(height: 12),
                const Text(
                  'Registro de usuario',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 18),

                if (_error != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.red.withOpacity(0.35)),
                    ),
                    child: Text(_error!, style: const TextStyle(color: Colors.red)),
                  ),
                  const SizedBox(height: 12),
                ],

                if (_success != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.green.withOpacity(0.35)),
                    ),
                    child: Text(
                      _success!,
                      style: const TextStyle(color: Colors.green),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _userCtrl,
                        enabled: canPress,
                        decoration: const InputDecoration(
                          labelText: 'Usuario (o email)',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                        // ✅ Sin reglas de longitud
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return 'Ingresa un usuario';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _passCtrl,
                        enabled: canPress,
                        obscureText: _obscure,
                        decoration: InputDecoration(
                          labelText: 'Contraseña',
                          prefixIcon: const Icon(Icons.key_outlined),
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            onPressed: canPress
                                ? () => setState(() => _obscure = !_obscure)
                                : null,
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                            ),
                          ),
                        ),
                        // ✅ Sin reglas de longitud
                        validator: (v) {
                          if (v == null || v.isEmpty) {
                            return 'Ingresa una contraseña';
                          }
                          return null;
                        },
                        onFieldSubmitted: (_) =>
                            canPress ? _signup() : null,
                      ),
                      const SizedBox(height: 16),

                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton(
                          onPressed: canPress ? _signup : null,
                          child: _loading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Crear cuenta'),
                        ),
                      ),

                      const SizedBox(height: 12),

                      Text(
                        'Backend: http://$_backendHost:$_backendPort/api/$_apiVersion',
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'recover_password_screen.dart';
import 'package:esp32_wifi/screens/signup_screen.dart';
import 'dashboard_screen.dart';
import 'package:esp32_wifi/config/app_config.dart';

import 'package:esp32_wifi/services/session_store.dart';
import 'package:esp32_wifi/models/admin_models.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();

  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  bool _loading = false;
  bool _obscure = true;
  String? _error;

  

  Uri _url(String path) => Uri.parse('${AppConfig.apiUrl}$path');

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _goRecover(){
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const RecoverPasswordScreen()),
    );
  }
  void _goSignup(){
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const SignupScreen()),
    );
  }

  Future<void> _login() async {
    FocusScope.of(context).unfocus();
    setState(() => _error = null);

    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _loading = true);

    try {
      final username = _userCtrl.text.trim();
      final password = _passCtrl.text;

      // Backend route: POST /auth/login :contentReference[oaicite:7]{index=7}
      final res = await http
          .post(
            _url('/auth/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              "email": username, // Backend espera "email"
              "password": password,
            }),
          )
          .timeout(const Duration(seconds: 10));

      final bodyText = res.body;
      Map<String, dynamic>? json;
      try {
        final decoded = jsonDecode(bodyText);
        if (decoded is Map<String, dynamic>) json = decoded;
      } catch (_) {
        // no json
      }

      if (res.statusCode < 200 || res.statusCode >= 300) {
        final errMsg = json?['error']?.toString() ??
            json?['message']?.toString() ??
            'HTTP ${res.statusCode}: $bodyText';
        throw Exception(errMsg);
      }

      // Respuestas típicas:
      // { success: true, data: { token/accessToken/refreshToken, user... } }
      // o { token: '...' }
      final success = json?['success'];
      if (success == false) {
        throw Exception(json?['error']?.toString() ?? 'Login fallido');
      }

      // Intentar encontrar token en varios lugares
      final token = _extractToken(json);
      if (token == null || token.isEmpty) {
        throw Exception('Login OK pero no llegó token en la respuesta (revisar authController.login).');
      }

      // Guardar token local (Legacy/Simple)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('access_token', token);

      // (Opcional) guardar refresh token si viene
      final refresh = _extractRefreshToken(json);
      if (refresh != null && refresh.isNotEmpty) {
        await prefs.setString('refresh_token', refresh);
      }
      
      // Guardar sesión completa para AdminScreen
      final userData = json?['data']?['user'] ?? json?['user'];
      if (userData is Map<String, dynamic>) {
        try {
          final adminUser = AdminUser.fromJson(userData);
          await SessionStore.instance.save(SessionData(token: token, user: adminUser));
        } catch (e) {
          print('Error guardando SessionStore: $e');
        }
      }

      if (!mounted) return;

      setState(() => _loading = false);
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const DashboardScreen()),
      );

    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  String? _extractToken(Map<String, dynamic>? json) {
    if (json == null) return null;

    // Directo
    final direct = json['token'] ?? json['accessToken'] ?? json['access_token'];
    if (direct is String && direct.isNotEmpty) return direct;

    // Dentro de data
    final data = json['data'];
    if (data is Map<String, dynamic>) {
      final t = data['token'] ?? data['accessToken'] ?? data['access_token'];
      if (t is String && t.isNotEmpty) return t;
    }

    // Dentro de nested "tokens"
    final tokens = json['tokens'];
    if (tokens is Map<String, dynamic>) {
      final t = tokens['accessToken'] ?? tokens['token'];
      if (t is String && t.isNotEmpty) return t;
    }

    return null;
  }

  String? _extractRefreshToken(Map<String, dynamic>? json) {
    if (json == null) return null;

    final direct = json['refreshToken'] ?? json['refresh_token'];
    if (direct is String && direct.isNotEmpty) return direct;

    final data = json['data'];
    if (data is Map<String, dynamic>) {
      final t = data['refreshToken'] ?? data['refresh_token'];
      if (t is String && t.isNotEmpty) return t;
    }

    final tokens = json['tokens'];
    if (tokens is Map<String, dynamic>) {
      final t = tokens['refreshToken'];
      if (t is String && t.isNotEmpty) return t;
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final canPress = !_loading;

    return Scaffold(
      appBar: AppBar(title: const Text('Login')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock_outline, size: 64),
                const SizedBox(height: 12),
                const Text('Iniciar sesión', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
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
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Ingresa tu usuario' : null,
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
                            onPressed: canPress ? () => setState(() => _obscure = !_obscure) : null,
                            icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                          ),
                        ),
                        validator: (v) => (v == null || v.isEmpty) ? 'Ingresa tu contraseña' : null,
                        onFieldSubmitted: (_) => canPress ? _login() : null,
                      ),
                      const SizedBox(height: 16),

                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton(
                          onPressed: canPress ? _login : null,
                          child: _loading
                              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('Entrar'),
                        ),
                      ),

                      const SizedBox(height: 10),

                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _loading ? null : _goRecover,
                          child: const Text('¿Olvidaste tu contraseña?'),
                        ),
                      ),

                      const SizedBox(height: 6),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('¿No tienes cuenta? '),
                          TextButton(
                            onPressed: _loading ? null : _goSignup,
                            child: const Text('Crea cuenta'),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),

                      Text(
                        'Backend: ${AppConfig.backendBaseUrl}',
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

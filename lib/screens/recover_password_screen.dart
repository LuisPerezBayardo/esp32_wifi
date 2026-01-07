import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class RecoverPasswordScreen extends StatefulWidget {
  const RecoverPasswordScreen({super.key});

  @override
  State<RecoverPasswordScreen> createState() => _RecoverPasswordScreenState();
}

class _RecoverPasswordScreenState extends State<RecoverPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();

  bool _loading = false;
  String? _error;
  String? _success;

  // =============================
  // CONFIG QUE DEBE COINCIDIR
  // =============================
  // Backend: corre en 3000 y usa /api/v1 :contentReference[oaicite:3]{index=3}
  // Ajusta host según tu entorno:
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
    _emailCtrl.dispose();
    super.dispose();
  }

  bool _isValidEmail(String v) {
    // Validación simple (suficiente para UI)
    final s = v.trim();
    return s.contains('@') && s.contains('.');
  }

  Future<void> _sendRecoveryEmail() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _error = null;
      _success = null;
    });

    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _loading = true);

    try {
      final email = _emailCtrl.text.trim().toLowerCase();

      // ✅ Endpoint que debes tener en backend:
      // POST /api/v1/auth/forgot-password
      //
      // Body:
      // { "email": "..." }
      final res = await http
          .post(
            _url('/auth/forgot-password'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({"email": email}),
          )
          .timeout(const Duration(seconds: 10));

      final bodyText = res.body;
      Map<String, dynamic>? json;
      try {
        final decoded = jsonDecode(bodyText);
        if (decoded is Map<String, dynamic>) json = decoded;
      } catch (_) {}

      // Si el backend aún no implementa la ruta, aquí te saldrá 404.
      if (res.statusCode == 404) {
        throw Exception(
          'El backend no tiene /auth/forgot-password todavía (falta implementar).',
        );
      }

      if (res.statusCode < 200 || res.statusCode >= 300) {
        final errMsg = json?['error']?.toString() ??
            json?['message']?.toString() ??
            'HTTP ${res.statusCode}: $bodyText';
        throw Exception(errMsg);
      }

      // Buena práctica: aunque el email no exista, no revelar eso.
      // Muchos backends responden { success: true, message: "If account exists..." }
      final ok = (json?['success'] == true) || res.statusCode == 200;

      if (!ok) {
        throw Exception(json?['error']?.toString() ?? 'No se pudo procesar la solicitud');
      }

      if (!mounted) return;

      setState(() {
        _loading = false;
        _success =
            'Si el correo está registrado, te enviamos instrucciones para restablecer tu contraseña.';
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
        title: const Text('Recuperar contraseña'),
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
                const Icon(Icons.mark_email_read_outlined, size: 64),
                const SizedBox(height: 12),
                const Text(
                  'Recupera tu contraseña',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Escribe tu correo. Si está registrado, te enviaremos un enlace o código para restablecer la contraseña.',
                  textAlign: TextAlign.center,
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
                    child: Text(_success!, style: const TextStyle(color: Colors.green)),
                  ),
                  const SizedBox(height: 12),
                ],

                Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _emailCtrl,
                        enabled: canPress,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Correo',
                          prefixIcon: Icon(Icons.alternate_email),
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return 'Ingresa tu correo';
                          }
                          if (!_isValidEmail(v)) {
                            return 'Correo inválido';
                          }
                          return null;
                        },
                        onFieldSubmitted: (_) =>
                            canPress ? _sendRecoveryEmail() : null,
                      ),
                      const SizedBox(height: 16),

                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton(
                          onPressed: canPress ? _sendRecoveryEmail : null,
                          child: _loading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Enviar instrucciones'),
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
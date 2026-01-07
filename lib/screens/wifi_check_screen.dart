import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:app_settings/app_settings.dart';

import 'package:esp32_wifi/screens/login_screen.dart';






class WifiCheckScreen extends StatefulWidget {
  const WifiCheckScreen({super.key});

  @override
  State<WifiCheckScreen> createState() => _WifiCheckScreenState();
}

class _WifiCheckScreenState extends State<WifiCheckScreen> {
  late StreamSubscription _subscription;

  @override
  void initState() {
    super.initState();
    _checkWifi();

    // Escucha cambios en conectividad
    _subscription =
        Connectivity().onConnectivityChanged.listen((result) {
      if (result == ConnectivityResult.wifi) {
        _goToLogin();
      }
    });
  }

  Future<void> _checkWifi() async {
    final result = await Connectivity().checkConnectivity();
    if (result == ConnectivityResult.wifi) {
      _goToLogin();
    }
  }

  void _goToLogin() {
    if (!mounted) return;

    _subscription.cancel();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Conexión requerida')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.wifi_off, size: 80),
            const SizedBox(height: 20),
            const Text(
              'Activa el Wi-Fi para continuar',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20),
            ),
            const SizedBox(height: 30),
            ElevatedButton.icon(
              onPressed: () {
                AppSettings.openAppSettings(type: AppSettingsType.wifi);
              },
              icon: const Icon(Icons.settings),
              label: const Text('Abrir ajustes Wi-Fi'),
            ),
          ],
        ),
      ),
    );
  }
}
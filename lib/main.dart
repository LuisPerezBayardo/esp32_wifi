import 'package:flutter/material.dart';

import 'package:esp32_wifi/screens/splash_screen.dart';
import 'screens/login_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/preferences_screen.dart';
import 'screens/device_detail_screen.dart';
import 'screens/admin_screen.dart';
import 'screens/wifi_scan_screen.dart';




void main() {
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'IoT App',
      theme: ThemeData.dark(),
      home: const SplashScreen(),

      routes: {
        '/login': (_) => const LoginScreen(),
        '/home': (_) => const DashboardScreen(),

        '/profile': (_) => const ProfileScreen(),
        '/preferences': (_) => const PreferencesScreen(),

        '/device_detail': (_) => const DeviceDetailScreen(),
        '/admin': (_) => const AdminScreen(),
        '/wifi_scans': (_) => const WifiScanScreen(),
      },
    );
  }
}
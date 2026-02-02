class AppConfig {
  static const String mqttHost = '192.168.1.75'; // <-- IP/host del broker
  static const int mqttPort = 1883;              // <-- puerto
  static const String mqttUsername = '';         // <-- si aplica
  static const String mqttPassword = '';         // <-- si aplica

  static const String plantId= '1';              // NO SE DEFINIÓ, YO LO PUSE

  // Base de topics (tu “namespace”)
  static const String mqttBaseTopic = 'iot-industrial/app';

  // =======================================================
  // BACKEND HTTP
  // =======================================================
  // Ajusta el host según tu entorno:
  // - Android Emulator: 10.0.2.2
  // - Celular físico: IP de tu PC (ej: 192.168.1.50)
  
  static const String backendHost = '192.168.1.75'; // <--- CAMBIAR ESTO POR LA IP DEL SERVIDOR
  //static const String backendHost = '10.0.2.2'; // <--- (Emulator Android)
  static const int backendPort = 3000;
  static const String apiVersion = 'v1';

  static String get backendBaseUrl => 'http://$backendHost:$backendPort';
  static String get apiUrl => '$backendBaseUrl/api/$apiVersion';
  
  // Keys para SharedPreferences
  static const String spAccessTokenKey = 'access_token';
  static const String spRefreshTokenKey = 'refresh_token';
  static const String spCanControlActuatorsKey = 'canControlActuators';
}
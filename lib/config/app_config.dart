class AppConfig {
  static const String mqttHost = '192.168.1.50'; // <-- IP/host del broker
  static const int mqttPort = 1883;              // <-- puerto
  static const String mqttUsername = '';         // <-- si aplica
  static const String mqttPassword = '';         // <-- si aplica

  // Base de topics (tu “namespace”)
  static const String mqttBaseTopic = 'iot-industrial/app';
}
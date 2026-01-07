import 'dart:async';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class MqttMessageEvent {
  final String topic;
  final String payload;
  MqttMessageEvent({required this.topic, required this.payload});
}

/// Servicio singleton: conecta una vez y se reutiliza en toda la app.
class MqttService {
  MqttService._();
  static final MqttService instance = MqttService._();

  MqttServerClient? _client;
  String? clientId;

  final _messagesCtrl = StreamController<MqttMessageEvent>.broadcast();
  Stream<MqttMessageEvent> get messagesStream => _messagesCtrl.stream;

  bool get isConnected =>
      _client?.connectionStatus?.state == MqttConnectionState.connected;

  Future<void> connect({
    required String host,
    required int port,
    required String clientId,
    String? username,
    String? password,
    bool cleanSession = true,
  }) async {
    this.clientId = clientId;

    final c = MqttServerClient(host, clientId);
    c.port = port;
    c.keepAlivePeriod = 20;
    c.logging(on: false);

    c.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean()
        .withWillTopic('clients/$clientId/status')
        .withWillMessage('offline')
        .withWillQos(MqttQos.atLeastOnce);

    _client = c;

    try {
      await c.connect(username, password);
    } catch (e) {
      c.disconnect();
      rethrow;
    }

    final status = c.connectionStatus;
    if (status == null || status.state != MqttConnectionState.connected) {
      throw Exception('MQTT no conectado: ${status?.state}');
    }

    // Escuchar mensajes entrantes
    c.updates?.listen((events) {
      if (events.isEmpty) return;
      final e = events.first;
      final rec = e.payload as MqttPublishMessage;
      final payload = MqttPublishPayload.bytesToStringAsString(rec.payload.message);
      _messagesCtrl.add(MqttMessageEvent(topic: e.topic, payload: payload));
    });

    // Presencia online
    publish('clients/$clientId/status', 'online', qos: MqttQos.atLeastOnce);
  }

  void subscribe(String topic, {MqttQos qos = MqttQos.atMostOnce}) {
    if (_client == null) throw Exception('MQTT client no inicializado');
    _client!.subscribe(topic, qos);
  }

  void publish(String topic, String payload, {MqttQos qos = MqttQos.atMostOnce}) {
    if (_client == null) throw Exception('MQTT client no inicializado');
    final builder = MqttClientPayloadBuilder()..addString(payload);
    _client!.publishMessage(topic, qos, builder.payload!);
  }

  void disconnect() {
    if (isConnected && clientId != null) {
      publish('clients/$clientId/status', 'offline', qos: MqttQos.atLeastOnce);
    }
    _client?.disconnect();
  }

  void dispose() {
    _messagesCtrl.close();
  }
}
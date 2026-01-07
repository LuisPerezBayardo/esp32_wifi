import 'dart:async';
import 'dart:convert';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

typedef TopicBuilder = String Function(String clientId);

class MqttRpcClient {
  MqttRpcClient({
    required this.brokerHost,
    required this.brokerPort,
    required this.clientIdPrefix,
    required this.requestTopicBuilder,
    required this.responseTopicBuilder,
    this.username,
    this.password,
  });

  final String brokerHost;
  final int brokerPort;
  final String clientIdPrefix;
  final String? username;
  final String? password;
  final TopicBuilder requestTopicBuilder;
  final TopicBuilder responseTopicBuilder;

  MqttServerClient? _client;
  String? _clientId;

  final _pending = <String, Completer<Map<String, dynamic>>>{};
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _sub;

  bool get isConnected => _client?.connectionStatus?.state == MqttConnectionState.connected;

  Future<void> connect() async {
    if (isConnected) return;

    final clientId = '${clientIdPrefix}_${DateTime.now().millisecondsSinceEpoch}';
    _clientId = clientId;

    final c = MqttServerClient(brokerHost, clientId);
    _client = c;

    c.port = brokerPort;
    c.keepAlivePeriod = 30;
    c.logging(on: false);
    c.onDisconnected = () {};
    c.onConnected = () {};
    c.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);

    if (username != null && username!.isNotEmpty) {
      c.connectionMessage = c.connectionMessage!.authenticateAs(username!, password ?? '');
    }

    await c.connect();

    if (c.connectionStatus?.state != MqttConnectionState.connected) {
      throw Exception('MQTT no conectado: ${c.connectionStatus}');
    }

    // Suscribirse al response topic
    final respTopic = responseTopicBuilder(clientId);
    c.subscribe(respTopic, MqttQos.atLeastOnce);

    _sub = c.updates?.listen((messages) {
      for (final m in messages) {
        final payload = m.payload as MqttPublishMessage;
        final raw = MqttPublishPayload.bytesToStringAsString(payload.payload.message);

        Map<String, dynamic> decoded;
        try {
          decoded = jsonDecode(raw);
        } catch (_) {
          continue;
        }

        final corr = decoded['correlationId']?.toString();
        if (corr != null && _pending.containsKey(corr)) {
          _pending.remove(corr)!.complete(decoded);
        }
      }
    });
  }

  Future<Map<String, dynamic>> requestJson({
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!isConnected) {
      await connect();
    }

    final corr = DateTime.now().microsecondsSinceEpoch.toString();
    final clientId = _clientId!;
    final reqTopic = requestTopicBuilder(clientId);

    final msg = {
      "correlationId": corr,
      "timestamp": DateTime.now().toIso8601String(),
      ...payload,
    };

    final c = Completer<Map<String, dynamic>>();
    _pending[corr] = c;

    final b = MqttClientPayloadBuilder();
    b.addString(jsonEncode(msg));

    _client!.publishMessage(reqTopic, MqttQos.atLeastOnce, b.payload!);

    try {
      return await c.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(corr);
      throw Exception('Timeout esperando respuesta MQTT (type=${payload["type"]})');
    }
  }

  void dispose() {
    _sub?.cancel();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(Exception('Disposed'));
    }
    _pending.clear();
    _client?.disconnect();
  }
}

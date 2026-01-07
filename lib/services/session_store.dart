import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/admin_models.dart';

class SessionData {
  final String token;
  final AdminUser user;

  SessionData({required this.token, required this.user});

  Map<String, dynamic> toJson() => {"token": token, "user": user.toJson()};
  factory SessionData.fromJson(Map<String, dynamic> j) =>
      SessionData(token: j["token"], user: AdminUser.fromJson(Map<String, dynamic>.from(j["user"])));
}

class SessionStore {
  SessionStore._();
  static final instance = SessionStore._();

  static const _k = 'session_data_v1';

  Future<void> save(SessionData data) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_k, jsonEncode(data.toJson()));
  }

  Future<SessionData?> read() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_k);
    if (raw == null) return null;
    return SessionData.fromJson(jsonDecode(raw));
  }

  Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_k);
  }
}

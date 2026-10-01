import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NotificacaoService {
  static const _canal = MethodChannel('ao_ponto/alerta');
  static bool get suportado =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> inicializar() async {
    if (!suportado) return;
    await Firebase.initializeApp();
    await FirebaseMessaging.instance.setAutoInitEnabled(true);
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  static Future<String?> obterToken() async {
    if (!suportado) return null;
    return FirebaseMessaging.instance.getToken();
  }

  static Stream<String> get tokens => suportado
      ? FirebaseMessaging.instance.onTokenRefresh
      : const Stream.empty();

  static Future<void> pararAlerta() async {
    if (suportado) await _canal.invokeMethod<void>('parar');
  }
}

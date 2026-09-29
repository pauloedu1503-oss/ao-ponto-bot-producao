import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AtualizacaoService {
  AtualizacaoService._();

  static const _canal = MethodChannel('ao_ponto/atualizacao');

  static bool get suportado =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<int> buildInstalado() async {
    if (!suportado) return 0;
    return await _canal.invokeMethod<int>('buildInstalado') ?? 0;
  }

  static Future<void> instalar(String url) async {
    if (!suportado) return;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException('Endereço da atualização inválido.');
    }
    await _canal.invokeMethod<void>('instalar', {'url': url});
  }
}

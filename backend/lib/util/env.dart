import 'dart:io';

class Env {
  Env._();

  static final Map<String, String> _values = {};

  static void carregar([String caminho = '.env']) {
    _values.clear();
    final file = File(caminho);
    if (!file.existsSync()) return;

    for (final linhaOriginal in file.readAsLinesSync()) {
      final linha = linhaOriginal.trim();
      if (linha.isEmpty || linha.startsWith('#')) continue;
      final idx = linha.indexOf('=');
      if (idx <= 0) continue;
      final chave = linha.substring(0, idx).trim();
      var valor = linha.substring(idx + 1).trim();
      if ((valor.startsWith('"') && valor.endsWith('"')) ||
          (valor.startsWith("'") && valor.endsWith("'"))) {
        valor = valor.substring(1, valor.length - 1);
      }
      _values[chave] = valor;
    }
  }

  static String get(String chave, {String padrao = ''}) {
    return _values[chave] ?? Platform.environment[chave] ?? padrao;
  }

  static int getInt(String chave, {required int padrao}) {
    return int.tryParse(get(chave)) ?? padrao;
  }

  static bool getBool(String chave, {required bool padrao}) {
    final valor = get(chave).toLowerCase();
    if (valor == 'true' || valor == '1' || valor == 'yes') return true;
    if (valor == 'false' || valor == '0' || valor == 'no') return false;
    return padrao;
  }
}

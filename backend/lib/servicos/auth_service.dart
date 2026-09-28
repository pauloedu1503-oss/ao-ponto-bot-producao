import 'dart:convert';
import 'dart:math';

import '../util/env.dart';
import '../banco/banco.dart';

enum LoginStatus { sucesso, senhaInvalida, muitasTentativas }

class LoginResult {
  final LoginStatus status;
  final String? token;
  final int tentativasRestantes;
  final int aguardeSegundos;

  const LoginResult._(
    this.status, {
    this.token,
    this.tentativasRestantes = 0,
    this.aguardeSegundos = 0,
  });

  const LoginResult.sucesso(String token)
      : this._(LoginStatus.sucesso, token: token);

  const LoginResult.senhaInvalida(int tentativasRestantes)
      : this._(
          LoginStatus.senhaInvalida,
          tentativasRestantes: tentativasRestantes,
        );

  const LoginResult.muitasTentativas(int aguardeSegundos)
      : this._(
          LoginStatus.muitasTentativas,
          aguardeSegundos: aguardeSegundos,
        );
}

class AuthService {
  static const int _maxFalhasPorJanela = 8;
  static const Duration _janelaFalhas = Duration(minutes: 1);

  final Map<String, DateTime> _tokens = {};
  final Map<String, List<DateTime>> _falhas = {};
  final Banco? banco;

  AuthService([this.banco]);

  LoginResult login(String senha, String origem) {
    _limpar();

    final agora = DateTime.now();

    final falhas = _falhas.putIfAbsent(origem, () => []);

    falhas.removeWhere(
      (data) => agora.difference(data) >= _janelaFalhas,
    );

    final senhaCorreta = Env.get(
      'ADMIN_PASSWORD',
      padrao: '',
    );

    // Somente senha errada entra no limite.
    if (falhas.length >= _maxFalhasPorJanela) {
      final maisAntiga = falhas.first;

      final decorrido = agora.difference(maisAntiga);

      var restante = _janelaFalhas - decorrido;

      if (restante.isNegative) {
        restante = Duration.zero;
      }

      final segundos = restante.inSeconds <= 0 ? 1 : restante.inSeconds + 1;

      return LoginResult.muitasTentativas(segundos);
    }

    // Senha correta entra normalmente, mesmo que existam
    // tentativas erradas anteriores.
    if (senhaCorreta.isNotEmpty &&
        senhaCorreta != 'troque-esta-senha' &&
        senha == senhaCorreta) {
      _falhas.remove(origem);

      final random = Random.secure();

      final bytes = List<int>.generate(
        32,
        (_) => random.nextInt(256),
      );

      final token = base64UrlEncode(bytes).replaceAll('=', '');

      final expira = agora.add(const Duration(days: 30));
      _tokens[token] = expira;
      banco?.db.execute(
        'INSERT OR REPLACE INTO auth_tokens(token, expira_em) VALUES (?, ?)',
        [token, expira.toIso8601String()],
      );

      return LoginResult.sucesso(token);
    }

    falhas.add(agora);

    final restantes = _maxFalhasPorJanela - falhas.length;

    return LoginResult.senhaInvalida(
      restantes < 0 ? 0 : restantes,
    );
  }

  bool valido(String? token) {
    if (token == null || token.isEmpty) {
      return false;
    }

    var expira = _tokens[token];
    if (expira == null && banco != null) {
      final rows = banco!.db.select(
        'SELECT expira_em FROM auth_tokens WHERE token = ? LIMIT 1',
        [token],
      );
      if (rows.isNotEmpty) {
        expira = DateTime.tryParse(rows.first['expira_em'] as String);
        if (expira != null) _tokens[token] = expira;
      }
    }

    if (expira == null) {
      return false;
    }

    if (DateTime.now().isAfter(expira)) {
      _tokens.remove(token);
      banco?.db.execute('DELETE FROM auth_tokens WHERE token = ?', [token]);
      return false;
    }

    return true;
  }

  void logout(String token) {
    _tokens.remove(token);
    banco?.db.execute('DELETE FROM auth_tokens WHERE token = ?', [token]);
  }

  void _limpar() {
    final agora = DateTime.now();

    _tokens.removeWhere(
      (_, expira) => agora.isAfter(expira),
    );
    banco?.db.execute(
      'DELETE FROM auth_tokens WHERE expira_em < ?',
      [agora.toIso8601String()],
    );

    for (final item in _falhas.entries.toList()) {
      item.value.removeWhere(
        (data) => agora.difference(data) >= _janelaFalhas,
      );

      if (item.value.isEmpty) {
        _falhas.remove(item.key);
      }
    }
  }
}

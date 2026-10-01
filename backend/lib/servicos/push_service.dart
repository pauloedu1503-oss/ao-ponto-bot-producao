import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';

import '../banco/banco.dart';
import '../util/data_hora.dart';
import '../util/env.dart';

class PushService {
  final Banco banco;
  AutoRefreshingAuthClient? _client;
  bool _enviando = false;

  PushService(this.banco);

  String get _caminhoCredencial => Env.get(
        'FIREBASE_SERVICE_ACCOUNT',
        padrao: 'firebase-service-account.json',
      );

  bool get configurado =>
      Env.get('FIREBASE_SERVICE_ACCOUNT_JSON').trim().isNotEmpty ||
      File(_caminhoCredencial).existsSync();

  void registrarToken(String token) {
    final limpo = token.trim();
    if (limpo.length < 20 || limpo.length > 4096) {
      throw const FormatException('Token de notificação inválido.');
    }
    banco.db.execute('''
      INSERT INTO push_tokens(token, atualizado_em) VALUES (?, ?)
      ON CONFLICT(token) DO UPDATE SET atualizado_em = excluded.atualizado_em
    ''', [limpo, agoraIso()]);
  }

  Future<AutoRefreshingAuthClient> _cliente() async {
    if (_client != null) return _client!;
    final jsonEmVariavel = Env.get('FIREBASE_SERVICE_ACCOUNT_JSON').trim();
    final json = jsonDecode(jsonEmVariavel.isNotEmpty
        ? jsonEmVariavel
        : File(_caminhoCredencial).readAsStringSync()) as Map<String, dynamic>;
    return _client = await clientViaServiceAccount(
      ServiceAccountCredentials.fromJson(json),
      const ['https://www.googleapis.com/auth/firebase.messaging'],
    );
  }

  Future<void> drenar() async {
    if (_enviando || !configurado) return;
    final tokens = banco.db.select('SELECT token FROM push_tokens');
    if (tokens.isEmpty) return;
    final agora = DateTime.now().toUtc();
    final alertas = <Map<String, dynamic>>[];

    for (final row in banco.db.select('''
      SELECT s.pedido_id, s.titulo, s.corpo, s.ultimo_envio_em
      FROM push_saida s
      JOIN pedidos p ON p.id = s.pedido_id
      WHERE s.status = 'pendente' AND p.status = 'novo'
    ''')) {
      final ultimo =
          DateTime.tryParse(row['ultimo_envio_em']?.toString() ?? '');
      if (ultimo == null || agora.difference(ultimo).inSeconds >= 60) {
        alertas.add({
          'tipo': 'novo_pedido',
          'referencia': row['pedido_id'].toString(),
          'titulo': row['titulo'],
          'corpo': row['corpo'],
          'duracao': '30',
        });
      }
    }

    for (final row in banco.db.select('''
      SELECT telefone, titulo, corpo, ultimo_envio_em
      FROM push_humano WHERE ativo = 1
    ''')) {
      final ultimo =
          DateTime.tryParse(row['ultimo_envio_em']?.toString() ?? '');
      if (ultimo == null || agora.difference(ultimo).inSeconds >= 30) {
        alertas.add({
          'tipo': 'atendente',
          'referencia': row['telefone'],
          'titulo': row['titulo'],
          'corpo': row['corpo'],
          'duracao': '15',
        });
      }
    }

    if (alertas.isEmpty) return;
    _enviando = true;
    try {
      final jsonEmVariavel = Env.get('FIREBASE_SERVICE_ACCOUNT_JSON').trim();
      final credencial = jsonDecode(jsonEmVariavel.isNotEmpty
              ? jsonEmVariavel
              : File(_caminhoCredencial).readAsStringSync())
          as Map<String, dynamic>;
      final projeto = credencial['project_id']?.toString() ?? '';
      if (projeto.isEmpty) throw StateError('project_id ausente no Firebase.');
      final client = await _cliente();

      for (final alerta in alertas) {
        var enviado = false;
        String? erro;
        for (final row in tokens) {
          final token = row['token'] as String;
          try {
            final resposta = await client.post(
              Uri.parse(
                  'https://fcm.googleapis.com/v1/projects/$projeto/messages:send'),
              headers: {'content-type': 'application/json'},
              body: jsonEncode({
                'message': {
                  'token': token,
                  'data': {
                    'tipo': alerta['tipo'],
                    'referencia': alerta['referencia'],
                    'titulo': alerta['titulo'],
                    'corpo': alerta['corpo'],
                    'duracaoSegundos': alerta['duracao'],
                  },
                  'android': {'priority': 'HIGH'},
                },
              }),
            );
            if (resposta.statusCode >= 200 && resposta.statusCode < 300) {
              enviado = true;
            } else {
              erro = 'FCM HTTP ${resposta.statusCode}';
              if (resposta.statusCode == 400 || resposta.statusCode == 404) {
                banco.db
                    .execute('DELETE FROM push_tokens WHERE token=?', [token]);
              }
            }
          } catch (e) {
            erro = e.runtimeType.toString();
          }
        }

        if (alerta['tipo'] == 'novo_pedido') {
          banco.db.execute('''
            UPDATE push_saida
            SET ultimo_envio_em=?, tentativas=tentativas+1, erro=?
            WHERE pedido_id=?
          ''', [
            enviado ? agoraIso() : null,
            erro,
            int.parse(alerta['referencia'])
          ]);
        } else {
          banco.db.execute('''
            UPDATE push_humano
            SET ultimo_envio_em=?, tentativas=tentativas+1
            WHERE telefone=?
          ''', [enviado ? agoraIso() : null, alerta['referencia']]);
        }
      }
    } finally {
      _enviando = false;
    }
  }

  void fechar() => _client?.close();
}

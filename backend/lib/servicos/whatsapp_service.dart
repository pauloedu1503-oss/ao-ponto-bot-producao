import 'dart:math';
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../banco/banco.dart';
import '../util/env.dart';

class WhatsAppService {
  final Banco banco;
  final http.Client _client;
  final List<Map<String, dynamic>> _mensagensSimuladas = [];

  WhatsAppService(this.banco, {http.Client? client})
      : _client = client ?? http.Client();

  String get _token => Env.get('WHATSAPP_ACCESS_TOKEN');
  String get _phoneNumberId => Env.get('WHATSAPP_PHONE_NUMBER_ID');
  String get _graphVersion => Env.get('META_GRAPH_VERSION', padrao: 'v26.0');

  bool get bridgeAtivo {
    final valor = Env.get('WHATSAPP_BRIDGE_ENABLED').trim().toLowerCase();

    return const {
      '1',
      'true',
      'sim',
      'yes',
      'on',
    }.contains(valor);
  }

  bool get configurado =>
      _token.trim().isNotEmpty && _phoneNumberId.trim().isNotEmpty;

  bool get metaAtiva => configurado && !bridgeAtivo;

  bool get disponivel => bridgeAtivo || metaAtiva;

  List<Map<String, dynamic>> consumirMensagensSimuladas() {
    final copia = List<Map<String, dynamic>>.from(_mensagensSimuladas);
    _mensagensSimuladas.clear();
    return copia;
  }

  Uri get _messagesUri => Uri.parse(
        'https://graph.facebook.com/$_graphVersion/$_phoneNumberId/messages',
      );

  Future<void> enviarTexto(String telefone, String texto) async {
    final caracteres = texto.runes.toList();
    for (var inicio = 0; inicio < caracteres.length; inicio += 4000) {
      final fim = (inicio + 4000).clamp(0, caracteres.length);
      await _enviar({
        'messaging_product': 'whatsapp',
        'to': telefone,
        'type': 'text',
        'text': {
          'preview_url': false,
          'body': String.fromCharCodes(caracteres.sublist(inicio, fim))
        }
      });
    }
  }

  Future<void> enviarBotoes(
    String telefone,
    String texto,
    List<Map<String, String>> botoes,
  ) async {
    if (texto.runes.length > 1024 || botoes.isEmpty || botoes.length > 3) {
      await enviarTexto(telefone, _textoNumerado(texto, botoes));
      return;
    }
    final originais = botoes;
    if (botoes.any((b) => (b['titulo'] ?? '').runes.length > 20)) {
      texto = _textoNumerado(texto, botoes);
      if (texto.runes.length > 1024) {
        await enviarTexto(telefone, texto);
        return;
      }
      botoes = [
        for (var i = 0; i < originais.length; i++)
          {...originais[i], 'titulo': '${i + 1}'}
      ];
    }
    botoes = _identificarOpcoes(telefone, botoes);
    await _enviar({
      'messaging_product': 'whatsapp',
      'to': telefone,
      'type': 'interactive',
      'interactive': {
        'type': 'button',
        'body': {'text': texto},
        'action': {
          'buttons': botoes
              .map((b) => {
                    'type': 'reply',
                    'reply': {
                      'id': b['id'] ?? '',
                      'title': _limitar(b['titulo'] ?? '', 20),
                    }
                  })
              .toList(),
        }
      }
    });
  }

  Future<void> enviarLista(
    String telefone, {
    required String texto,
    required String tituloBotao,
    required List<Map<String, String>> opcoes,
  }) async {
    if (opcoes.isEmpty) {
      await enviarTexto(telefone, texto);
      return;
    }
    // A lista interativa do WhatsApp tem limite de linhas por seção.
    // Se o cardápio passar disso, não escondemos opções: enviamos texto numerado.
    if (texto.runes.length > 1024 || opcoes.length > 10) {
      await enviarTexto(telefone, _textoNumerado(texto, opcoes));
      return;
    }
    final originais = opcoes;
    if (opcoes.any((o) => (o['titulo'] ?? '').runes.length > 24)) {
      texto = _textoNumerado(texto, opcoes);
      if (texto.runes.length > 1024) {
        await enviarTexto(telefone, texto);
        return;
      }
      opcoes = [
        for (var i = 0; i < originais.length; i++)
          {
            ...originais[i],
            'titulo': '${i + 1}',
            'descricao': [
              originais[i]['titulo'] ?? '',
              if ((originais[i]['descricao'] ?? '').isNotEmpty)
                originais[i]['descricao']!,
            ].join(' — '),
          }
      ];
    }
    opcoes = _identificarOpcoes(telefone, opcoes);
    final rows = opcoes.map((o) {
      return {
        'id': o['id'] ?? '',
        'title': _limitar(o['titulo'] ?? '', 24),
        if ((o['descricao'] ?? '').isNotEmpty)
          'description': _limitar(o['descricao'] ?? '', 72),
      };
    }).toList();

    await _enviar({
      'messaging_product': 'whatsapp',
      'to': telefone,
      'type': 'interactive',
      'interactive': {
        'type': 'list',
        'body': {'text': texto},
        'action': {
          'button': _limitar(tituloBotao, 20),
          'sections': [
            {'title': 'Opções', 'rows': rows}
          ]
        }
      }
    });
  }

  Future<void> marcarComoLida(String mensagemId) async {
    if (!configurado) return;
    try {
      await _enviar({
        'messaging_product': 'whatsapp',
        'status': 'read',
        'message_id': mensagemId,
      });
    } catch (_) {
      // Falha de marcação não deve quebrar o atendimento.
    }
  }

  Future<void> _enviar(Map<String, dynamic> payload) async {
    // Sem Meta e sem Baileys = simulador antigo.
    if (!configurado && !bridgeAtivo) {
      _mensagensSimuladas.add(
        Map<String, dynamic>.from(payload),
      );

      if (_mensagensSimuladas.length > 500) {
        _mensagensSimuladas.removeAt(0);
      }

      return;
    }

    // Meta e Baileys usam a mesma fila persistente,
    // mas cada um possui seu próprio canal.
    final canal = configurado ? 'meta' : 'bridge';

    banco.db.execute(
      '''
    INSERT INTO whatsapp_saida(
      payload,
      status,
      tentativas,
      criado_em,
      erro,
      canal
    )
    VALUES (?, 'pendente', 0, ?, NULL, ?)
    ''',
      [
        jsonEncode(payload),
        DateTime.now().toUtc().toIso8601String(),
        canal,
      ],
    );
  }

  List<Map<String, dynamic>> reservarProximaSaidaBridge() {
    if (!bridgeAtivo) {
      return const [];
    }
    recuperarEnviosBridgeInterrompidos();
    banco.db.execute('BEGIN IMMEDIATE');

    try {
      final rows = banco.db.select(
        '''
      SELECT id, payload
      FROM whatsapp_saida
      WHERE canal = 'bridge'
        AND status = 'pendente'
      ORDER BY id
      LIMIT 1
      ''',
      );

      if (rows.isEmpty) {
        banco.db.execute('COMMIT');
        return const [];
      }

      final row = rows.first;
      final id = row['id'] as int;

      banco.db.execute(
        '''
      UPDATE whatsapp_saida
      SET status = 'enviando',
          tentativas = tentativas + 1,
          erro = NULL
      WHERE id = ?
        AND canal = 'bridge'
        AND status = 'pendente'
      ''',
        [id],
      );

      if (banco.db.updatedRows != 1) {
        throw StateError(
          'A saída #$id foi alterada durante a reserva.',
        );
      }

      final payload = Map<String, dynamic>.from(
        jsonDecode(row['payload'] as String) as Map,
      );

      banco.db.execute('COMMIT');

      return [
        {
          'id': id,
          'payload': payload,
        }
      ];
    } catch (_) {
      banco.db.execute('ROLLBACK');
      rethrow;
    }
  }

  void concluirSaidaBridge(int id) {
    banco.db.execute(
      '''
    UPDATE whatsapp_saida
    SET status = 'enviado',
        erro = NULL
    WHERE id = ?
      AND canal = 'bridge'
      AND status = 'enviando'
    ''',
      [id],
    );

    if (banco.db.updatedRows != 1) {
      throw StateError(
        'Não foi possível confirmar a saída #$id.',
      );
    }
  }

  void marcarSaidaBridgeIncerta(
    int id,
    String erro,
  ) {
    final detalhe = erro.length > 500 ? erro.substring(0, 500) : erro;

    banco.db.execute(
      '''
    UPDATE whatsapp_saida
    SET status = 'incerto',
        erro = ?
    WHERE id = ?
      AND canal = 'bridge'
      AND status = 'enviando'
    ''',
      [
        detalhe,
        id,
      ],
    );

    banco.log(
      'WARN',
      'bridge_envio_incerto',
      '#$id: $detalhe',
    );
  }

  List<Map<String, dynamic>> listarFilaBridge({
    int limite = 100,
  }) {
    final limiteSeguro = limite.clamp(1, 200);

    final rows = banco.db.select(
      '''
    SELECT
      id,
      payload,
      status,
      tentativas,
      criado_em,
      erro,
      canal
    FROM whatsapp_saida
    WHERE canal = 'bridge'
    ORDER BY id DESC
    LIMIT ?
    ''',
      [limiteSeguro],
    );

    return rows.map((row) {
      Map<String, dynamic> payload = {};

      try {
        payload = Map<String, dynamic>.from(
          jsonDecode(row['payload'] as String) as Map,
        );
      } catch (_) {}

      return {
        'id': row['id'],
        'status': row['status'],
        'tentativas': row['tentativas'],
        'criadoEm': row['criado_em'],
        'erro': row['erro'],
        'telefone': payload['to']?.toString(),
        'tipo': payload['type']?.toString(),
        'payload': payload,
      };
    }).toList();
  }

  Map<String, int> resumoFilaBridge() {
    final rows = banco.db.select(
      '''
    SELECT status, COUNT(*) AS total
    FROM whatsapp_saida
    WHERE canal = 'bridge'
    GROUP BY status
    ''',
    );

    final resultado = <String, int>{
      'pendente': 0,
      'enviando': 0,
      'incerto': 0,
      'enviado': 0,
      'descartado': 0,
    };

    for (final row in rows) {
      final status = row['status']?.toString() ?? '';
      final total = (row['total'] as int?) ?? 0;

      resultado[status] = total;
    }

    return resultado;
  }

  void resolverSaidaBridge(
    int id,
    String acao,
  ) {
    final rows = banco.db.select(
      '''
    SELECT status
    FROM whatsapp_saida
    WHERE id = ?
      AND canal = 'bridge'
    LIMIT 1
    ''',
      [id],
    );

    if (rows.isEmpty) {
      throw StateError('Mensagem da fila não encontrada.');
    }

    final statusAtual = rows.first['status']?.toString() ?? '';

    switch (acao) {
      case 'marcar_enviado':
        if (statusAtual != 'incerto' && statusAtual != 'enviando') {
          throw StateError(
            'Somente mensagens incertas ou em envio podem ser marcadas como enviadas.',
          );
        }

        banco.db.execute(
          '''
        UPDATE whatsapp_saida
        SET status = 'enviado',
            erro = NULL
        WHERE id = ?
          AND canal = 'bridge'
        ''',
          [id],
        );
        break;

      case 'reenviar':
        if (statusAtual != 'incerto') {
          throw StateError(
            'Somente mensagens incertas podem ser reenviadas manualmente.',
          );
        }

        banco.db.execute(
          '''
        UPDATE whatsapp_saida
        SET status = 'pendente',
            erro = 'Reenvio manual autorizado pelo administrador'
        WHERE id = ?
          AND canal = 'bridge'
        ''',
          [id],
        );
        break;

      case 'descartar':
        if (statusAtual == 'enviado') {
          throw StateError(
            'Mensagem já enviada não pode ser descartada.',
          );
        }

        banco.db.execute(
          '''
        UPDATE whatsapp_saida
        SET status = 'descartado'
        WHERE id = ?
          AND canal = 'bridge'
        ''',
          [id],
        );
        break;

      default:
        throw ArgumentError(
          'Ação inválida para a fila.',
        );
    }

    banco.log(
      'INFO',
      'bridge_fila_resolvida',
      '#$id ação=$acao status_anterior=$statusAtual',
    );
  }

  void recuperarEnviosBridgeInterrompidos() {
    banco.db.execute(
      '''
    UPDATE whatsapp_saida
    SET status = 'incerto',
        erro = 'O envio foi interrompido antes da confirmação. Verifique antes de reenviar.'
    WHERE canal = 'bridge'
      AND status = 'enviando'
    ''',
    );
  }

  bool _enviando = false;
  Future<void> drenar() async {
    if (_enviando || !metaAtiva) return;
    _enviando = true;
    try {
      final rows = banco.db.select(
        "SELECT * FROM whatsapp_saida "
        "WHERE canal = 'meta' "
        "AND status NOT IN ('enviado','descartado') "
        "ORDER BY id LIMIT 50",
      );
      for (final row in rows) {
        if (row['status'] != 'pendente') break;
        banco.db.execute(
            "UPDATE whatsapp_saida SET status = 'enviando', tentativas = tentativas + 1 WHERE id = ?",
            [row['id']]);
        try {
          final response = await _client
              .post(_messagesUri,
                  headers: {
                    'authorization': 'Bearer $_token',
                    'content-type': 'application/json'
                  },
                  body: row['payload'] as String)
              .timeout(const Duration(seconds: 10));
          if (response.statusCode >= 200 && response.statusCode < 300) {
            banco.db.execute(
                "UPDATE whatsapp_saida SET status = 'enviado', erro = NULL WHERE id = ?",
                [row['id']]);
          } else {
            // Uma rejeição explícita pode ser retentada; timeouts são ambíguos.
            final temporario =
                response.statusCode == 429 && (row['tentativas'] as int) < 5;
            banco.db.execute(
                'UPDATE whatsapp_saida SET status = ?, erro = ? WHERE id = ?', [
              temporario ? 'pendente' : 'falhou',
              'HTTP ' + response.statusCode.toString(),
              row['id']
            ]);
            banco.log('ERROR', 'whatsapp_envio_falhou',
                'HTTP ' + response.statusCode.toString());
            break;
          }
        } catch (e) {
          banco.db.execute(
              "UPDATE whatsapp_saida SET status = 'incerto', erro = ? WHERE id = ?",
              [e.runtimeType.toString(), row['id']]);
          banco.log('ERROR', 'whatsapp_envio_incerto',
              'Confira a conversa antes de reenviar.');
          break;
        }
      }
    } finally {
      _enviando = false;
    }
  }

  void fechar() => _client.close();

  List<Map<String, String>> _identificarOpcoes(
      String telefone, List<Map<String, String>> opcoes) {
    final sessao = banco.obterSessao(telefone);
    if (sessao == null) return opcoes;
    final random = Random.secure();
    final nonce =
        base64UrlEncode(List.generate(12, (_) => random.nextInt(256)));
    final dados = Map<String, dynamic>.from(sessao['dados'] as Map)
      ..['promptId'] = nonce;
    banco.db.execute('UPDATE sessoes SET dados_json = ? WHERE telefone = ?',
        [jsonEncode(dados), telefone]);
    return opcoes
        .map((e) => {...e, 'id': nonce + '|' + (e['id'] ?? '')})
        .toList();
  }

  String _textoNumerado(String texto, List<Map<String, String>> opcoes) {
    final linhas = <String>[texto];
    for (var i = 0; i < opcoes.length; i++) {
      linhas.add('${i + 1} - ${opcoes[i]['titulo'] ?? ''}');
    }
    return linhas.join('\n');
  }

  String _limitar(String valor, int max) {
    return String.fromCharCodes(valor.runes.take(max));
  }
}

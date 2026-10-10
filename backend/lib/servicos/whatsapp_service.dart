import 'dart:math';
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../banco/banco.dart';
import '../util/env.dart';

class MidiaWhatsApp {
  final List<int> bytes;
  final String mimeType;
  const MidiaWhatsApp(this.bytes, this.mimeType);
}

class WhatsAppService {
  final Banco banco;
  final http.Client _client;
  final List<Map<String, dynamic>> _mensagensSimuladas = [];
  final Map<String, ({String texto, int repeticoes, bool encaminhado})>
      _ultimaRespostaPorTelefone = {};

  static const _avisoEncaminhamento =
      'Não consegui entender com segurança. Encaminhei a conversa para um atendente, que continuará o atendimento por aqui.';

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

  Future<MidiaWhatsApp?> baixarMidia(String mediaId, {String? mimeType}) async {
    if (!metaAtiva || mediaId.trim().isEmpty) return null;
    final metadata = await _client
        .get(
          Uri.parse('https://graph.facebook.com/$_graphVersion/$mediaId'),
          headers: {'authorization': 'Bearer $_token'},
        )
        .timeout(const Duration(seconds: 10));
    if (metadata.statusCode < 200 || metadata.statusCode >= 300) return null;
    final json = jsonDecode(metadata.body);
    final url = json is Map ? json['url']?.toString() : null;
    if (url == null || url.isEmpty) return null;
    final resposta = await _client
        .get(Uri.parse(url), headers: {'authorization': 'Bearer $_token'})
        .timeout(const Duration(seconds: 15));
    if (resposta.statusCode < 200 || resposta.statusCode >= 300) return null;
    final mime = resposta.headers['content-type']?.split(';').first.trim();
    return MidiaWhatsApp(
      resposta.bodyBytes,
      mime?.isNotEmpty == true ? mime! : (mimeType ?? 'application/octet-stream'),
    );
  }

  List<Map<String, dynamic>> consumirMensagensSimuladas() {
    final copia = List<Map<String, dynamic>>.from(_mensagensSimuladas);
    _mensagensSimuladas.clear();
    return copia;
  }

  Uri get _messagesUri => Uri.parse(
        'https://graph.facebook.com/$_graphVersion/$_phoneNumberId/messages',
      );

  Future<void> enviarTexto(String telefone, String texto) async {
    final resposta = _validarRepeticao(telefone, texto);
    if (resposta == null) return;
    texto = resposta;
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

  Future<void> enviarImagemCardapio(
      String telefone, List<int> bytes, String mimeType) async {
    const chaveRepeticao = '[imagem do cardápio]';
    final resposta = _validarRepeticao(telefone, chaveRepeticao);
    if (resposta == null) return;
    if (resposta != chaveRepeticao) {
      await _enviarTextoSemValidar(telefone, resposta);
      return;
    }
    await _enviar({
      'messaging_product': 'whatsapp',
      'to': telefone,
      'type': 'image',
      'image': {
        'data': base64Encode(bytes),
        'mimetype': mimeType,
      },
    });
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
    final resposta = _validarRepeticao(telefone, texto);
    if (resposta == null) return;
    if (resposta != texto) {
      await _enviarTextoSemValidar(telefone, resposta);
      return;
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
    final resposta = _validarRepeticao(telefone, texto);
    if (resposta == null) return;
    if (resposta != texto) {
      await _enviarTextoSemValidar(telefone, resposta);
      return;
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

  // Uma resposta idêntica pode ser repetida duas vezes. Na terceira ocorrência
  // consecutiva, a conversa é encaminhada para evitar que o cliente fique preso
  // em um loop. Respostas diferentes reiniciam a contagem.
  String? _validarRepeticao(String telefone, String texto) {
    final sessao = banco.obterSessao(telefone);
    final dados = Map<String, dynamic>.from(
      (sessao?['dados'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
    if (dados['_encaminhadoPorRepeticao'] == true) return null;
    final estadoSalvo = dados['_controleRepeticaoBot'];
    final anterior = _ultimaRespostaPorTelefone[telefone] ??
        (estadoSalvo is Map && estadoSalvo['texto'] is String
            ? (
                texto: estadoSalvo['texto'] as String,
                repeticoes: (estadoSalvo['repeticoes'] as num?)?.toInt() ?? 0,
                encaminhado: false,
              )
            : null);

    final repeticoes = anterior != null && anterior.texto == texto
        ? anterior.repeticoes + 1
        : 1;
    if (repeticoes <= 2) {
      _ultimaRespostaPorTelefone[telefone] = (
        texto: texto,
        repeticoes: repeticoes,
        encaminhado: false,
      );
      if (sessao != null && sessao['modoHumano'] != true) {
        dados['_controleRepeticaoBot'] = {
          'texto': texto,
          'repeticoes': repeticoes,
        };
        banco.salvarSessao(
          telefone: telefone,
          nome: sessao['nome'] as String?,
          etapa: sessao['etapa'] as String,
          dados: dados,
          modoHumano: sessao['modoHumano'] == true,
        );
      }
      return texto;
    }

    banco.definirModoHumano(telefone, true, preservarDados: true);
    final sessaoAtualizada = banco.obterSessao(telefone);
    if (sessaoAtualizada != null) {
      final dadosAtualizados = Map<String, dynamic>.from(
        sessaoAtualizada['dados'] as Map,
      )..['_encaminhadoPorRepeticao'] = true;
      banco.salvarSessao(
        telefone: telefone,
        nome: sessaoAtualizada['nome'] as String?,
        etapa: sessaoAtualizada['etapa'] as String,
        dados: dadosAtualizados,
        modoHumano: true,
      );
    }
    _ultimaRespostaPorTelefone[telefone] = (
      texto: _avisoEncaminhamento,
      repeticoes: 1,
      encaminhado: true,
    );
    return _avisoEncaminhamento;
  }

  Future<void> _enviarTextoSemValidar(String telefone, String texto) async {
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
          final payload =
              jsonDecode(row['payload'] as String) as Map<String, dynamic>;
          final response = payload['type'] == 'image'
              ? await _enviarImagemMeta(payload)
              : await _client
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

  Future<http.Response> _enviarImagemMeta(Map<String, dynamic> payload) async {
    final imagem = Map<String, dynamic>.from(payload['image'] as Map);
    final mimeType = imagem['mimetype']?.toString() ?? '';
    if (!{'image/jpeg', 'image/png'}.contains(mimeType)) {
      throw const FormatException('Formato de imagem do cardápio inválido.');
    }
    final bytes = base64Decode(imagem['data'] as String);
    final partesMime = mimeType.split('/');
    final upload = http.MultipartRequest(
      'POST',
      Uri.parse(
          'https://graph.facebook.com/$_graphVersion/$_phoneNumberId/media'),
    )
      ..headers['authorization'] = 'Bearer $_token'
      ..fields['messaging_product'] = 'whatsapp'
      ..files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: partesMime.last == 'png' ? 'cardapio.png' : 'cardapio.jpg',
        contentType: MediaType(partesMime[0], partesMime[1]),
      ));
    final respostaUpload = await http.Response.fromStream(
      await _client.send(upload).timeout(const Duration(seconds: 20)),
    );
    if (respostaUpload.statusCode < 200 || respostaUpload.statusCode >= 300) {
      return respostaUpload;
    }
    final respostaJson = jsonDecode(respostaUpload.body);
    final mediaId = respostaJson is Map ? respostaJson['id']?.toString() : null;
    if (mediaId == null || mediaId.isEmpty) {
      throw const FormatException(
          'O WhatsApp não retornou o identificador da imagem.');
    }
    final mensagem = {
      'messaging_product': 'whatsapp',
      'to': payload['to'],
      'type': 'image',
      'image': {'id': mediaId},
    };
    return _client
        .post(_messagesUri,
            headers: {
              'authorization': 'Bearer $_token',
              'content-type': 'application/json',
            },
            body: jsonEncode(mensagem))
        .timeout(const Duration(seconds: 10));
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

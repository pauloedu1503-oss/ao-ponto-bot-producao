import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../banco/banco.dart';
import '../app_update.dart';
import '../bot/bot_service.dart';
import '../modelos/mensagem_whatsapp.dart';
import '../servicos/auth_service.dart';
import '../servicos/push_service.dart';
import '../util/env.dart';
import '../util/json_resposta.dart';

class Api {
  final Banco banco;
  final AuthService auth;
  final BotService bot;
  final PushService push;

  Timer? _timer;
  bool _processando = false;
  Api(this.banco, this.auth, this.bot, this.push);

  void iniciarWorker() {
    _timer ??=
        Timer.periodic(const Duration(seconds: 2), (_) => processarPendentes());
    unawaited(processarPendentes());
  }

  Future<void> fechar() async {
    _timer?.cancel();
    while (_processando) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> processarPendentes() async {
    if (_processando) return;
    _processando = true;
    try {
      final rows = banco.db.select(
          'SELECT payload FROM webhook_entrada ORDER BY rowid LIMIT 100');
      for (final row in rows) {
        final m = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        try {
          await bot.processar(MensagemWhatsApp(
              id: m['id'],
              telefone: m['telefone'],
              nome: m['nome'],
              texto: m['texto'],
              respostaId: m['respostaId'],
              enviadaEm: DateTime.tryParse(m['enviadaEm'] ?? '')));
        } catch (e) {
          banco.log('ERROR', 'webhook_processamento', e.runtimeType.toString());
          break;
        }
      }
      await bot.whatsapp.drenar();
      await push.drenar();
    } catch (e) {
      banco.log('ERROR', 'worker_erro', e.runtimeType.toString());
    } finally {
      _processando = false;
    }
  }

  Handler get handler {
    final router = Router()
      ..get('/health', _health)
      ..get('/api/app-versao', _appVersao)
      ..post('/api/auth/login', _login)
      ..post('/api/auth/logout', _logout)
      ..get('/api/bootstrap', _protegido(_bootstrap))
      ..get('/api/dashboard', _protegido(_dashboard))
      ..get('/api/config', _protegido(_configGet))
      ..put('/api/config', _protegido(_configPut))
      ..get('/api/cardapio', _protegido(_cardapioGet))
      ..put('/api/cardapio', _protegido(_cardapioPut))
      ..get('/api/pedidos', _protegido(_pedidosGet))
      ..put('/api/pedidos/<id|[0-9]+>/status', _protegido1(_pedidoStatus))
      ..get('/api/humanos', _protegido(_humanosGet))
      ..put('/api/humanos/<telefone>', _protegido1(_humanoPut))
      ..get('/api/conversas-ativas', _protegido(_conversasAtivasGet))
      ..post('/api/conversas-ativas/<telefone>/parar',
          _protegido1(_conversaAtivaParar))
      ..post('/api/humanos/<telefone>/parar-alerta',
          _protegido1(_humanoPararAlerta))
      ..get('/api/logs', _protegido(_logsGet))
      ..get('/api/envios', _protegido(_enviosGet))
      ..post('/api/envios/<id|[0-9]+>/resolver', _protegido1(_envioResolver))
      ..post('/api/backup', _protegido(_backupPost))
      ..post('/api/push/token', _protegido(_pushToken))
      ..post('/api/teste/mensagem', _protegido(_testeMensagem))
      ..post('/api/teste/reset', _protegido(_testeReset))
      ..post('/api/bridge/mensagem', _protegido(_bridgeMensagem))
      ..get('/api/bridge/saidas', _protegido(_bridgeSaidas))
      ..post(
        '/api/bridge/saidas/<id|[0-9]+>/resultado',
        _protegido1(_bridgeSaidaResultado),
      )
      ..get(
        '/api/bridge/fila',
        _protegido(_bridgeFila),
      )
      ..post(
        '/api/bridge/fila/<id|[0-9]+>/resolver',
        _protegido1(_bridgeFilaResolver),
      )
      ..get('/webhook', _webhookVerify)
      ..post('/webhook', _webhookReceive)
      ..options('/<ignored|.*>', (Request _) => Response.ok(''));

    return const Pipeline()
        .addMiddleware(logRequests(logger: (message, isError) {
          if (isError) stderr.writeln('Falha HTTP');
        }))
        .addMiddleware(_cors())
        .addMiddleware(_erros())
        .addHandler(router.call);
  }

  Middleware _cors() => (inner) => (request) async {
        final origin = request.headers['origin'];
        final permitidas = Env.get('CORS_ORIGINS')
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toSet();
        final uri = Uri.tryParse(origin ?? '');
        final local = permitidas.isEmpty &&
            uri != null &&
            {'localhost', '127.0.0.1', '[::1]'}.contains(uri.host);
        final permitido =
            origin == null || permitidas.contains(origin) || local;
        if (!permitido)
          return jsonResponse({'erro': 'Origem não autorizada.'},
              statusCode: 403);
        final response = await inner(request);
        return response.change(headers: {
          ...response.headers,
          if (origin != null) 'access-control-allow-origin': origin,
          'vary': 'Origin',
          'access-control-allow-headers':
              'authorization, content-type, x-hub-signature-256',
          'access-control-allow-methods': 'GET,POST,PUT,OPTIONS',
        });
      };

  Middleware _erros() => (inner) => (request) async {
        try {
          return await inner(request);
        } on ConflitoVersao catch (e) {
          return jsonResponse({'erro': e.mensagem, 'codigo': 'conflito_versao'},
              statusCode: 409);
        } on TypeError {
          return jsonResponse({'erro': 'Formato de dados inválido.'},
              statusCode: 400);
        } on TimeoutException {
          return jsonResponse({'erro': 'Tempo de leitura excedido.'},
              statusCode: 408);
        } on FormatException catch (e) {
          return jsonResponse({'erro': e.message}, statusCode: 400);
        } on ArgumentError catch (e) {
          return jsonResponse({'erro': e.message ?? e.toString()},
              statusCode: 400);
        } on StateError catch (e) {
          return jsonResponse({'erro': e.message}, statusCode: 400);
        } catch (e) {
          banco.log('ERROR', 'api_erro', e.runtimeType.toString());
          return jsonResponse({'erro': 'Erro interno do servidor.'},
              statusCode: 500);
        }
      };

  Handler _protegido(FutureOr<Response> Function(Request) endpoint) {
    return (request) async {
      final authorization = request.headers['authorization'] ?? '';
      final token = authorization.startsWith('Bearer ')
          ? authorization.substring(7).trim()
          : '';
      if (!auth.valido(token)) {
        return jsonResponse({'erro': 'Não autorizado.'}, statusCode: 401);
      }
      return await endpoint(request);
    };
  }

  Function _protegido1(FutureOr<Response> Function(Request, String) endpoint) {
    return (Request request, String parametro) async {
      final authorization = request.headers['authorization'] ?? '';
      final token = authorization.startsWith('Bearer ')
          ? authorization.substring(7).trim()
          : '';
      if (!auth.valido(token)) {
        return jsonResponse({'erro': 'Não autorizado.'}, statusCode: 401);
      }
      return await endpoint(request, parametro);
    };
  }

  Response _bridgeFila(Request request) {
    return jsonResponse({
      'resumo': bot.whatsapp.resumoFilaBridge(),
      'mensagens': bot.whatsapp.listarFilaBridge(),
    });
  }

  Future<Response> _bridgeFilaResolver(
    Request request,
    String id,
  ) async {
    final body = await lerJson(request);

    final acao = body['acao']?.toString().trim() ?? '';

    try {
      bot.whatsapp.resolverSaidaBridge(
        int.parse(id),
        acao,
      );

      return jsonResponse({
        'ok': true,
      });
    } catch (erro) {
      return jsonResponse(
        {
          'erro': erro.toString(),
        },
        statusCode: 400,
      );
    }
  }

  Response _health(Request _) => jsonResponse({
        'ok': true,
        'nome': 'Ao Ponto Bot Backend',
        'whatsappConfigurado': bot.whatsapp.configurado,
        'whatsappBridgeAtivo': bot.whatsapp.bridgeAtivo,
        'whatsappDisponivel': bot.whatsapp.disponivel,
        'versao': '1.3.1',
      });

  Response _appVersao(Request _) => jsonResponse({
        'versao': appVersao,
        'build': appBuild,
        'downloadUrl': appDownloadUrl,
      });

  Future<Response> _pushToken(Request request) async {
    final body = await lerJson(request);
    push.registrarToken(body['token']?.toString() ?? '');
    unawaited(push.drenar());
    return jsonResponse({'ok': true});
  }

  Future<Response> _login(Request request) async {
    final body = await lerJson(request);

    final senha = body['senha']?.toString() ?? '';

    final info = request.context['shelf.io.connection_info'];
    final origem =
        info is HttpConnectionInfo ? info.remoteAddress.address : 'local';

    final resultado = auth.login(
      senha,
      origem,
    );

    switch (resultado.status) {
      case LoginStatus.sucesso:
        banco.log(
          'INFO',
          'login_admin',
          origem,
        );

        return jsonResponse({
          'token': resultado.token,
        });

      case LoginStatus.senhaInvalida:
        banco.log(
          'WARN',
          'login_senha_invalida',
          origem,
        );

        final restantes = resultado.tentativasRestantes;

        return jsonResponse(
          {
            'erro': restantes > 0
                ? 'Senha administrativa incorreta. Restam $restantes tentativa(s) antes do bloqueio temporário.'
                : 'Senha administrativa incorreta.',
            'tentativasRestantes': restantes,
          },
          statusCode: 401,
        );

      case LoginStatus.muitasTentativas:
        banco.log(
          'WARN',
          'login_bloqueado_temporariamente',
          origem,
        );

        return jsonResponse(
          {
            'erro':
                'Muitas senhas incorretas. Aguarde ${resultado.aguardeSegundos} segundo(s) e tente novamente.',
            'retryAfterSeconds': resultado.aguardeSegundos,
          },
          statusCode: 429,
          headers: {
            'retry-after': resultado.aguardeSegundos.toString(),
          },
        );
    }
  }

  Future<Response> _logout(Request request) async {
    final authorization = request.headers['authorization'] ?? '';
    final token = authorization.startsWith('Bearer ')
        ? authorization.substring(7).trim()
        : '';
    if (token.isNotEmpty) auth.logout(token);
    return jsonResponse({'ok': true});
  }

  Response _bootstrap(Request _) => jsonResponse({
        'dashboard': banco.dashboard(),
        'configuracao': banco.obterConfiguracao(),
        'cardapio': banco.obterCardapio(),
        'pedidos': banco.listarPedidos(limite: 50),
        'humanos': banco.listarSessoesHumanas(),
      });

  Response _dashboard(Request _) => jsonResponse(banco.dashboard());
  Response _configGet(Request _) => jsonResponse(banco.obterConfiguracao());

  Future<Response> _configPut(Request request) async {
    final body = await lerJson(request);
    final versao = (body['versao'] as num?)?.toInt() ?? -1;
    final dados = Map<String, dynamic>.from(body['dados'] as Map? ?? {});
    if (dados.isEmpty) throw const FormatException('Configuração vazia.');
    return jsonResponse(banco.atualizarConfiguracao(dados, versao));
  }

  Response _cardapioGet(Request _) => jsonResponse(banco.obterCardapio());

  Future<Response> _cardapioPut(Request request) async {
    final body = await lerJson(request);
    return jsonResponse(banco.atualizarCardapio(body));
  }

  Response _pedidosGet(Request request) {
    final status = request.url.queryParameters['status'];
    final limite =
        int.tryParse(request.url.queryParameters['limite'] ?? '') ?? 100;
    return jsonResponse(banco.listarPedidos(
        status: status, limite: limite.clamp(1, 500).toInt()));
  }

  Future<Response> _pedidoStatus(Request request, String id) async {
    final body = await lerJson(request);
    final pedidoId = int.parse(id);
    final status = body['status']?.toString() ?? '';
    final versao = (body['versao'] as num?)?.toInt() ?? -1;
    final motivo = body['motivoCancelamento']?.toString();
    final pedido = banco.atualizarStatusPedido(pedidoId, status, versao,
        motivoCancelamento: motivo);

    // A atualização do painel não depende do WhatsApp. Se a notificação falhar,
    // o status continua salvo e a falha fica registrada no log.
    unawaited(_notificarStatusPedido(pedido));
    return jsonResponse(pedido);
  }

  Future<void> _notificarStatusPedido(Map<String, dynamic> pedido) async {
    final telefone = pedido['telefone']?.toString() ?? '';
    if (telefone.isEmpty || !bot.whatsapp.disponivel) return;
    final numero = pedido['numero'];
    final status = pedido['status']?.toString() ?? '';
    final recebimento = pedido['recebimento']?.toString() ?? '';
    String? texto;
    switch (status) {
      case 'confirmado':
        texto = '✅ *Pedido #$numero confirmado!*\n\n'
            '👨‍🍳 Já estamos preparando tudo com muito carinho. '
            'Avisaremos você assim que estiver pronto.';
        break;
      case 'pronto':
        texto = recebimento == 'retirada'
            ? '✅ *Seu pedido #$numero está pronto para retirada!*\n\n'
                '🍱 Pode vir buscar. Estamos esperando por você!'
            : '🛵 *Seu pedido #$numero saiu para entrega!*\n\n'
                'Está a caminho e logo chegará até você. Bom apetite! 🍱';
        break;
      case 'finalizado':
        texto =
            '❤️ Pedido #$numero finalizado. Obrigado por pedir na Ao Ponto!';
        break;
      case 'cancelado':
        texto = 'Seu pedido foi recusado pela loja.\n'
            'Motivo: ${pedido['motivoCancelamento']}';
        break;
    }
    if (texto == null) return;
    try {
      await bot.whatsapp.enviarTexto(telefone, texto);
    } catch (e) {
      banco.log('WARN', 'notificacao_status_falhou', '#$numero -> $status: $e');
    }
  }

  Response _humanosGet(Request _) => jsonResponse(banco.listarSessoesHumanas());

  Response _conversasAtivasGet(Request _) =>
      jsonResponse(banco.listarConversasAtivas());

  Response _conversaAtivaParar(Request _, String telefone) {
    banco.pararBotNaConversa(Uri.decodeComponent(telefone));
    return jsonResponse({'ok': true});
  }

  Future<Response> _humanoPut(Request request, String telefone) async {
    final body = await lerJson(request);
    final ativo = body['ativo'] == true;
    final numero = Uri.decodeComponent(telefone);
    if (ativo) {
      banco.definirModoHumano(numero, true);
    } else {
      await bot.retomarAtendimentoHumano(numero);
    }
    return jsonResponse({'ok': true, 'ativo': ativo});
  }

  Response _humanoPararAlerta(Request _, String telefone) {
    banco.pararAlertaHumano(Uri.decodeComponent(telefone));
    return jsonResponse({'ok': true});
  }

  Response _logsGet(Request request) {
    final limite =
        int.tryParse(request.url.queryParameters['limite'] ?? '') ?? 100;
    return jsonResponse(banco.listarLogs(limite: limite.clamp(1, 500).toInt()));
  }

  Response _backupPost(Request _) {
    final caminho = banco.gerarBackup();
    return jsonResponse({'ok': true, 'caminho': caminho});
  }

  Response _enviosGet(Request _) => jsonResponse(banco.enviosComFalha());

  Future<Response> _envioResolver(Request request, String id) async {
    final body = await lerJson(request);
    banco.resolverEnvio(int.parse(id), body['acao']?.toString() ?? '');
    return jsonResponse({'ok': true});
  }

  Future<Response> _bridgeMensagem(Request request) async {
    if (!bot.whatsapp.bridgeAtivo) {
      return jsonResponse(
        {
          'erro': 'A ponte Baileys não está ativada.',
        },
        statusCode: 409,
      );
    }

    final body = await lerJson(request);

    final id = body['id']?.toString().trim() ?? '';
    final telefone = body['telefone']?.toString().trim() ?? '';
    final nome = body['nome']?.toString().trim();
    final texto = body['texto']?.toString() ?? '';
    final respostaId = body['respostaId']?.toString();

    if (id.isEmpty) {
      return jsonResponse(
        {'erro': 'ID da mensagem não informado.'},
        statusCode: 400,
      );
    }

    if (telefone.isEmpty) {
      return jsonResponse(
        {'erro': 'Telefone do cliente não informado.'},
        statusCode: 400,
      );
    }

    await bot.processar(
      MensagemWhatsApp(
        id: id,
        telefone: telefone,
        nome: nome?.isNotEmpty == true ? nome! : 'Cliente',
        texto: texto,
        respostaId: respostaId,
      ),
    );

    return jsonResponse({
      'ok': true,
    });
  }

  Response _bridgeSaidas(Request request) {
    if (!bot.whatsapp.bridgeAtivo) {
      return jsonResponse(
        {
          'erro': 'A ponte Baileys não está ativada.',
        },
        statusCode: 409,
      );
    }

    return jsonResponse({
      'mensagens': bot.whatsapp.reservarProximaSaidaBridge(),
    });
  }

  Future<Response> _bridgeSaidaResultado(
    Request request,
    String id,
  ) async {
    if (!bot.whatsapp.bridgeAtivo) {
      return jsonResponse(
        {'erro': 'A ponte Baileys não está ativada.'},
        statusCode: 409,
      );
    }

    final filaId = int.parse(id);
    final body = await lerJson(request);

    final status = body['status']?.toString().trim().toLowerCase() ?? '';

    if (status == 'enviado') {
      bot.whatsapp.concluirSaidaBridge(filaId);

      return jsonResponse({
        'ok': true,
        'status': 'enviado',
      });
    }

    if (status == 'incerto') {
      final erro = body['erro']?.toString() ?? 'Falha desconhecida';

      bot.whatsapp.marcarSaidaBridgeIncerta(
        filaId,
        erro,
      );

      return jsonResponse({
        'ok': true,
        'status': 'incerto',
      });
    }

    return jsonResponse(
      {
        'erro': 'Status inválido. Use "enviado" ou "incerto".',
      },
      statusCode: 400,
    );
  }

  Future<Response> _testeReset(Request request) async {
    if (bot.whatsapp.disponivel) {
      return jsonResponse(
        {
          'erro':
              'O reset do simulador é bloqueado quando o WhatsApp real está configurado.'
        },
        statusCode: 400,
      );
    }
    final body = await lerJson(request);
    final telefone = body['telefone']?.toString().trim().isNotEmpty == true
        ? body['telefone'].toString().trim()
        : '5514999999999';
    banco.excluirSessao(telefone);
    bot.whatsapp.consumirMensagensSimuladas();
    banco.log('INFO', 'simulador_reset', telefone);
    return jsonResponse({'ok': true});
  }

  Future<Response> _testeMensagem(Request request) async {
    if (bot.whatsapp.disponivel) {
      return jsonResponse(
        {
          'erro':
              'O simulador é bloqueado quando o WhatsApp real está configurado.'
        },
        statusCode: 400,
      );
    }
    final body = await lerJson(request);
    final telefone = body['telefone']?.toString().trim().isNotEmpty == true
        ? body['telefone'].toString().trim()
        : '5514999999999';
    final nome = body['nome']?.toString().trim().isNotEmpty == true
        ? body['nome'].toString().trim()
        : 'Cliente Teste';
    final texto = body['texto']?.toString() ?? '';
    final respostaId = body['respostaId']?.toString();
    bot.whatsapp.consumirMensagensSimuladas();
    await bot.processar(MensagemWhatsApp(
      id: 'sim_${DateTime.now().microsecondsSinceEpoch}',
      telefone: telefone,
      nome: nome,
      texto: texto,
      respostaId: respostaId,
    ));
    return jsonResponse(
        {'respostas': bot.whatsapp.consumirMensagensSimuladas()});
  }

  Response _webhookVerify(Request request) {
    final q = request.url.queryParameters;
    final mode = q['hub.mode'];
    final token = q['hub.verify_token'];
    final challenge = q['hub.challenge'];
    final esperado = Env.get('WHATSAPP_VERIFY_TOKEN');
    if (mode == 'subscribe' &&
        esperado.isNotEmpty &&
        token == esperado &&
        challenge != null) {
      return Response.ok(challenge, headers: {'content-type': 'text/plain'});
    }
    return Response.forbidden('Verificação inválida.');
  }

  Future<Response> _webhookReceive(Request request) async {
    final raw = await lerCorpoLimitado(request);
    if (!_assinaturaValida(raw, request.headers['x-hub-signature-256'])) {
      banco.log('WARN', 'webhook_assinatura_invalida');
      return Response.forbidden('Assinatura inválida.');
    }

    final payload = jsonDecode(raw);
    if (payload is! Map<String, dynamic>) return Response.ok('EVENT_RECEIVED');
    final mensagens = _extrairMensagens(payload);

    banco.db.execute('BEGIN IMMEDIATE');
    try {
      for (final m in mensagens) {
        banco.db.execute(
            'INSERT OR IGNORE INTO webhook_entrada(id,payload,criado_em) VALUES (?,?,?)',
            [
              m.id,
              jsonEncode({
                'id': m.id,
                'telefone': m.telefone,
                'nome': m.nome,
                'texto': m.texto,
                'respostaId': m.respostaId,
                'enviadaEm': m.enviadaEm?.toIso8601String()
              }),
              DateTime.now().toUtc().toIso8601String()
            ]);
      }
      banco.db.execute('COMMIT');
    } catch (_) {
      banco.db.execute('ROLLBACK');
      rethrow;
    }
    return Response.ok('EVENT_RECEIVED');
  }

  bool _assinaturaValida(String raw, String? assinatura) {
    final secret = Env.get('META_APP_SECRET');
    final exigir = Env.getBool('VERIFY_META_SIGNATURE', padrao: true);
    if (secret.isEmpty) return !exigir && !bot.whatsapp.configurado;
    if (assinatura == null || !assinatura.startsWith('sha256=')) return false;
    final esperado =
        Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(raw)).toString();
    return _constantTimeEquals(esperado, assinatura.substring(7));
  }

  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  List<MensagemWhatsApp> _extrairMensagens(Map<String, dynamic> payload) {
    final saida = <MensagemWhatsApp>[];
    final entries = payload['entry'];
    if (entries is! List) return saida;
    for (final entryRaw in entries) {
      if (entryRaw is! Map) continue;
      final changes = entryRaw['changes'];
      if (changes is! List) continue;
      for (final changeRaw in changes) {
        if (changeRaw is! Map) continue;
        final value = changeRaw['value'];
        if (value is! Map) continue;
        final contatos = value['contacts'];
        final nomePorTelefone = <String, String>{};
        if (contatos is List) {
          for (final cRaw in contatos) {
            if (cRaw is! Map) continue;
            final waId = cRaw['wa_id']?.toString();
            final profile = cRaw['profile'];
            final nome = profile is Map ? profile['name']?.toString() : null;
            if (waId != null) nomePorTelefone[waId] = nome ?? '';
          }
        }
        final messages = value['messages'];
        if (messages is! List) continue;
        for (final mRaw in messages) {
          if (mRaw is! Map) continue;
          final id = mRaw['id']?.toString();
          final from = mRaw['from']?.toString();
          if (id == null || from == null) continue;
          String texto = '';
          String? respostaId;
          final type = mRaw['type']?.toString();
          if (type == 'text' && mRaw['text'] is Map) {
            texto = (mRaw['text'] as Map)['body']?.toString() ?? '';
          } else if (type == 'interactive' && mRaw['interactive'] is Map) {
            final interactive = mRaw['interactive'] as Map;
            final subtype = interactive['type']?.toString();
            final reply = subtype == 'button_reply'
                ? interactive['button_reply']
                : interactive['list_reply'];
            if (reply is Map) {
              respostaId = reply['id']?.toString();
              texto = reply['title']?.toString() ?? '';
            }
          } else if (type == 'button' && mRaw['button'] is Map) {
            final button = mRaw['button'] as Map;
            respostaId = button['payload']?.toString();
            texto = button['text']?.toString() ?? '';
          } else {
            texto = '';
          }
          final nomeContato = nomePorTelefone[from]?.trim();
          saida.add(MensagemWhatsApp(
            id: id,
            telefone: from,
            nome: (nomeContato?.isNotEmpty ?? false) ? nomeContato! : 'Cliente',
            texto: texto,
            respostaId: respostaId,
            enviadaEm: int.tryParse(mRaw['timestamp']?.toString() ?? '') == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    int.parse(mRaw['timestamp'].toString()) * 1000,
                    isUtc: true),
          ));
        }
      }
    }
    return saida;
  }
}

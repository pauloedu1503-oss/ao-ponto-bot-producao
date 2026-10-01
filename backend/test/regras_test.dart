import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/api/api.dart';
import '../lib/banco/banco.dart';
import '../lib/bot/bot_service.dart';
import '../lib/modelos/mensagem_whatsapp.dart';
import '../lib/servicos/auth_service.dart';
import '../lib/servicos/push_service.dart';
import '../lib/servicos/whatsapp_service.dart';
import '../lib/util/calculo_pedido.dart';
import '../lib/util/env.dart';
import '../bin/restaurar.dart' as restauracao;

void main() {
  late Banco banco;
  late WhatsAppService wa;
  late BotService bot;
  late Directory temp;
  var sequencia = 0;

  void configurar(void Function(Map<String, dynamic>) alterar) {
    final w = banco.obterConfiguracao();
    final dados = Map<String, dynamic>.from(w['dados']);
    alterar(dados);
    banco.atualizarConfiguracao(dados, w['versao']);
  }

  Future<void> enviar(String texto,
          {String? id, String telefone = '5514999999999'}) =>
      bot.processar(MensagemWhatsApp(
          id: id ?? 'teste_${sequencia++}',
          telefone: telefone,
          nome: 'Teste',
          texto: texto));

  Map<String, dynamic> sessao() => banco.obterSessao('5514999999999')!;

  Future<void> montar(
      {bool entrega = false, String pagamento = 'pag_credito'}) async {
    for (final t in [
      'inicio_pedido',
      '1',
      '1',
      '1',
      '2',
      'outro_nao',
      entrega ? 'rec_entrega' : 'rec_retirada'
    ]) {
      await enviar(t);
    }
    if (entrega) {
      await enviar('Rua das Flores, 120, Centro');
      await enviar('cid:barra_bonita_sp');
    }
    await enviar(pagamento);
    if (pagamento == 'pag_dinheiro') await enviar('sem troco');
    await enviar('não');
    expect(sessao()['etapa'], 'confirmacao');
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('ao_ponto_test_');
    final env = File('${temp.path}/test.env')
      ..writeAsStringSync(
          'ADMIN_PASSWORD=senha-de-teste\nMETA_APP_SECRET=segredo-teste\n');
    Env.carregar(env.path);
    banco = Banco(caminhoBanco: '${temp.path}/test.db');
    wa = WhatsAppService(banco);
    bot = BotService(banco, wa);
    configurar((d) {
      d['enderecoRetirada'] = 'Rua da Loja, 10';
      d['chavePix'] = 'chave-teste';
      d['estadoBot'] = 'atendendo';
    });
  });

  tearDown(() {
    wa.fechar();
    banco.fechar();
    temp.deleteSync(recursive: true);
  });

  test('cálculo em centavos e recusa de valores inválidos', () {
    final c = CalculoPedido([
      {'precoUnitario': 0.1, 'quantidade': 3}
    ], 0.2);
    expect(c.total, 0.5);
    expect(
        () => CalculoPedido([
              {'precoUnitario': double.nan, 'quantidade': 1}
            ], 0),
        throwsArgumentError);
    expect(
        () => CalculoPedido([
              {'precoUnitario': 10, 'quantidade': 0}
            ], 0),
        throwsArgumentError);
  });

  test('retirada, segundo clique e segundo pedido limpo', () async {
    await montar();
    await Future.wait([
      enviar('conf_confirmar', id: 'conf1'),
      enviar('conf_confirmar', id: 'conf1'),
      enviar('conf_confirmar', id: 'conf2')
    ]);
    expect(banco.listarPedidos(), hasLength(1));
    final p = banco.listarPedidos().single;
    expect(p['numero'], inInclusiveRange(10000, 99999));
    expect(p['total'], 18);
    expect(p['taxaMaquininha'], 2);
    expect(p['taxaEntrega'], 0);
    expect(p['endereco'], 'Rua da Loja, 10');
    expect((sessao()['dados'] as Map)['itens'], isEmpty);
    await montar();
    await enviar('conf_confirmar');
    expect(banco.listarPedidos(), hasLength(2));
    final numeros = banco.listarPedidos().map((e) => e['numero']).toSet();
    expect(numeros, hasLength(2));
  });

  test('bot desativado não visualiza nem responde mensagens', () async {
    configurar((d) => d['botAtivo'] = false);
    wa.consumirMensagensSimuladas();
    await enviar('oi');
    expect(wa.consumirMensagensSimuladas(), isEmpty);
    expect(banco.obterSessao('5514999999999'), isNull);
  });

  test('conversa ativa pode ser parada sem desligar o bot para todos',
      () async {
    await enviar('oi');
    expect(banco.listarConversasAtivas(), hasLength(1));

    banco.pararBotNaConversa('5514999999999');
    expect(banco.listarConversasAtivas(), isEmpty);
    final humanos = banco.listarSessoesHumanas();
    expect(humanos, hasLength(1));
    expect(humanos.single['alertaAtivo'], isFalse);

    wa.consumirMensagensSimuladas();
    await enviar('1');
    expect(wa.consumirMensagensSimuladas(), isEmpty);

    await enviar('oi', telefone: '5514888888888');
    expect(banco.listarConversasAtivas(), hasLength(1));
  });

  test('bebidas são configuráveis, opcionais e entram no total', () async {
    final menu = banco.obterCardapio();
    menu['bebidas'] = [
      {
        'id': 'beb_coca',
        'tipo': 'bebida',
        'nome': 'Coca-Cola lata',
        'preco': 3.0,
        'ativo': true,
        'ordem': 1,
      }
    ];
    banco.atualizarCardapio(menu);
    for (final texto in [
      'inicio_pedido',
      '1',
      '1',
      '1',
      '1',
      'outro_nao',
      'rec_retirada',
      'pag_pix',
      'não',
      '1',
      '2',
      'beb_finalizar',
      'conf_confirmar',
    ]) {
      await enviar(texto);
    }
    final pedido = banco.listarPedidos().single;
    expect(pedido['subtotal'], 14);
    expect(pedido['total'], 14);
    expect(pedido['bebidas'], hasLength(1));
    expect(pedido['bebidas'][0]['quantidade'], 2);
  });

  test('fluxos de arroz e feijão são independentes e salvos no pedido',
      () async {
    final menu = banco.obterCardapio();
    menu['fluxoArrozAtivo'] = true;
    menu['fluxoFeijaoAtivo'] = true;
    menu['arrozes'] = [
      {
        'id': 'arr_branco',
        'tipo': 'arroz',
        'nome': 'Arroz branco',
        'ativo': true,
        'ordem': 1,
      }
    ];
    menu['feijoes'] = [
      {
        'id': 'fei_carioca',
        'tipo': 'feijao',
        'nome': 'Feijão carioca',
        'ativo': true,
        'ordem': 1,
      }
    ];
    banco.atualizarCardapio(menu);

    await enviar('inicio_pedido');
    await enviar('1');
    expect(sessao()['etapa'], 'arroz');
    await enviar('1');
    expect(sessao()['etapa'], 'feijao');
    await enviar('1');
    expect(sessao()['etapa'], 'mistura');
    final saidas = wa.consumirMensagensSimuladas();
    expect(jsonEncode(saidas.last),
        contains('arroz à escolha + feijão à escolha'));

    for (final texto in [
      '1',
      '1',
      '1',
      'outro_nao',
      'rec_retirada',
      'pag_pix',
      'não',
      'conf_confirmar',
    ]) {
      await enviar(texto);
    }
    final item = banco.listarPedidos().single['itens'][0] as Map;
    expect(item['arrozNome'], 'Arroz branco');
    expect(item['feijaoNome'], 'Feijão carioca');
  });

  test('descrição arroz e feijão acompanha cada combinação dos fluxos',
      () async {
    final menu = banco.obterCardapio();
    menu['arrozes'] = [
      {'id': 'arr_1', 'nome': 'Arroz branco', 'ativo': true, 'ordem': 1}
    ];
    menu['feijoes'] = [
      {'id': 'fei_1', 'nome': 'Feijão carioca', 'ativo': true, 'ordem': 1}
    ];

    Future<String> cardapioCom(bool arroz, bool feijao) async {
      final atual = banco.obterCardapio();
      atual['arrozes'] = menu['arrozes'];
      atual['feijoes'] = menu['feijoes'];
      atual['fluxoArrozAtivo'] = arroz;
      atual['fluxoFeijaoAtivo'] = feijao;
      banco.atualizarCardapio(atual);
      wa.consumirMensagensSimuladas();
      await enviar('inicio_cardapio');
      return jsonEncode(wa.consumirMensagensSimuladas().last);
    }

    expect(await cardapioCom(false, false), contains('arroz + feijão'));
    expect(
        await cardapioCom(true, false), contains('arroz à escolha + feijão'));
    expect(
        await cardapioCom(false, true), contains('arroz + feijão à escolha'));
    expect(await cardapioCom(true, true),
        contains('arroz à escolha + feijão à escolha'));
  });

  test('preço visto fica congelado antes da escolha', () async {
    await enviar('inicio_pedido');
    final menu = banco.obterCardapio();
    (menu['tamanhos'] as List).first['preco'] = 99;
    banco.atualizarCardapio(menu);
    await enviar('1');
    expect(sessao()['dados']['itemAtual']['precoUnitario'], 8);
  });

  test('endereço natural, cidade e taxa exibida congelada', () async {
    for (final t in [
      'inicio_pedido',
      '1',
      '1',
      '1',
      '1',
      'outro_nao',
      'rec_entrega',
      'Rua A 123 centro'
    ]) {
      await enviar(t);
    }
    expect(sessao()['etapa'], 'cidade_entrega');
    configurar((d) => d['cidadesEntrega'][0]['taxa'] = 99.0);
    await enviar('1');
    expect(sessao()['dados']['taxaEntregaCongelada'], 8);
    await enviar('pag_credito');
    await enviar('não');
    await enviar('conf_confirmar');
    expect(banco.listarPedidos().single['total'], 18);
  });

  test('cidade desativada impede confirmação', () async {
    await montar(entrega: true);
    configurar((d) => d['cidadesEntrega'][0]['ativa'] = false);
    await enviar('conf_confirmar');
    expect(banco.listarPedidos(), isEmpty);
    expect(sessao()['etapa'], 'endereco');
  });

  test('mistura desativada impede pedido antigo', () async {
    await montar();
    final menu = banco.obterCardapio();
    menu['misturas'][0]['ativo'] = false;
    banco.atualizarCardapio(menu);
    await enviar('conf_confirmar');
    expect(banco.listarPedidos(), isEmpty);
    expect(sessao()['etapa'], 'tamanho');
  });

  test('pagamento desativado exige nova escolha', () async {
    await montar();
    configurar((d) => d['pagamentos']['credito'] = false);
    await enviar('conf_confirmar');
    expect(sessao()['etapa'], 'pagamento');
    expect(banco.listarPedidos(), isEmpty);
  });

  test('troco menor que total permanece na etapa', () async {
    for (final t in [
      'inicio_pedido',
      '1',
      '1',
      '1',
      '2',
      'outro_nao',
      'rec_retirada',
      'pag_dinheiro',
      '10'
    ]) {
      await enviar(t);
    }
    expect(sessao()['etapa'], 'troco');
    await enviar('16');
    expect(sessao()['etapa'], 'observacao');
  });

  test('voltar em etapa automaticamente pulada não retorna à frente', () async {
    configurar((d) {
      d['entregaAtiva'] = false;
      d['pagamentos'] = {'pix': false, 'dinheiro': true, 'cartao': false};
    });
    for (final t in ['inicio_pedido', '1', '1', '1', '1', 'outro_nao']) {
      await enviar(t);
    }
    expect(sessao()['etapa'], 'troco');
    await enviar('voltar');
    expect(sessao()['etapa'], 'pagamento');
    await enviar('voltar');
    expect(sessao()['etapa'], 'recebimento');
    await enviar('voltar');
    expect(sessao()['etapa'], 'adicionar_outro');
  });

  test('cancelamento e humano limpam carrinho', () async {
    await montar();
    await enviar('0');
    expect(sessao()['etapa'], 'confirmar_cancelamento');
    await enviar('cancelar_sim');
    expect(sessao()['dados']['itens'], isEmpty);
    await montar();
    await enviar('atendente');
    expect(sessao()['modoHumano'], true);
    expect(sessao()['dados'], isEmpty);
    await bot.retomarAtendimentoHumano('5514999999999');
    expect(sessao()['dados']['itens'], isEmpty);
  });

  test('mídia não avança observação; sessão expirada recomeça', () async {
    await montar();
    await enviar('voltar');
    await enviar('');
    expect(sessao()['etapa'], 'observacao');
    banco.db.execute(
        "UPDATE sessoes SET ultima_atividade = '2000-01-01T00:00:00Z'");
    await enviar('conf_confirmar');
    expect(sessao()['etapa'], 'inicio');
    expect(banco.listarPedidos(), isEmpty);
  });

  test('sessão limpa após pedido concluído ou cancelado não expira', () async {
    await montar();
    await enviar('conf_confirmar');
    expect(sessao()['etapa'], 'inicio');

    banco.db.execute(
      "UPDATE sessoes SET ultima_atividade = ? WHERE telefone = ?",
      [
        DateTime.now().subtract(const Duration(days: 2)).toIso8601String(),
        '5514999999999'
      ],
    );

    await enviar('olá');
    expect(sessao()['etapa'], 'inicio');
    final ultimaResposta =
        wa.consumirMensagensSimuladas().last['texto']?.toString() ?? '';
    expect(ultimaResposta, isNot(contains('expirou por inatividade')));

    await montar();
    await enviar('cancelar');
    await enviar('cancelar_sim');
    expect(sessao()['etapa'], 'inicio');

    banco.db.execute(
      "UPDATE sessoes SET ultima_atividade = ? WHERE telefone = ?",
      [
        DateTime.now().subtract(const Duration(days: 2)).toIso8601String(),
        '5514999999999'
      ],
    );

    await enviar('olá novamente');
    final respostaAposCancelamento =
        wa.consumirMensagensSimuladas().last['texto']?.toString() ?? '';
    expect(
        respostaAposCancelamento, isNot(contains('expirou por inatividade')));
  });

  test('status só avança e controle de versão recusa alteração antiga',
      () async {
    await montar();
    await enviar('conf_confirmar');
    var p = banco.listarPedidos().single;
    expect(
        () => banco.atualizarStatusPedido(p['id'], 'finalizado', p['versao']),
        throwsArgumentError);
    for (final status in ['confirmado', 'pronto', 'finalizado']) {
      p = banco.atualizarStatusPedido(p['id'], status, p['versao']);
    }
    expect(() => banco.atualizarStatusPedido(p['id'], 'novo', p['versao']),
        throwsArgumentError);
    expect(() => banco.atualizarStatusPedido(p['id'], 'cancelado', 1),
        throwsA(isA<ConflitoVersao>()));
  });

  test('configuração, cidade e botões inválidos são recusados', () {
    expect(() => configurar((d) => d['pagamentos'] = {}), throwsArgumentError);
    expect(
        () => configurar(
            (d) => d['cidadesEntrega'][1]['id'] = d['cidadesEntrega'][0]['id']),
        throwsArgumentError);
    expect(
        () => configurar((d) => d['fluxo']['cidadeEntrega']['mensagem'] = ''),
        throwsArgumentError);
    expect(
        () => configurar(
            (d) => d['fluxo']['inicio']['botaoPedido'] = 'Ver cardápio'),
        throwsArgumentError);
    final w = banco.obterConfiguracao();
    configurar((d) => d['nomeEstabelecimento'] = 'Novo');
    expect(() => banco.atualizarConfiguracao(w['dados'], w['versao']),
        throwsA(isA<ConflitoVersao>()));
  });

  test('limite de login é aplicado antes de testar senha', () {
    final auth = AuthService();
    for (var i = 0; i < 8; i++) {
      expect(auth.login('errada', 'ip').status, LoginStatus.senhaInvalida);
    }
    expect(auth.login('senha-de-teste', 'ip').status,
        LoginStatus.muitasTentativas);
    final token = auth.login('senha-de-teste', 'outro').token!;
    expect(auth.valido(token), true);
    auth.logout(token);
    expect(auth.valido(token), false);
  });

  test('webhook exige assinatura, persiste e deduplica após reinício do worker',
      () async {
    final api = Api(banco, AuthService(), bot, PushService(banco));
    final raw = jsonEncode({
      'entry': [
        {
          'changes': [
            {
              'value': {
                'messages': [
                  {
                    'id': 'wa1',
                    'from': '5514999999999',
                    'type': 'text',
                    'text': {'body': 'oi'}
                  }
                ]
              }
            }
          ]
        }
      ]
    });
    Future<Response> request({bool assinado = true}) => Future.value(
            api.handler(Request('POST', Uri.parse('http://localhost/webhook'),
                body: raw,
                headers: {
              if (assinado)
                'x-hub-signature-256':
                    'sha256=${Hmac(sha256, utf8.encode('segredo-teste')).convert(utf8.encode(raw))}'
            })));
    expect((await request(assinado: false)).statusCode, 403);
    expect((await request()).statusCode, 200);
    expect(banco.db.select('SELECT * FROM webhook_entrada'), hasLength(1));
    await api.processarPendentes();
    wa.consumirMensagensSimuladas();
    await request();
    await api.processarPendentes();
    expect(wa.consumirMensagensSimuladas(), isEmpty);
    await api.fechar();
  });

  test('payload de tipo errado retorna erro JSON 400', () async {
    final auth = AuthService();
    final token = auth.login('senha-de-teste', 'local').token!;
    final api = Api(banco, auth, bot, PushService(banco));
    final r = await api.handler(Request(
        'PUT', Uri.parse('http://localhost/api/config'),
        headers: {'authorization': 'Bearer $token'},
        body: '{"versao":"errada","dados":{}}'));
    expect(r.statusCode, 400);
    expect(jsonDecode(await r.readAsString())['codigo'], isNotEmpty);
  });

  test('falha da Meta não perde pedido nem reexecuta confirmação', () async {
    final file = File('${temp.path}/real.env')
      ..writeAsStringSync(
          'ADMIN_PASSWORD=senha-de-teste\nWHATSAPP_ACCESS_TOKEN=falso\nWHATSAPP_PHONE_NUMBER_ID=teste\nMETA_APP_SECRET=segredo-teste');
    Env.carregar(file.path);
    wa.fechar();
    wa = WhatsAppService(banco,
        client: MockClient((_) async => http.Response('indisponível', 503)));
    bot = BotService(banco, wa);
    await montar();
    await enviar('conf_confirmar', id: 'real_conf');
    await wa.drenar();
    await enviar('conf_confirmar', id: 'real_conf');
    expect(banco.listarPedidos(), hasLength(1));
    expect(
        banco.db.select("SELECT * FROM whatsapp_saida WHERE status='falhou'"),
        isNotEmpty);
    expect(
        banco.db
            .select("SELECT * FROM mensagens_processadas WHERE id='real_conf'")
            .single['status'],
        'done');
  });

  test('migração é idempotente e preserva cardápio intencionalmente vazio', () {
    configurar((d) => d['estadoBot'] = 'fechado');
    banco.atualizarCardapio({
      'versao': banco.obterCardapio()['versao'],
      'tamanhos': [],
      'misturas': [],
      'acompanhamentos': []
    });
    final versao = banco.obterConfiguracao()['versao'];
    banco.fechar();
    banco = Banco(caminhoBanco: '${temp.path}/test.db');
    expect(banco.obterCardapio()['tamanhos'], isEmpty);
    expect(banco.obterConfiguracao()['versao'], versao);
    expect(
        banco.db.select('PRAGMA integrity_check').single.values.single, 'ok');
  });

  test('botão de mensagem antiga é recusado sem mudar a etapa', () async {
    await enviar('oi');
    final botoes = wa.consumirMensagensSimuladas().last;
    final antigo = ((botoes['interactive'] as Map)['action'] as Map)['buttons']
        [0]['reply']['id'] as String;
    await bot.processar(MensagemWhatsApp(
        id: 'clique1',
        telefone: '5514999999999',
        nome: 'Teste',
        texto: '',
        respostaId: antigo));
    expect(sessao()['etapa'], 'tamanho');
    await bot.processar(MensagemWhatsApp(
        id: 'clique2',
        telefone: '5514999999999',
        nome: 'Teste',
        texto: '',
        respostaId: antigo));
    expect(sessao()['etapa'], 'tamanho');
    expect(banco.listarPedidos(), isEmpty);
  });

  test('falha depois de inserir pedido desfaz pedido e conserva sessão',
      () async {
    await montar();
    wa.fechar();
    wa = _WhatsappFalhaConfirmacao(banco);
    bot = BotService(banco, wa);
    await expectLater(enviar('conf_confirmar'), throwsStateError);
    expect(banco.listarPedidos(), isEmpty);
    expect(sessao()['etapa'], 'confirmacao');
  });

  test('backup SQLite restaura pedidos, sessão e integridade', () async {
    await montar();
    await enviar('conf_confirmar');
    final backup = banco.gerarBackup(diretorio: '${temp.path}/backups');
    final destino = '${temp.path}/restaurado.db';
    restauracao.main([backup, destino]);
    expect(File(destino).existsSync(), true);
    final recuperado = Banco(caminhoBanco: destino);
    try {
      expect(recuperado.listarPedidos(), hasLength(1));
      expect(recuperado.obterSessao('5514999999999'), isNotNull);
      expect(
          recuperado.db.select('PRAGMA integrity_check').single.values.single,
          'ok');
    } finally {
      recuperado.fechar();
    }
  });

  test('falha de envio bloqueia os seguintes até decisão explícita', () async {
    final file = File('${temp.path}/real.env')
      ..writeAsStringSync(
          'ADMIN_PASSWORD=senha-de-teste\nWHATSAPP_ACCESS_TOKEN=falso\nWHATSAPP_PHONE_NUMBER_ID=teste\nMETA_APP_SECRET=segredo-teste');
    Env.carregar(file.path);
    wa.fechar();
    var chamadas = 0;
    wa = WhatsAppService(banco, client: MockClient((_) async {
      chamadas++;
      return http.Response('', 503);
    }));
    await wa.enviarTexto('5514999999999', 'primeiro');
    await wa.enviarTexto('5514999999999', 'segundo');
    await wa.drenar();
    expect(chamadas, 1);
    await wa.drenar();
    expect(chamadas, 1);
    final primeiro = banco.enviosComFalha().single;
    banco.resolverEnvio(primeiro['id'], 'descartar');
    await wa.drenar();
    expect(chamadas, 2);
  });
}

class _WhatsappFalhaConfirmacao extends WhatsAppService {
  _WhatsappFalhaConfirmacao(super.banco);
  @override
  Future<void> enviarTexto(String telefone, String texto) {
    if (texto.contains('PEDIDO #')) throw StateError('Falha simulada');
    return super.enviarTexto(telefone, texto);
  }
}

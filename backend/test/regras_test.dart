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
import '../lib/util/data_hora.dart';
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
    ]) {
      await enviar(texto);
    }
    final opcoesBebida = jsonEncode(wa.consumirMensagensSimuladas().last);
    expect(opcoesBebida, contains(r'Coca-Cola lata R$ 3,00'));

    for (final texto in [
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

  test('negações naturais pulam bebida e preservam escolha afirmativa',
      () async {
    final menu = banco.obterCardapio();
    menu['bebidas'] = [
      {
        'id': 'beb_coca',
        'tipo': 'bebida',
        'nome': 'Coca-Cola',
        'preco': 3.0,
        'ativo': true,
        'ordem': 1,
      }
    ];
    banco.atualizarCardapio(menu);

    Future<void> chegarNasBebidas(String telefone) async {
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
      ]) {
        await enviar(texto, telefone: telefone);
      }
      expect(banco.obterSessao(telefone)?['etapa'], 'bebida');
    }

    const negacoes = [
      'sem',
      'não',
      'n',
      'n quero',
      'não quero bebida',
      'não precisa',
      'não obrigado',
      'dispenso',
      'nenhuma bebida',
      'pode deixar',
    ];
    for (var i = 0; i < negacoes.length; i++) {
      final telefone = '55148888000$i';
      await chegarNasBebidas(telefone);
      await enviar(negacoes[i], telefone: telefone);
      final sessaoAtual = banco.obterSessao(telefone)!;
      expect(sessaoAtual['etapa'], 'confirmacao', reason: negacoes[i]);
      expect(sessaoAtual['dados']['bebidas'], isEmpty, reason: negacoes[i]);
      wa.consumirMensagensSimuladas();
    }

    const telefonePositivo = '5514777700001';
    await chegarNasBebidas(telefonePositivo);
    await enviar('Quero uma Coca-Cola', telefone: telefonePositivo);
    expect(banco.obterSessao(telefonePositivo)?['etapa'], 'quantidade_bebida');
  });

  test('negações naturais finalizam outra marmita e outra bebida', () async {
    final menu = banco.obterCardapio();
    menu['bebidas'] = [
      {
        'id': 'beb_coca',
        'tipo': 'bebida',
        'nome': 'Coca-Cola',
        'preco': 3.0,
        'ativo': true,
        'ordem': 1,
      }
    ];
    banco.atualizarCardapio(menu);

    const telefoneMarmita = '5514777700002';
    for (final texto in ['inicio_pedido', '1', '1', '1', '1']) {
      await enviar(texto, telefone: telefoneMarmita);
    }
    await enviar('não quero outra marmita', telefone: telefoneMarmita);
    expect(banco.obterSessao(telefoneMarmita)?['etapa'], 'recebimento');

    const telefoneBebida = '5514777700003';
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
    ]) {
      await enviar(texto, telefone: telefoneBebida);
    }
    expect(
        banco.obterSessao(telefoneBebida)?['etapa'], 'adicionar_outra_bebida');
    await enviar('n quero', telefone: telefoneBebida);
    final sessaoBebida = banco.obterSessao(telefoneBebida)!;
    expect(sessaoBebida['etapa'], 'confirmacao');
    expect(sessaoBebida['dados']['bebidas'], hasLength(1));
  });

  test('negação natural de troco e observação não perde texto válido',
      () async {
    final menu = banco.obterCardapio();
    menu['bebidas'] = <dynamic>[];
    banco.atualizarCardapio(menu);

    for (final texto in [
      'inicio_pedido',
      '1',
      '1',
      '1',
      '1',
      'outro_nao',
      'rec_retirada',
      'pag_dinheiro',
    ]) {
      await enviar(texto);
    }
    expect(sessao()['etapa'], 'troco');
    await enviar('n quero');
    expect(sessao()['etapa'], 'observacao');

    await enviar('sem cebola');
    expect(sessao()['etapa'], 'confirmacao');
    expect(sessao()['dados']['observacao'], 'sem cebola');
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
    expect(jsonEncode(saidas.last), contains('Escolha a mistura'));
    expect(jsonEncode(saidas.last), isNot(contains('Você escolheu')));
    expect(jsonEncode(saidas.last), isNot(contains('Arroz branco')));
    expect(jsonEncode(saidas.last), isNot(contains('Feijão carioca')));

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

  test('cardápio segue arroz, feijão, mistura, acompanhamento e bebida',
      () async {
    final menu = banco.obterCardapio();
    menu['fluxoArrozAtivo'] = true;
    menu['fluxoFeijaoAtivo'] = true;
    menu['arrozes'] = [
      {'id': 'arr_1', 'nome': 'Arroz branco', 'ativo': true, 'ordem': 1}
    ];
    menu['feijoes'] = [
      {'id': 'fei_1', 'nome': 'Feijão carioca', 'ativo': true, 'ordem': 1}
    ];
    menu['bebidas'] = [
      {
        'id': 'beb_1',
        'nome': 'Refrigerante',
        'preco': 5.0,
        'ativo': true,
        'ordem': 1
      }
    ];
    banco.atualizarCardapio(menu);

    await enviar('inicio_cardapio');
    final resposta = jsonEncode(wa.consumirMensagensSimuladas().last);
    final arroz = resposta.indexOf('*Arroz:*');
    final feijao = resposta.indexOf('*Feijão:*');
    final mistura = resposta.indexOf('*Misturas:*');
    final acompanhamento = resposta.indexOf('*Acompanhamentos:*');
    final bebida = resposta.indexOf('*Bebidas:*');
    expect(arroz, greaterThanOrEqualTo(0));
    expect(arroz < feijao && feijao < mistura, isTrue);
    expect(mistura < acompanhamento && acompanhamento < bebida, isTrue);
  });

  test('opção 2 depois do cardápio chama atendente', () async {
    await enviar('oi');
    await enviar('quero ver o cardápio');
    expect(sessao()['etapa'], 'inicio');
    expect(jsonEncode(wa.consumirMensagensSimuladas().last),
        contains('CARDÁPIO DO DIA'));

    await enviar('2');
    expect(sessao()['modoHumano'], true);
    expect(jsonEncode(wa.consumirMensagensSimuladas().last),
        contains('atendimento automático foi pausado'));
  });

  test('frase livre e cardápio no meio do pedido não consomem a quantidade',
      () async {
    await enviar('Quero fazer um pedido');
    expect(sessao()['etapa'], 'tamanho');

    await enviar('1');
    await enviar('Bife acebolado');
    await enviar('Macarrão');
    expect(sessao()['etapa'], 'quantidade');

    await enviar('Pode me mostrar o cardápio?');
    expect(sessao()['etapa'], 'quantidade');
    expect(jsonEncode(wa.consumirMensagensSimuladas().last),
        contains('CARDÁPIO DO DIA'));

    await enviar('2');
    expect(sessao()['etapa'], 'adicionar_outro');
  });

  test('nomes longos aparecem completos sem depender do rótulo do botão',
      () async {
    const nomeLongo = 'Carne de panela com batatas e molho caseiro';
    await wa.enviarBotoes('5514999999999', 'Escolha a mistura:', const [
      {'id': 'mis:1', 'titulo': nomeLongo},
      {'id': 'mis:2', 'titulo': 'Frango grelhado'},
    ]);
    var payload = wa.consumirMensagensSimuladas().last;
    expect(payload['interactive']['body']['text'], contains(nomeLongo));
    expect(
        payload['interactive']['action']['buttons'][0]['reply']['title'], '1');

    await wa.enviarLista(
      '5514999999999',
      texto: 'Escolha o acompanhamento:',
      tituloBotao: 'Ver opções',
      opcoes: const [
        {'id': 'aco:1', 'titulo': nomeLongo},
        {'id': 'aco:2', 'titulo': 'Batata frita'},
      ],
    );
    payload = wa.consumirMensagensSimuladas().last;
    expect(payload['interactive']['body']['text'], contains(nomeLongo));
    expect(payload['interactive']['action']['sections'][0]['rows'][0]['title'],
        '1');
  });

  test('coleta as quantidades configuradas de misturas e acompanhamentos',
      () async {
    final menu = banco.obterCardapio();
    final pequena = (menu['tamanhos'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((item) => item['id'] == 'tam_pequena');
    pequena['quantidadeMisturas'] = 2;
    pequena['quantidadeAcompanhamentos'] = 2;
    banco.atualizarCardapio(menu);

    await enviar('inicio_pedido');
    await enviar('tam:tam_pequena');
    await enviar('mis:mis_calabresa');
    expect(sessao()['etapa'], 'mistura');
    expect(
        jsonEncode(wa.consumirMensagensSimuladas().last), contains('(2 de 2)'));

    await enviar('mis:mis_frango');
    expect(sessao()['etapa'], 'acompanhamento');
    expect(
        jsonEncode(wa.consumirMensagensSimuladas().last), contains('(1 de 2)'));
    await enviar('aco:aco_macarrao');
    expect(sessao()['etapa'], 'acompanhamento');
    expect(
        jsonEncode(wa.consumirMensagensSimuladas().last), contains('(2 de 2)'));
    await enviar('aco:aco_batata');
    expect(sessao()['etapa'], 'quantidade');
    await enviar('1');

    final item = (sessao()['dados']['itens'] as List).single;
    expect(item['misturaIds'], ['mis_calabresa', 'mis_frango']);
    expect(item['acompanhamentoIds'], ['aco_macarrao', 'aco_batata']);
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
    wa.consumirMensagensSimuladas();
    await bot.retomarAtendimentoHumano('5514999999999');
    expect(sessao()['dados']['itens'], isEmpty);
    expect(wa.consumirMensagensSimuladas(), isEmpty);
  });

  test('atendente e ajuda continuam disponíveis na confirmação de cancelamento',
      () async {
    await montar();
    await enviar('cancelar');
    expect(sessao()['etapa'], 'confirmar_cancelamento');

    await enviar('ajuda');
    expect(sessao()['etapa'], 'confirmar_cancelamento');
    expect(jsonEncode(wa.consumirMensagensSimuladas().last),
        contains('confirmar o cancelamento'));

    await enviar('atendente');
    expect(sessao()['modoHumano'], true);
  });

  test('voltar na confirmação de cancelamento mantém o pedido', () async {
    await montar();
    await enviar('cancelar');
    await enviar('voltar');

    expect(sessao()['etapa'], 'confirmacao');
    expect(sessao()['dados']['itens'], hasLength(1));
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
    final resposta = jsonEncode(wa.consumirMensagensSimuladas().last);
    expect(resposta, contains('expirou por inatividade'));
    expect(resposta, contains('Bem-vindo'));
  });

  test('após concluir, boas-vindas voltam após 60 minutos inativo', () async {
    await montar();
    await enviar('conf_confirmar');
    wa.consumirMensagensSimuladas();

    await enviar('olá');
    final respostaImediata =
        wa.consumirMensagensSimuladas().last['texto']?.toString() ?? '';
    expect(respostaImediata, isNot(contains('Bem-vindo')));

    banco.db.execute(
      'UPDATE sessoes SET ultima_atividade = ? WHERE telefone = ?',
      [
        agoraLocal().subtract(const Duration(minutes: 61)).toIso8601String(),
        '5514999999999'
      ],
    );
    await enviar('olá novamente');

    final resposta = jsonEncode(wa.consumirMensagensSimuladas().last);
    expect(resposta, contains('Bem-vindo'));
    expect(resposta, contains('Como podemos ajudar?'));
    expect(sessao()['etapa'], 'inicio');
    expect(sessao()['dados']['itens'], isEmpty);
  });

  test('sessão limpa após cancelamento também expira com boas-vindas',
      () async {
    await montar();
    await enviar('cancelar');
    await enviar('cancelar_sim');
    expect(sessao()['etapa'], 'inicio');

    banco.db.execute(
      "UPDATE sessoes SET ultima_atividade = ? WHERE telefone = ?",
      [
        agoraLocal().subtract(const Duration(minutes: 61)).toIso8601String(),
        '5514999999999'
      ],
    );

    await enviar('olá novamente');
    final respostaAposCancelamento =
        jsonEncode(wa.consumirMensagensSimuladas().last);
    expect(respostaAposCancelamento, contains('Bem-vindo'));
    expect(respostaAposCancelamento, contains('Como podemos ajudar?'));
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

  test('mensagem secundária de lote agrupado continua deduplicada após retry',
      () async {
    const idAgrupado = 'wa_secundaria_ja_processada';
    banco.registrarMensagemAgrupadaComoProcessada(idAgrupado);
    banco.db.execute(
      'INSERT INTO webhook_entrada(id,payload,criado_em) VALUES (?,?,?)',
      [
        idAgrupado,
        jsonEncode({
          'id': idAgrupado,
          'telefone': '5514999999999',
          'nome': 'Teste',
          'texto': 'conf_confirmar',
          'tipo': 'text',
        }),
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
    final api = Api(banco, AuthService(), bot, PushService(banco));

    await api.processarPendentes();

    expect(wa.consumirMensagensSimuladas(), isEmpty);
    expect(banco.db.select('SELECT * FROM webhook_entrada'), isEmpty);
    expect(
      banco.db.select('SELECT status FROM mensagens_processadas WHERE id = ?',
          [idAgrupado]).single['status'],
      'done',
    );
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

  test('envia imagem usando upload de mídia da API oficial', () async {
    final file = File('${temp.path}/imagem.env')
      ..writeAsStringSync(
          'ADMIN_PASSWORD=senha-de-teste\nWHATSAPP_ACCESS_TOKEN=token-teste\nWHATSAPP_PHONE_NUMBER_ID=numero-teste');
    Env.carregar(file.path);
    wa.fechar();
    var uploadChamado = false;
    var mensagemEnviada = false;
    wa = WhatsAppService(banco, client: MockClient((request) async {
      if (request.url.path.endsWith('/media')) {
        uploadChamado = true;
        expect(
            request.headers['content-type'], startsWith('multipart/form-data'));
        return http.Response(jsonEncode({'id': 'media-teste'}), 200);
      }
      mensagemEnviada = true;
      final corpo = jsonDecode(request.body) as Map;
      expect(corpo['type'], 'image');
      expect((corpo['image'] as Map)['id'], 'media-teste');
      return http.Response('{}', 200);
    }));

    await wa.enviarImagemCardapio(
        '5514999999999', [0xff, 0xd8, 0xff], 'image/jpeg');
    await wa.drenar();

    expect(uploadChamado, isTrue);
    expect(mensagemEnviada, isTrue,
        reason: banco.db
            .select(
                "SELECT status, erro FROM whatsapp_saida WHERE canal='meta'")
            .toString());
    expect(
        banco.db
            .select("SELECT status FROM whatsapp_saida WHERE canal='meta'")
            .single['status'],
        'enviado');
  });

  test('API autenticada recebe imagem válida para o cardápio', () async {
    final auth = AuthService();
    final token = auth.login('senha-de-teste', 'imagem').token!;
    final api = Api(banco, auth, bot, PushService(banco));
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p8sAAAAASUVORK5CYII=',
    );
    final resposta = await api.handler(Request(
      'PUT',
      Uri.parse('http://localhost/api/cardapio/imagem'),
      headers: {
        'authorization': 'Bearer $token',
        'content-type': 'image/png',
      },
      body: bytes,
    ));

    expect(resposta.statusCode, 200);
    expect(
        jsonDecode(await resposta.readAsString())['imagemConfigurada'], true);
    expect(banco.obterImagemCardapio()!['dados'], orderedEquals(bytes));
    await api.fechar();
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

  test('fluxo ponta a ponta de entrega com Pix cria o pedido confirmado',
      () async {
    await montar(entrega: true, pagamento: 'pag_pix');
    expect(sessao()['etapa'], 'confirmacao');
    expect(banco.listarPedidos(), isEmpty);

    await enviar('conf_confirmar');

    final pedidos = banco.listarPedidos();
    expect(pedidos, hasLength(1));
    expect(pedidos.single['status'], 'novo');
    expect(pedidos.single['recebimento'], 'entrega');
    expect(pedidos.single['pagamento'], 'pix');
    expect(pedidos.single['endereco'], contains('Rua das Flores'));
  });

  test('fluxo ponta a ponta de retirada com dinheiro e troco conclui',
      () async {
    await montar(pagamento: 'pag_dinheiro');
    expect(sessao()['etapa'], 'confirmacao');

    await enviar('conf_confirmar');

    final pedido = banco.listarPedidos().single;
    expect(pedido['recebimento'], 'retirada');
    expect(pedido['pagamento'], 'dinheiro');
    expect(pedido['troco_para'], isNull);
    expect(pedido['status'], 'novo');
  });

  test('pedido incompleto atravessa correção, observação e confirmação',
      () async {
    await enviar('inicio_pedido');
    await enviar('1');
    await enviar('1');
    await enviar('1');
    await enviar('2');
    await enviar('outro_nao');
    await enviar('rec_retirada');
    await enviar('pag_pix');
    await enviar('sem cebola e capricha no molho');
    expect(sessao()['etapa'], 'confirmacao');
    expect(sessao()['dados']['observacao'], contains('sem cebola'));
  });

  test('transforma recorrência de erros em sugestões de melhoria', () {
    banco.log('WARN', 'ia_indisponivel_fallback_bot', 'timeout');
    banco.log('WARN', 'ia_indisponivel_fallback_bot', 'cota');
    banco.log('ERROR', 'bot_erro', 'StateError');

    final sugestoes = banco.sugestoesMelhoria();
    final ia = sugestoes
        .firstWhere((item) => item['evento'] == 'ia_indisponivel_fallback_bot');
    expect(ia['quantidade'], 2);
    expect(ia['titulo'], contains('disponibilidade'));
    expect(ia['acao'], isNotEmpty);
  });

  test('ignora logs antigos ao gerar sugestões', () {
    banco.db.execute(
      "INSERT INTO logs (nivel, evento, detalhes, criado_em) VALUES (?, ?, ?, ?)",
      ['ERROR', 'bot_erro', 'antigo', '2000-01-01T00:00:00.000Z'],
    );
    expect(banco.sugestoesMelhoria(), isEmpty);
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

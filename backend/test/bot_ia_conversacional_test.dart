import 'dart:convert';
import 'dart:async';

import 'package:ao_ponto_backend/banco/banco.dart';
import 'package:ao_ponto_backend/bot/bot_service.dart';
import 'package:ao_ponto_backend/modelos/mensagem_whatsapp.dart';
import 'package:ao_ponto_backend/servicos/groq_atendimento_service.dart';
import 'package:ao_ponto_backend/servicos/whatsapp_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late Banco banco;
  late WhatsAppService whatsapp;
  late BotService bot;
  late GroqAtendimentoService ia;
  late Map<String, dynamic> outputModel;

  var sequenciaMensagem = 0;

  Future<void> send(String text) => bot.processar(MensagemWhatsApp(
        id: 'msg_${sequenciaMensagem++}_'
            '${DateTime.now().microsecondsSinceEpoch}_${text.hashCode}',
        telefone: '5514666600001',
        nome: 'Teste',
        texto: text,
      ));

  Map<String, dynamic> sessao() => banco.obterSessao('5514666600001')!;

  Map<String, dynamic> dados() =>
      Map<String, dynamic>.from(sessao()['dados'] as Map);

  List<Map> itensSalvos() =>
      (dados()['itens'] as List? ?? const []).cast<Map>();

  void salvarSessao(String etapa, Map<String, dynamic> valores) {
    banco.salvarSessao(
      telefone: '5514666600001',
      nome: 'Teste',
      etapa: etapa,
      dados: valores,
    );
  }

  List<String> textos() => whatsapp
      .consumirMensagensSimuladas()
      .where((reply) => reply['type'] == 'text')
      .map((reply) => ((reply['text'] as Map)['body']).toString())
      .toList();

  void usarIaComErro() {
    ia.fechar();
    ia = GroqAtendimentoService(
      apiKey: 'chave-de-teste',
      client: MockClient(
        (_) async => http.Response('{"error": {"message": "falha"}}', 500),
      ),
    );
    bot = BotService(banco, whatsapp, ia: ia);
  }

  Map<String, dynamic> itemSalvo({
    String tamanho = 'Pequena',
    int quantidade = 1,
    String mistura = 'Calabresa acebolada',
    String acompanhamento = 'Batata',
  }) {
    const tamanhos = {
      'Pequena': ('tam_pequena', 8.0),
      'Média': ('tam_media', 15.0),
      'Grande': ('tam_grande', 20.0),
    };
    const misturas = {
      'Bife acebolado': 'mis_bife',
      'Filé de frango': 'mis_frango',
      'Calabresa acebolada': 'mis_calabresa',
      'Carne moída': 'mis_carne_moida',
    };
    const acompanhamentos = {
      'Macarrão': 'aco_macarrao',
      'Batata': 'aco_batata',
    };
    return {
      'tamanhoId': tamanhos[tamanho]!.$1,
      'tamanhoNome': tamanho,
      'precoUnitario': tamanhos[tamanho]!.$2,
      'misturaId': misturas[mistura]!,
      'misturaNome': mistura,
      'acompanhamentoId': acompanhamentos[acompanhamento]!,
      'acompanhamentoNome': acompanhamento,
      'quantidade': quantidade,
      'arrozDesativado': true,
      'feijaoDesativado': true,
    };
  }

  setUp(() {
    outputModel = {
      'tipo': 'pedido',
      'texto': '',
      'itens': <dynamic>[],
      'finalizarItens': false,
    };
    banco = Banco(caminhoBanco: ':memory:');
    final wrapper = banco.obterConfiguracao();
    final config = Map<String, dynamic>.from(wrapper['dados'] as Map)
      ..['modoAtendimento'] = 'ia'
      ..['estadoBot'] = 'atendendo'
      ..['botAtivo'] = true
      ..['usarHorarioAutomatico'] = false
      ..['enderecoRetirada'] = 'Rua da Loja, 10'
      ..['chavePix'] = 'chave-teste';
    banco.db.execute(
      'UPDATE configuracao SET json = ? WHERE id = 1',
      [jsonEncode(config)],
    );
    whatsapp = WhatsAppService(banco);
    ia = GroqAtendimentoService(
      apiKey: 'chave-de-teste',
      client: MockClient((_) async => httpResponse(outputModel)),
    );
    bot = BotService(banco, whatsapp, ia: ia);
  });

  tearDown(() {
    ia.fechar();
    banco.fechar();
  });

  test('confirma um pedido com "pode confirmar" no resumo', () async {
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'credito',
      'bebidas': <dynamic>[],
    });

    await send('pode confirmar');

    expect(banco.listarPedidos(), hasLength(1));
    expect(textos().join('\n'), contains('RECEBIDO'));
  });

  test('retomada fica silenciosa e processa a próxima mensagem do cliente',
      () async {
    await send('atendente');
    textos();

    await bot.retomarAtendimentoHumano('5514666600001');

    expect(textos(), isEmpty);
    await send('quero uma marmita');

    expect(sessao()['etapa'], 'ia_pedido');
    expect(textos().join('\n'), contains('Qual tamanho você prefere'));
    expect(dados().containsKey('aguardaBoasVindas'), isFalse);
  });

  test('retomada do painel espera a mensagem em andamento terminar', () async {
    final respostaLiberada = Completer<http.Response>();
    ia.fechar();
    ia = GroqAtendimentoService(
      apiKey: 'chave-de-teste',
      client: MockClient((_) => respostaLiberada.future),
    );
    bot = BotService(banco, whatsapp, ia: ia);
    salvarSessao('inicio', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': <dynamic>[],
    });

    final mensagem = send('tem entrega?');
    await Future<void>.delayed(Duration.zero);
    expect(respostaLiberada.isCompleted, isFalse);
    final retomada = bot.retomarAtendimentoHumano('5514666600001');

    respostaLiberada.complete(httpResponse({
      'tipo': 'duvida',
      'texto': 'Sim, temos entrega.',
      'itens': <dynamic>[],
      'finalizarItens': false,
    }));
    await mensagem;
    await retomada;

    expect(textos().join('\n'), contains('Barra Bonita'));
    expect(sessao()['etapa'], 'inicio');
    expect(dados()['aguardaBoasVindas'], isTrue);
  });

  test('não confirma o resumo com "ok" ambíguo', () async {
    outputModel = {
      'tipo': 'escolha',
      'texto': 'conf_confirmar',
      'itens': <dynamic>[],
      'finalizarItens': false,
    };
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'credito',
      'bebidas': <dynamic>[],
    });

    await send('ok');

    expect(banco.listarPedidos(), isEmpty);
    expect(sessao()['etapa'], 'confirmacao');
    expect(textos().join('\n'), contains('sim, confirmar pedido'));
  });

  test('"não quero outra marmita" mantém as marmitas já escolhidas', () async {
    usarIaComErro();
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo(quantidade: 2)],
      'recebimento': 'retirada',
      'pagamento': 'pix',
      'bebidas': <dynamic>[],
    });

    await send('não quero outra marmita');

    expect(sessao()['etapa'], 'confirmacao');
    expect(itensSalvos().single['quantidade'], 2);
    expect(textos().join('\n'), contains('mantive o pedido atual'));
  });

  test('responde dúvida sobre o resumo sem confirmar mesmo se IA erra tipo',
      () async {
    outputModel = {
      'tipo': 'pedido',
      'texto': '',
      'itens': <dynamic>[],
      'finalizarItens': false,
    };
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'credito',
      'bebidas': <dynamic>[],
    });

    await send('o valor já inclui a taxa?');

    expect(banco.listarPedidos(), isEmpty);
    expect(sessao()['etapa'], 'confirmacao');
  });

  test('confirma resumo com resposta afirmativa natural mais longa', () async {
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'credito',
      'bebidas': <dynamic>[],
    });

    await send('beleza, pode confirmar o pedido');

    expect(banco.listarPedidos(), hasLength(1));
  });

  test('não confirma resumo quando a resposta pede alteração', () async {
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'credito',
      'bebidas': <dynamic>[],
    });

    await send('isso, mas troca a batata por macarrão');

    expect(banco.listarPedidos(), isEmpty);
    expect(sessao()['etapa'], 'confirmacao');
  });

  test('troca acompanhamento no resumo e mostra o resumo atualizado', () async {
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'credito',
      'bebidas': <dynamic>[],
    });

    await send('troca o acompanhamento por macarrão');

    expect(itensSalvos().single['acompanhamentoNome'], 'Macarrão');
    expect(sessao()['etapa'], 'confirmacao');
    final resposta = textos().join('\n');
    expect(resposta, contains('Macarrão'));
    expect(resposta, contains('CONFIRA SEU PEDIDO'));
  });

  test('infere acompanhamento quando cliente diz troca batata por macarrão',
      () async {
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'credito',
      'bebidas': <dynamic>[],
    });

    await send('troca a batata por macarrão');

    expect(itensSalvos().single['acompanhamentoNome'], 'Macarrão');
    expect(textos().join('\n'), contains('CONFIRA SEU PEDIDO'));
  });

  test('troca o tamanho no resumo e recalcula o subtotal', () async {
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'credito',
      'bebidas': <dynamic>[],
    });

    await send('muda o tamanho para média');

    expect(itensSalvos().single['tamanhoNome'], 'Média');
    expect(itensSalvos().single['precoUnitario'], 15.0);
    expect(textos().join('\n'), contains('TOTAL: R\$ 17,00'));
  });

  test('trocar para tamanho com mais misturas solicita as escolhas faltantes',
      () async {
    usarIaComErro();
    final menu = banco.obterCardapio();
    final media = (menu['tamanhos'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((item) => item['nome'] == 'Média');
    media['quantidadeMisturas'] = 2;
    banco.atualizarCardapio(menu);
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'pix',
      'bebidas': <dynamic>[],
    });

    await send('troca o tamanho para média');

    expect(sessao()['etapa'], 'confirmacao');
    expect(itensSalvos().single['tamanhoNome'], 'Pequena');
    expect(dados()['edicaoMarmitaResumo']['campo'], 'misturas');
    expect(textos().join('\n'), contains('precisa de 2 mistura'));
    textos();

    await send('filé de frango');
    expect(itensSalvos().single['tamanhoNome'], 'Pequena');
    expect(dados()['edicaoMarmitaResumo']['selecionadas'], ['mis_frango']);
    textos();

    await send('calabresa');

    expect(itensSalvos().single['tamanhoNome'], 'Média');
    expect(itensSalvos().single['quantidadeMisturas'], 2);
    expect(itensSalvos().single['misturaNomes'], [
      'Filé de frango',
      'Calabresa acebolada',
    ]);
    expect(dados().containsKey('edicaoMarmitaResumo'), isFalse);
    expect(textos().join('\n'), contains('TOTAL: R\$ 15,00'));
  });

  test('nova marmita de tamanho com mais escolhas não entra incompleta',
      () async {
    usarIaComErro();
    final menu = banco.obterCardapio();
    final media = (menu['tamanhos'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((item) => item['nome'] == 'Média');
    media['quantidadeMisturas'] = 2;
    banco.atualizarCardapio(menu);
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'entrega',
      'endereco': 'Rua Teste, 100',
      'cidadeEntrega': 'Barra Bonita',
      'ufEntrega': 'SP',
      'cidadeConfirmadaCliente': true,
      'taxaEntregaCongelada': 8.0,
      'pagamento': 'credito',
      'bebidas': <dynamic>[],
    });

    await send('mais uma marmita média');
    expect(itensSalvos(), hasLength(1));
    expect(dados()['edicaoMarmitaResumo']['nova'], isTrue);
    expect(dados()['endereco'], 'Rua Teste, 100');
    expect(dados()['pagamento'], 'credito');
    textos();

    await send('filé de frango');
    expect(itensSalvos(), hasLength(1));
    textos();
    await send('calabresa');

    expect(itensSalvos(), hasLength(2));
    expect(itensSalvos()[1]['tamanhoNome'], 'Média');
    expect(itensSalvos()[1]['misturaNomes'], [
      'Filé de frango',
      'Calabresa acebolada',
    ]);
    expect(dados()['endereco'], 'Rua Teste, 100');
    expect(dados()['cidadeEntrega'], 'Barra Bonita');
    expect(dados()['taxaEntregaCongelada'], 8.0);
    expect(dados()['pagamento'], 'credito');
    expect(textos().join('\n'), contains('TOTAL: R\$ 33,00'));
  });

  test('atualiza quantidade da marmita no resumo', () async {
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'credito',
      'bebidas': <dynamic>[],
    });

    await send('altera a quantidade para 3 marmitas');

    expect(itensSalvos().single['quantidade'], 3);
    expect(textos().join('\n'), contains('TOTAL: R\$ 26,00'));
  });

  test('não cancela quando o cliente nega o resumo', () async {
    outputModel = {
      'tipo': 'escolha',
      'texto': 'conf_cancelar',
      'itens': <dynamic>[],
      'finalizarItens': false,
    };
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'credito',
      'bebidas': <dynamic>[],
    });

    await send('não');

    final resposta = textos().join('\n');
    expect(resposta, contains('alterar'));
    expect(resposta, isNot(contains('Tem certeza')));
    expect(sessao()['etapa'], 'confirmacao');
    expect(banco.listarPedidos(), isEmpty);
  });

  test('negação na confirmação de cancelamento mantém o pedido', () async {
    outputModel = {
      'tipo': 'escolha',
      'texto': 'cancelar_sim',
      'itens': <dynamic>[],
      'finalizarItens': false,
    };
    salvarSessao('confirmar_cancelamento', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      '_etapaAntesCancelamento': 'confirmacao',
      'bebidas': <dynamic>[],
    });

    await send('não');

    expect(textos().join('\n'), contains('Pedido mantido'));
    expect(sessao()['etapa'], 'confirmacao');
    expect(itensSalvos(), hasLength(1));
    expect(banco.listarPedidos(), isEmpty);
  });

  test('sim isolado não cancela sem intenção explícita de cancelar', () async {
    salvarSessao('confirmar_cancelamento', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      '_etapaAntesCancelamento': 'confirmacao',
      'bebidas': <dynamic>[],
    });

    await send('sim');

    expect(sessao()['etapa'], 'confirmar_cancelamento');
    expect(itensSalvos(), hasLength(1));
    expect(banco.listarPedidos(), isEmpty);
    expect(textos().join('\n'), contains('sim, cancelar pedido'));
  });

  test('resposta vaga no cancelamento não apaga o pedido', () async {
    salvarSessao('confirmar_cancelamento', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      '_etapaAntesCancelamento': 'confirmacao',
      'bebidas': <dynamic>[],
    });

    await send('isso');

    expect(sessao()['etapa'], 'confirmar_cancelamento');
    expect(itensSalvos(), hasLength(1));
    expect(banco.listarPedidos(), isEmpty);
    expect(textos().join('\n'), contains('sim, cancelar pedido'));
  });

  test('troca a mistura de uma marmita já escolhida sem duplicar', () async {
    salvarSessao('ia_pedido', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': <dynamic>[],
      'rascunhoPedidoIA': {
        'itens': [
          {
            'indice': 1,
            'tamanho': 'Pequena',
            'quantidade': 1,
            'mistura': 'Calabresa acebolada',
            'acompanhamento': 'Batata',
          }
        ],
      },
    });

    await send('trocar a mistura para frango');

    final itens = itensSalvos();
    expect(itens, hasLength(1));
    expect(itens.single['misturaNome'], 'Filé de frango');
    expect(sessao()['etapa'], 'adicionar_outro');
  });

  test('pergunta qual linha alterar quando o resumo tem combinações diferentes',
      () async {
    usarIaComErro();
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [
        itemSalvo(),
        itemSalvo(
          tamanho: 'Média',
          mistura: 'Filé de frango',
          acompanhamento: 'Macarrão',
        ),
      ],
      'recebimento': 'retirada',
      'pagamento': 'pix',
      'bebidas': <dynamic>[],
    });

    await send('troca a mistura por bife');

    expect(itensSalvos()[0]['misturaNome'], 'Calabresa acebolada');
    expect(itensSalvos()[1]['misturaNome'], 'Filé de frango');
    expect(
        dados()['acaoPendenteResumo']['tipo'], 'identificar_alteracao_marmita');
    expect(textos().join('\n'), contains('Qual combinação você quer alterar?'));
    textos();

    await send('marmita 2');

    expect(itensSalvos()[0]['misturaNome'], 'Calabresa acebolada');
    expect(itensSalvos()[1]['misturaNome'], 'Bife acebolado');
    expect(dados().containsKey('acaoPendenteResumo'), isFalse);
    expect(textos().join('\n'), contains('CONFIRA SEU PEDIDO'));
  });

  test('captura tamanho, quantidade, mistura e acompanhamento de uma vez',
      () async {
    salvarSessao('ia_pedido', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': <dynamic>[],
      'rascunhoPedidoIA': {'itens': <dynamic>[]},
    });

    await send('duas pequenas de calabresa com batata');

    final itens = itensSalvos();
    expect(itens, hasLength(1));
    expect(itens.single['tamanhoNome'], 'Pequena');
    expect(itens.single['quantidade'], 2);
    expect(itens.single['misturaNome'], 'Calabresa acebolada');
    expect(itens.single['acompanhamentoNome'], 'Batata');
    expect(sessao()['etapa'], 'adicionar_outro');
  });

  test('adiciona uma nova marmita sem sobrescrever a anterior', () async {
    salvarSessao('ia_pedido', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'rascunhoPedidoIA': {
        'itens': [
          {
            'indice': 1,
            'tamanho': 'Pequena',
            'quantidade': 1,
            'mistura': 'Calabresa acebolada',
            'acompanhamento': 'Batata',
          }
        ],
      },
    });

    await send('uma pequena de frango com batata');

    final itens = itensSalvos();
    expect(itens, hasLength(2));
    expect(itens[0]['misturaNome'], 'Calabresa acebolada');
    expect(itens[0]['acompanhamentoNome'], 'Batata');
    expect(itens[1]['misturaNome'], 'Filé de frango');
    expect(itens[1]['acompanhamentoNome'], 'Batata');
    expect(sessao()['etapa'], 'adicionar_outro');
  });

  test('pergunta sobre tempo no endereço é respondida sem salvar endereço',
      () async {
    outputModel = {
      'tipo': 'duvida',
      'texto': 'O pedido costuma sair em cerca de 40 minutos.',
      'itens': <dynamic>[],
      'finalizarItens': false,
    };
    salvarSessao('endereco', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'entrega',
    });

    await send('demora quanto tempo?');

    expect(textos().join('\n'), contains('40 minutos'));
    expect(sessao()['etapa'], 'endereco');
    expect(dados()['endereco'], isNull);
  });

  test('falha da IA no endereço não salva a pergunta como endereço', () async {
    usarIaComErro();
    salvarSessao('endereco', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'entrega',
    });

    await send('demora quanto tempo?');

    expect(sessao()['etapa'], 'endereco');
    expect(dados()['endereco'], isNull);
  });

  test('fallback contextual pergunta o detalhe que falta', () async {
    usarIaComErro();
    salvarSessao('ia_pedido', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': <dynamic>[],
      'rascunhoPedidoIA': {
        'itens': [
          {'indice': 1, 'tamanho': 'Pequena', 'quantidade': 1}
        ],
      },
    });

    await send('queria aquele lá');

    expect(textos().join('\n'), contains('Qual mistura você prefere'));
    expect(sessao()['etapa'], 'ia_pedido');
  });

  test('captura uma quantidade isolada para a marmita em montagem', () async {
    salvarSessao('ia_pedido', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': <dynamic>[],
      'rascunhoPedidoIA': {
        'itens': [
          {
            'indice': 1,
            'tamanho': 'Pequena',
            'mistura': 'Calabresa acebolada',
            'acompanhamento': 'Batata',
          }
        ],
      },
    });

    await send('duas');

    final itens = itensSalvos();
    expect(itens, hasLength(1));
    expect(itens.single['quantidade'], 2);
    expect(itens.single['misturaNome'], 'Calabresa acebolada');
    expect(sessao()['etapa'], 'adicionar_outro');
  });

  test('ao escolher entrega, pergunta o endereço e a cidade', () async {
    usarIaComErro();
    salvarSessao('recebimento', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'bebidas': <dynamic>[],
    });

    await send('rec_entrega');

    expect(sessao()['etapa'], 'endereco');
    expect(
      textos().join('\n'),
      contains('Qual será o endereço para entrega e a cidade?'),
    );
  });

  test(
      'ao finalizar marmitas no modo IA, pergunta endereço em vez de recebimento',
      () async {
    usarIaComErro();
    salvarSessao('adicionar_outro', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'bebidas': <dynamic>[],
    });

    await send('não');

    expect(sessao()['etapa'], 'endereco');
    expect(textos().join('\n'),
        contains('Qual será o endereço para entrega e a cidade?'));
    expect(textos().join('\n'),
        isNot(contains('Como você quer receber seu pedido?')));
  });

  test('aceita retirada respondida na etapa de endereço', () async {
    usarIaComErro();
    salvarSessao('endereco', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'entrega',
      'bebidas': <dynamic>[],
    });

    await send('vou buscar na loja');

    expect(dados()['recebimento'], 'retirada');
    expect(dados()['endereco'], 'Rua da Loja, 10');
    expect(sessao()['etapa'], 'troco');
    expect(textos().join('\n'), contains('Retirada em:'));
  });

  test('pergunta a cidade com os nomes curtos das opções', () async {
    usarIaComErro();
    salvarSessao('cidade_entrega', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'entrega',
      'endereco': 'Rua Teste, 100',
      'bebidas': <dynamic>[],
    });

    await send('nao sei ainda');

    expect(textos().join('\n'), contains('Barra ou Igaraçu?'));
    expect(sessao()['etapa'], 'cidade_entrega');
  });

  test('pergunta crédito ou débito quando o cliente diz apenas cartão',
      () async {
    usarIaComErro();
    salvarSessao('troco', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'bebidas': <dynamic>[],
    });

    await send('quero pagar no cartão');

    expect(textos().join('\n'), contains('Crédito ou débito?'));
    expect(sessao()['etapa'], 'troco');
  });

  test('informa a taxa da maquininha ao escolher crédito', () async {
    usarIaComErro();
    salvarSessao('troco', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'bebidas': <dynamic>[],
    });

    await send('vou pagar no crédito');

    final resposta = textos().join('\n');
    expect(
      resposta,
      contains('Temos a taxa da maquininha para pagamento no crédito'),
    );
    expect(sessao()['etapa'], 'confirmacao');
    expect(resposta, contains('Taxa da maquininha: R\$ 2,00'));
    expect(resposta, contains('TOTAL: R\$ 10,00'));
  });

  test('usa o total do pedido na pergunta de troco', () async {
    usarIaComErro();
    salvarSessao('pagamento', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'bebidas': <dynamic>[],
    });

    await send('dinheiro');

    final resposta = textos().join('\n');
    expect(resposta,
        contains('Seu pedido ficou R\$ 8,00. Vai precisar de troco?'));
    expect(sessao()['etapa'], 'troco');
  });

  test('responde ao total com cartão e mostra resumo com taxa calculada',
      () async {
    usarIaComErro();
    salvarSessao('troco', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'entrega',
      'taxaEntregaCongelada': 8.0,
      'endereco': 'Rua Teste, 100',
      'cidadeEntrega': 'Barra Bonita',
      'cidadeConfirmadaCliente': true,
      'bebidas': <dynamic>[],
    });

    await send('cartão');
    expect(textos().join('\n'), contains('Crédito ou débito?'));
    expect(sessao()['etapa'], 'troco');
    whatsapp.consumirMensagensSimuladas();

    await send('crédito');

    final resposta = textos().join('\n');
    expect(resposta,
        contains('Temos a taxa da maquininha para pagamento no crédito'));
    expect(resposta, contains('Taxa da maquininha: R\$ 2,00'));
    expect(resposta, contains('TOTAL: R\$ 18,00'));
    expect(sessao()['etapa'], 'confirmacao');
    expect(dados()['pagamento'], 'credito');
  });

  test('entende resposta natural de troco como "sim, para 50"', () async {
    usarIaComErro();
    salvarSessao('troco', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'dinheiro',
      'bebidas': <dynamic>[],
    });

    await send('sim, para 50');

    expect(dados()['trocoPara'], 50.0);
  });

  test('remove uma bebida já lançada no resumo', () async {
    usarIaComErro();
    banco.db.execute(
      "INSERT INTO bebidas (id, nome, preco, ativo, ordem) "
      "VALUES ('beb_coca', 'Coca-Cola', 6.0, 1, 0)",
    );
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'credito',
      'bebidas': [
        {
          'bebidaId': 'beb_coca',
          'nome': 'Coca-Cola',
          'precoUnitario': 6.0,
          'quantidade': 1,
        }
      ],
    });

    await send('tira a coca');

    expect((dados()['bebidas'] as List), isEmpty);
    expect(textos().join('\n'), contains('removi'));
    expect(sessao()['etapa'], 'confirmacao');
  });

  test('trocar bebida mantém a quantidade já pedida', () async {
    usarIaComErro();
    banco.db.execute(
      "INSERT INTO bebidas (id, nome, preco, ativo, ordem) VALUES "
      "('beb_coca', 'Coca-Cola', 6.0, 1, 0), "
      "('beb_guarana', 'Guaraná', 5.0, 1, 1)",
    );
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'pix',
      'bebidas': [
        {
          'bebidaId': 'beb_coca',
          'nome': 'Coca-Cola',
          'precoUnitario': 6.0,
          'quantidade': 3,
        }
      ],
    });

    await send('troca a Coca-Cola por Guaraná');

    expect((dados()['bebidas'] as List).single['nome'], 'Guaraná');
    expect((dados()['bebidas'] as List).single['quantidade'], 3);
    expect(textos().join('\n'), contains('3x Guaraná'));
  });

  test('remove somente uma unidade de uma combinação agregada', () async {
    usarIaComErro();
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo(quantidade: 2)],
      'recebimento': 'retirada',
      'pagamento': 'pix',
      'bebidas': <dynamic>[],
    });

    await send('não vou querer 1 marmita pequena de calabresa');

    expect(itensSalvos(), hasLength(1));
    expect(itensSalvos().single['quantidade'], 1);
    expect(textos().join('\n'), contains('TOTAL: R\$ 8,00'));
  });

  test('pergunta qual combinação remover quando as marmitas são diferentes',
      () async {
    usarIaComErro();
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [
        itemSalvo(quantidade: 2),
        itemSalvo(
          tamanho: 'Média',
          mistura: 'Filé de frango',
          acompanhamento: 'Macarrão',
        ),
      ],
      'recebimento': 'retirada',
      'pagamento': 'pix',
      'bebidas': <dynamic>[],
    });

    await send('não vou querer 1');

    expect(itensSalvos(), hasLength(2));
    expect(dados()['acaoPendenteResumo'], {'tipo': 'remover_marmita'});
    expect(textos().join('\n'), contains('Qual combinação você quer remover?'));
    textos();

    await send('a média de frango com macarrão');

    expect(itensSalvos(), hasLength(1));
    expect(itensSalvos().single['tamanhoNome'], 'Pequena');
    expect(itensSalvos().single['quantidade'], 2);
    expect(dados().containsKey('acaoPendenteResumo'), isFalse);
    expect(textos().join('\n'), contains('CONFIRA SEU PEDIDO'));
  });

  test('recusa explícita do pedido remove todas as marmitas e bebidas',
      () async {
    usarIaComErro();
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo(quantidade: 2)],
      'recebimento': 'retirada',
      'pagamento': 'pix',
      'bebidas': [
        {
          'bebidaId': 'beb_coca',
          'nome': 'Coca-Cola',
          'precoUnitario': 6.0,
          'quantidade': 1,
        }
      ],
    });

    await send('não quero pedir');

    expect(sessao()['etapa'], 'inicio');
    expect(itensSalvos(), isEmpty);
    expect(textos().join('\n'), contains('removi todas as marmitas e bebidas'));
    expect(banco.listarPedidos(), isEmpty);
  });

  test('troca de pagamento mantém bebidas e observação do pedido', () async {
    usarIaComErro();
    banco.db.execute(
      "INSERT INTO bebidas (id, nome, preco, ativo, ordem) "
      "VALUES ('beb_coca', 'Coca-Cola', 6.0, 1, 0)",
    );
    salvarSessao('pagamento', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'pix',
      'observacao': 'Sem cebola',
      'bebidas': [
        {
          'bebidaId': 'beb_coca',
          'nome': 'Coca-Cola',
          'precoUnitario': 6.0,
          'quantidade': 1,
        }
      ],
    });

    await send('crédito');

    expect(dados()['pagamento'], 'credito');
    expect(dados()['observacao'], 'Sem cebola');
    expect((dados()['bebidas'] as List), hasLength(1));
    final resposta = textos().join('\n');
    expect(resposta, contains('Coca-Cola'));
    expect(resposta, contains('Sem cebola'));
  });

  test('adiciona outra marmita depois do resumo sem refazer o pedido',
      () async {
    usarIaComErro();
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'credito',
      'bebidas': <dynamic>[],
    });

    await send('vou querer outra marmita');

    final resposta = textos().join('\n');
    expect(sessao()['etapa'], 'confirmacao');
    expect(itensSalvos(), hasLength(1));
    expect(itensSalvos().single['quantidade'], 2);
    expect(resposta, contains('CONFIRA SEU PEDIDO'));
    expect(resposta.toLowerCase(), isNot(contains('endereço')));
    expect(resposta.toLowerCase(), isNot(contains('precisar de troco')));
    expect(dados()['recebimento'], 'retirada');
    expect(dados()['pagamento'], 'credito');
  });

  test('adiciona duas médias depois do resumo e recalcula o total', () async {
    usarIaComErro();
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'pix',
      'bebidas': <dynamic>[],
    });

    await send('vou querer mais duas médias');

    final itens = itensSalvos();
    expect(sessao()['etapa'], 'confirmacao');
    expect(itens, hasLength(2));
    expect(itens[0]['tamanhoNome'], 'Pequena');
    expect(itens[0]['quantidade'], 1);
    expect(itens[1]['tamanhoNome'], 'Média');
    expect(itens[1]['quantidade'], 2);
    expect(itens[1]['misturaNome'], 'Calabresa acebolada');
    expect(itens[1]['acompanhamentoNome'], 'Batata');
    final resposta = textos().join('\n');
    expect(resposta, contains('2x Média'));
    expect(resposta, contains('TOTAL: R\$ 38,00'));
    expect(dados()['pagamento'], 'pix');
  });

  test('acrescenta uma marmita igual à anterior agregando a quantidade',
      () async {
    usarIaComErro();
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'pix',
      'bebidas': <dynamic>[],
    });

    await send('vou querer mais uma igual à anterior');

    final itens = itensSalvos();
    expect(sessao()['etapa'], 'confirmacao');
    expect(itens, hasLength(1));
    expect(itens.single['quantidade'], 2);
    expect(textos().join('\n'), contains('TOTAL: R\$ 16,00'));
  });

  test('adiciona marmita com mistura e acompanhamento diferentes no resumo',
      () async {
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'retirada',
      'pagamento': 'credito',
      'bebidas': <dynamic>[],
    });

    await send('adiciona outra marmita pequena de frango com macarrão');

    final itens = itensSalvos();
    expect(itens, hasLength(2));
    expect(itens[1]['misturaNome'], 'Filé de frango');
    expect(itens[1]['acompanhamentoNome'], 'Macarrão');
    expect(textos().join('\n'), contains('CONFIRA SEU PEDIDO'));
  });

  test('preserva endereço, cidade, bebidas e taxa de cartão ao adicionar',
      () async {
    usarIaComErro();
    banco.db.execute(
      "INSERT INTO bebidas (id, nome, preco, ativo, ordem) "
      "VALUES ('beb_coca', 'Coca-Cola', 6.0, 1, 0)",
    );
    salvarSessao('confirmacao', {
      'clienteNome': 'Teste',
      'boasVindasEnviada': true,
      'itens': [itemSalvo()],
      'recebimento': 'entrega',
      'endereco': 'Rua Teste, 100',
      'cidadeEntrega': 'Barra Bonita',
      'ufEntrega': 'SP',
      'cidadeConfirmadaCliente': true,
      'taxaEntregaCongelada': 8.0,
      'pagamento': 'credito',
      'bebidas': [
        {
          'bebidaId': 'beb_coca',
          'nome': 'Coca-Cola',
          'precoUnitario': 6.0,
          'quantidade': 1,
        }
      ],
    });

    await send('vou querer outra marmita');

    final sessaoApos = dados();
    final resposta = textos().join('\n');
    expect(sessao()['etapa'], 'confirmacao');
    expect(sessaoApos['recebimento'], 'entrega');
    expect(sessaoApos['endereco'], 'Rua Teste, 100');
    expect(sessaoApos['cidadeEntrega'], 'Barra Bonita');
    expect(sessaoApos['taxaEntregaCongelada'], 8.0);
    expect(sessaoApos['pagamento'], 'credito');
    expect((sessaoApos['bebidas'] as List), hasLength(1));
    expect(resposta, contains('🚚 Entrega'));
    expect(resposta, contains('Rua Teste, 100'));
    expect(resposta, contains('Coca-Cola'));
    expect(resposta, contains('Taxa da maquininha: R\$ 2,00'));
    expect(resposta, contains('TOTAL: R\$ 32,00'));
    expect(resposta.toLowerCase(), isNot(contains('qual será o endereço')));
    expect(resposta.toLowerCase(), isNot(contains('crédito ou débito')));
  });

  test('encaminha após a terceira resposta idêntica consecutiva', () async {
    const resposta = 'Qual tamanho de marmita você deseja?';
    banco.salvarSessao(
      telefone: '5514666600099',
      nome: 'Cliente com pedido',
      etapa: 'confirmacao',
      dados: {
        'itens': [itemSalvo()],
        'endereco': 'Rua Teste, 100',
        'cidadeEntrega': 'Barra Bonita',
        'pagamento': 'dinheiro',
      },
    );
    await whatsapp.enviarTexto('5514666600099', resposta);
    await whatsapp.enviarTexto('5514666600099', resposta);
    final duasPrimeiras = whatsapp
        .consumirMensagensSimuladas()
        .map((item) => ((item['text'] as Map)['body']).toString())
        .toList();

    // A contagem sobrevive à recriação do serviço/processo.
    whatsapp = WhatsAppService(banco);
    await whatsapp.enviarTexto('5514666600099', resposta);

    final enviadas = [
      ...duasPrimeiras,
      ...whatsapp
          .consumirMensagensSimuladas()
          .where((item) => item['to'] == '5514666600099')
          .map((item) => ((item['text'] as Map)['body']).toString()),
    ];
    expect(enviadas, [
      resposta,
      resposta,
      'Não consegui entender com segurança. Encaminhei a conversa para um atendente, que continuará o atendimento por aqui.',
    ]);
    expect(banco.obterSessao('5514666600099')?['modoHumano'], isTrue);
    final dadosPreservados =
        banco.obterSessao('5514666600099')!['dados'] as Map;
    expect(dadosPreservados['endereco'], 'Rua Teste, 100');
    expect(dadosPreservados['cidadeEntrega'], 'Barra Bonita');
    expect(dadosPreservados['pagamento'], 'dinheiro');
    expect(dadosPreservados['itens'], hasLength(1));
    expect(banco.listarSessoesHumanas(), isNotEmpty);

    await whatsapp.enviarTexto('5514666600099', 'Outra tentativa');
    expect(whatsapp.consumirMensagensSimuladas(), isEmpty);
  });

  test('uma resposta diferente reinicia a contagem de repetição', () async {
    const repetida = 'Qual tamanho de marmita você deseja?';
    await whatsapp.enviarTexto('5514666600098', repetida);
    await whatsapp.enviarTexto('5514666600098', repetida);
    await whatsapp.enviarTexto(
        '5514666600098', 'Posso ajudar com outra coisa?');
    await whatsapp.enviarTexto('5514666600098', repetida);
    await whatsapp.enviarTexto('5514666600098', repetida);

    final enviadas = whatsapp.consumirMensagensSimuladas();
    expect(enviadas, hasLength(5));
    expect(banco.obterSessao('5514666600098'), isNull);
  });
}

http.Response httpResponse(Map<String, dynamic> content) => http.Response(
      jsonEncode({
        'choices': [
          {
            'message': {'content': jsonEncode(content)}
          }
        ]
      }),
      200,
    );

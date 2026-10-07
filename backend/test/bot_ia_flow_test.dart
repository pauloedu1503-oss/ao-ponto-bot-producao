import 'dart:convert';

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

  Future<void> send(String text) async {
    final id = 'msg_${sequenciaMensagem++}_'
        '${DateTime.now().microsecondsSinceEpoch}';
    await bot.processar(MensagemWhatsApp(
      id: id,
      telefone: '5514999900001',
      nome: 'Teste',
      texto: text,
    ));
  }

  void startFreshConversation() {
    banco.salvarSessao(
      telefone: '5514999900001',
      nome: 'Teste',
      etapa: 'inicio',
      dados: {'boasVindasEnviada': true, 'itens': []},
    );
  }

  List<String> texts() => whatsapp
      .consumirMensagensSimuladas()
      .where((reply) => reply['type'] == 'text')
      .map((reply) => ((reply['text'] as Map)['body']).toString())
      .toList();

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
      ..['usarHorarioAutomatico'] = false;
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

  test('preserves quantity one across separate natural messages', () async {
    await send('quero uma marmita');
    expect(texts(), contains('Qual tamanho você prefere para sua marmita?'));

    await send('pequena');
    expect(texts(), contains('Qual mistura você prefere na sua marmita?'));

    await send('pode ser calabres');
    expect(
        texts(), contains('Qual acompanhamento você prefere na sua marmita?'));

    await send('pode se batata');
    expect(
        texts().single, contains('Quer incluir outra ou podemos finalizar?'));

    final sessao = banco.obterSessao('5514999900001')!;
    final dados = Map<String, dynamic>.from(sessao['dados'] as Map);
    final itens = (dados['rascunhoPedidoIA'] as Map)['itens'] as List;
    expect(itens.single['quantidade'], 1);
    expect(sessao['etapa'], 'adicionar_outro');
  });

  test('starts collecting size when customer says they want one', () async {
    await send('vou querer uma');

    expect(texts().last, 'Qual tamanho você prefere para sua marmita?');
    final sessao = banco.obterSessao('5514999900001')!;
    expect(sessao['etapa'], 'ia_pedido');
    final dados = Map<String, dynamic>.from(sessao['dados'] as Map);
    final rascunho = dados['rascunhoPedidoIA'] as Map;
    final itens = (rascunho['itens'] as List).cast<Map>();
    expect(itens, hasLength(1));
    expect(itens.single['quantidade'], 1);
  });

  test('collects every configured mixture and accompaniment in AI mode',
      () async {
    final wrapper = banco.obterConfiguracao();
    final config = Map<String, dynamic>.from(wrapper['dados'] as Map)
      ..['estadoBot'] = 'pausado';
    banco.db.execute(
      'UPDATE configuracao SET json = ? WHERE id = 1',
      [jsonEncode(config)],
    );
    final menu = banco.obterCardapio();
    final pequena = (menu['tamanhos'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((item) => item['nome'] == 'Pequena');
    pequena['quantidadeMisturas'] = 2;
    pequena['quantidadeAcompanhamentos'] = 2;
    banco.atualizarCardapio(menu);
    config['estadoBot'] = 'atendendo';
    banco.db.execute(
      'UPDATE configuracao SET json = ? WHERE id = 1',
      [jsonEncode(config)],
    );

    outputModel = {
      'tipo': 'pedido',
      'texto': '',
      'itens': [
        {
          'indice': 1,
          'tamanho': 'Pequena',
          'quantidade': 1,
          'mistura': 'Calabresa acebolada',
          'misturas': ['Calabresa acebolada'],
          'acompanhamento': 'Batata',
          'acompanhamentos': ['Batata'],
          'arroz': null,
          'feijao': null,
        }
      ],
      'finalizarItens': false,
    };
    await send('uma pequena com calabresa e batata');
    var enviados = texts();
    expect(enviados.last, contains('outra mistura'));
    expect(enviados.last, contains('2 de 2'));

    outputModel = {
      'tipo': 'pedido',
      'texto': '',
      'itens': [
        {
          'indice': 1,
          'tamanho': null,
          'quantidade': null,
          'mistura': 'Filé de frango',
          'misturas': ['Filé de frango'],
          'acompanhamento': null,
          'acompanhamentos': <String>[],
          'arroz': null,
          'feijao': null,
        }
      ],
      'finalizarItens': false,
    };
    await send('frango');
    enviados = texts();
    expect(enviados.last, contains('outro acompanhamento'));
    expect(enviados.last, contains('2 de 2'));

    outputModel = {
      'tipo': 'pedido',
      'texto': '',
      'itens': [
        {
          'indice': 1,
          'tamanho': null,
          'quantidade': null,
          'mistura': null,
          'misturas': <String>[],
          'acompanhamento': 'Macarrão',
          'acompanhamentos': ['Macarrão'],
          'arroz': null,
          'feijao': null,
        }
      ],
      'finalizarItens': false,
    };
    await send('macarrão');

    final sessao = banco.obterSessao('5514999900001')!;
    final dados = Map<String, dynamic>.from(sessao['dados'] as Map);
    final rascunho =
        Map<String, dynamic>.from(dados['rascunhoPedidoIA'] as Map);
    final item = (rascunho['itens'] as List).cast<Map>().single;
    expect(item['misturas'], ['Calabresa acebolada', 'Filé de frango']);
    expect(item['acompanhamentos'], ['Batata', 'Macarrão']);
    expect(sessao['etapa'], 'adicionar_outro');
  });

  test('recognizes p, m and g as size answers while collecting a marmita',
      () async {
    for (final (abreviacao, tamanho) in const [
      ('p', 'Pequena'),
      ('m', 'Média'),
      ('g', 'Grande'),
    ]) {
      startFreshConversation();
      await send('quero uma marmita');
      texts();

      await send(abreviacao);

      expect(texts().last, contains('mistura'));
      final sessao = banco.obterSessao('5514999900001')!;
      final dados = Map<String, dynamic>.from(sessao['dados'] as Map);
      final rascunho = dados['rascunhoPedidoIA'] as Map;
      final itens = (rascunho['itens'] as List).cast<Map>();
      expect(itens.single['tamanho'], tamanho);
    }
  });

  test('treats an affirmative continuation as the next item, not a duplicate',
      () async {
    banco.salvarSessao(
      telefone: '5514999900001',
      nome: 'Teste',
      etapa: 'adicionar_outro',
      dados: {
        'clienteNome': 'Teste',
        'itens': [
          {
            'tamanhoId': 'tam_pequena',
            'tamanhoNome': 'Pequena',
            'precoUnitario': 8.0,
            'misturaId': 'mis_calabresa',
            'misturaNome': 'Calabresa acebolada',
            'acompanhamentoId': 'aco_batata',
            'acompanhamentoNome': 'Batata',
            'quantidade': 1,
          }
        ],
        'rascunhoPedidoIA': {
          'itens': [
            {
              'indice': 1,
              'tamanho': 'Pequena',
              'quantidade': 1,
              'mistura': 'Calabresa acebolada',
              'acompanhamento': 'Batata',
            }
          ]
        },
        'boasVindasEnviada': true,
      },
    );

    await send('vou quere');
    final enviados = texts();
    expect(enviados, ['Qual tamanho você prefere para a próxima marmita?']);
    final sessao = banco.obterSessao('5514999900001')!;
    final dados = Map<String, dynamic>.from(sessao['dados'] as Map);
    expect((dados['itens'] as List), hasLength(1));
    expect(sessao['etapa'], 'ia_pedido');
  });

  test('legacy bot mode continues to use interactive start options', () async {
    final wrapper = banco.obterConfiguracao();
    final config = Map<String, dynamic>.from(wrapper['dados'] as Map)
      ..['modoAtendimento'] = 'bot';
    banco.db.execute(
      'UPDATE configuracao SET json = ? WHERE id = 1',
      [jsonEncode(config)],
    );

    await send('oi');
    final replies = whatsapp.consumirMensagensSimuladas();
    expect(replies.any((reply) => reply['type'] == 'interactive'), isTrue);
  });

  test('natural menu requests return the configured menu without buttons',
      () async {
    await send('oq tem hj?');
    final replies = whatsapp.consumirMensagensSimuladas();
    final bodies = replies
        .where((reply) => reply['type'] == 'text')
        .map((reply) => ((reply['text'] as Map)['body']).toString())
        .toList();
    expect(replies.any((reply) => reply['type'] == 'interactive'), isFalse);
    expect(bodies.join('\n'), contains('CARDÁPIO DO DIA'));
    expect(bodies.join('\n'), contains('Calabresa acebolada'));
    expect(bodies.join('\n'), contains('R\$ 8,00'));
  });

  test('configured image menu sends the image instead of menu text', () async {
    banco.salvarImagemCardapio(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p8sAAAAASUVORK5CYII=',
      ),
      'image/png',
    );
    banco.db.execute("UPDATE meta SET valor='imagem' WHERE chave='menu_mode'");

    await send('oq tem hj?');
    final replies = whatsapp.consumirMensagensSimuladas();
    final textos = replies
        .where((reply) => reply['type'] == 'text')
        .map((reply) => ((reply['text'] as Map)['body']).toString())
        .join('\n');
    expect(replies.map((reply) => reply['type']), contains('image'));
    expect(textos, isNot(contains('CARDÁPIO DO DIA')));
    expect(textos, isNot(contains('Calabresa acebolada')));
    final image = replies.singleWhere((reply) => reply['type'] == 'image');
    expect((image['image'] as Map)['mimetype'], 'image/png');
    expect((image['image'] as Map)['data'], isNotEmpty);
  });

  test('understands conversational lead-ins before a menu request', () async {
    startFreshConversation();
    await send('acho que vou pedir, o que tem hoje?');
    expect(texts().join('\n'), contains('CARDÁPIO DO DIA'));
  });

  test('answers delivery and fee from active configured cities', () async {
    startFreshConversation();
    await send('quanto cobra pra entrega em igaracu?');
    final resposta = texts().join('\n');
    expect(resposta, contains('Igaraçu do Tietê'));
    expect(resposta, contains('R\$ 10,00'));
  });

  test('answers Barra Bonita delivery fee', () async {
    startFreshConversation();
    await send('qual a taxa para Barra Bonita?');
    expect(texts().join('\n'), contains('R\$ 8,00'));
  });

  test('declines delivery outside the two served cities', () async {
    startFreshConversation();
    await send('vocês entregam em Jaú?');
    final respostaCidadeFora = texts().join('\n');
    expect(respostaCidadeFora, contains('Atendemos em Barra Bonita'));
    expect(respostaCidadeFora, contains('Igaraçu do Tietê'));
    expect(respostaCidadeFora, contains('R\$ 8,00'));
    expect(respostaCidadeFora, contains('R\$ 10,00'));
  });

  test('lists the two served cities and their fees', () async {
    startFreshConversation();
    await send('quais cidades vocês atendem?');
    final cidades = texts().join('\n');
    expect(cidades, contains('Barra Bonita'));
    expect(cidades, contains('Igaraçu do Tietê'));
    expect(cidades, contains('R\$ 8,00'));
    expect(cidades, contains('R\$ 10,00'));
  });

  test('answers payment methods and does not reveal missing pix key', () async {
    startFreshConversation();
    await send('aceita pix?');
    expect(texts().join('\n'), contains('Sim, aceitamos PIX.'));
  });

  test('does not invent a missing Pix key', () async {
    startFreshConversation();
    await send('qual a chave pix?');
    expect(texts().join('\n'), contains('não tenho uma chave Pix disponível'));
  });

  test('confirms menu changes daily', () async {
    startFreshConversation();
    await send('todo dia tem um cardápio diferente?');
    expect(texts().single, contains('muda a cada dia'));
  });

  test('confirms active menu item availability', () async {
    startFreshConversation();
    await send('tem calabresa?');
    expect(texts().last, contains('Calabresa acebolada está disponível'));
  });

  test('keeps different combinations separate for a multi-item message',
      () async {
    outputModel = {
      'tipo': 'pedido',
      'texto': '',
      'itens': [
        {
          'indice': 1,
          'tamanho': 'Pequena',
          'quantidade': 1,
          'mistura': 'Carne moída',
          'acompanhamento': 'Macarrão',
        },
        {
          'indice': 2,
          'tamanho': 'Pequena',
          'quantidade': 1,
          'mistura': 'Filé de frango',
          'acompanhamento': 'Batata',
        },
      ],
      'finalizarItens': false,
    };
    await send(
        'duas pequenas: uma de carne com macarrão e outra de frango com batata');

    final sessao = banco.obterSessao('5514999900001')!;
    final dados = Map<String, dynamic>.from(sessao['dados'] as Map);
    final itens = (dados['itens'] as List).cast<Map>();
    expect(itens, hasLength(2));
    expect(itens[0]['misturaNome'], 'Carne moída');
    expect(itens[0]['acompanhamentoNome'], 'Macarrão');
    expect(itens[1]['misturaNome'], 'Filé de frango');
    expect(itens[1]['acompanhamentoNome'], 'Batata');
  });

  test('captures quantity and size groups from one natural message', () async {
    await send('vou querer 3 marmitas');
    expect(
      texts().last,
      'Quais tamanhos você prefere para as 3 marmitas?',
    );

    await send('uma pequena e duas media');
    expect(texts().single, 'Qual mistura você prefere na marmita pequena 1?');
    final sessao = banco.obterSessao('5514999900001')!;
    final dados = Map<String, dynamic>.from(sessao['dados'] as Map);
    final itens =
        ((dados['rascunhoPedidoIA'] as Map)['itens'] as List).cast<Map>();
    expect(itens, hasLength(2));
    expect(itens[0]['tamanho'], 'Pequena');
    expect(itens[0]['quantidade'], 1);
    expect(itens[1]['tamanho'], 'Média');
    expect(itens[1]['quantidade'], 2);
  });

  test('keeps incomplete later combinations when an earlier one is complete',
      () async {
    banco.salvarSessao(
      telefone: '5514999900001',
      nome: 'Teste',
      etapa: 'ia_pedido',
      dados: {
        'clienteNome': 'Teste',
        'boasVindasEnviada': true,
        'itens': [
          {
            'tamanhoId': 'tam_pequena',
            'tamanhoNome': 'Pequena',
            'precoUnitario': 8.0,
            'misturaId': 'mis_bife',
            'misturaNome': 'Bife acebolado',
            'acompanhamentoId': 'aco_macarrao',
            'acompanhamentoNome': 'Macarrão',
            'quantidade': 1,
          }
        ],
        'rascunhoPedidoIA': {
          'quantidadeTotalSolicitada': 3,
          'itens': [
            {
              'indice': 1,
              'tamanho': 'Pequena',
              'quantidade': 1,
              'mistura': 'Bife acebolado',
              'acompanhamento': 'Macarrão',
            },
            {
              'indice': 2,
              'tamanho': 'Média',
              'quantidade': 2,
              'mistura': 'Filé de frango',
            },
          ],
        },
      },
    );

    await send('como ta meu pedido agora?');
    final resumo = texts().last;
    expect(resumo, contains('3 marmitas'));
    expect(resumo, contains('Bife acebolado com Macarrão'));
    expect(resumo, contains('2x Média — Filé de frango'));

    await send('??');
    expect(
      texts().last,
      'Qual acompanhamento você prefere nas marmitas médias 1 e 2?',
    );
  });

  test('captures a next marmita mixture while asking for the current side',
      () async {
    banco.salvarSessao(
      telefone: '5514999900001',
      nome: 'Teste',
      etapa: 'ia_pedido',
      dados: {
        'clienteNome': 'Teste',
        'boasVindasEnviada': true,
        'itens': [
          {
            'tamanhoId': 'tam_pequena',
            'tamanhoNome': 'Pequena',
            'precoUnitario': 8.0,
            'misturaId': 'mis_bife',
            'misturaNome': 'Bife acebolado',
            'quantidade': 1,
          }
        ],
        'rascunhoPedidoIA': {
          'itens': [
            {
              'indice': 1,
              'tamanho': 'Pequena',
              'quantidade': 1,
              'mistura': 'Bife acebolado',
            },
            {
              'indice': 2,
              'tamanho': 'Média',
              'quantidade': 2,
            },
          ],
        },
      },
    );

    await send('filé');
    expect(
      texts().single,
      'Qual acompanhamento você prefere na marmita pequena 1?',
    );
    final sessao = banco.obterSessao('5514999900001')!;
    final dados = Map<String, dynamic>.from(sessao['dados'] as Map);
    final itens =
        ((dados['rascunhoPedidoIA'] as Map)['itens'] as List).cast<Map>();
    expect(itens[1]['mistura'], 'Filé de frango');

    await send('macarrão');
    expect(
      texts().single,
      'Qual acompanhamento você prefere nas marmitas médias 1 e 2?',
    );
  });

  test('asks before replacing a mixture already saved on a combination',
      () async {
    banco.salvarSessao(
      telefone: '5514999900001',
      nome: 'Teste',
      etapa: 'ia_pedido',
      dados: {
        'boasVindasEnviada': true,
        'itens': [],
        'rascunhoPedidoIA': {
          'itens': [
            {
              'indice': 1,
              'tamanho': 'Média',
              'quantidade': 2,
              'mistura': 'Filé de frango',
            },
          ],
        },
      },
    );

    await send('carne e batata');
    expect(texts().single, contains('trocar as 2 para Carne moída'));
    final sessao = banco.obterSessao('5514999900001')!;
    final dados = Map<String, dynamic>.from(sessao['dados'] as Map);
    final itens =
        ((dados['rascunhoPedidoIA'] as Map)['itens'] as List).cast<Map>();
    expect(itens.single['mistura'], 'Filé de frango');
    expect(itens.single['acompanhamento'], isNull);
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

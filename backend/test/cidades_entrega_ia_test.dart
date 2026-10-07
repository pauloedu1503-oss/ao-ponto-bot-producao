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
  late GroqAtendimentoService ia;
  late BotService bot;
  var sequencia = 0;

  Future<String> perguntar(String texto) async {
    await bot.processar(MensagemWhatsApp(
      id: 'cidade_${sequencia++}',
      telefone: '5514555500001',
      nome: 'Teste',
      texto: texto,
    ));
    final saidas = whatsapp.consumirMensagensSimuladas();
    return saidas.map((saida) {
      if (saida['type'] == 'text') {
        return ((saida['text'] as Map)['body']).toString();
      }
      return ((saida['interactive'] as Map?)?['body'] as Map?)?['text']
              ?.toString() ??
          jsonEncode(saida);
    }).join('\n');
  }

  setUp(() {
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
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    bot = BotService(banco, whatsapp, ia: ia);
  });

  tearDown(() {
    ia.fechar();
    whatsapp.fechar();
    banco.fechar();
  });

  test('reports only the two served cities and their fees', () async {
    final resposta = await perguntar('quais cidades vocês atendem?');
    expect(resposta, contains('Atendemos em Barra Bonita'));
    expect(resposta, contains('Igaraçu do Tietê'));
    expect(resposta, contains('R\$ 8,00'));
    expect(resposta, contains('R\$ 10,00'));
  });

  test('reports the Barra Bonita delivery fee', () async {
    final resposta = await perguntar('qual a taxa para Barra Bonita?');
    expect(resposta, contains('Barra Bonita'));
    expect(resposta, contains('R\$ 8,00'));
  });

  test('uses only active cities and fees from the saved configuration',
      () async {
    final wrapper = banco.obterConfiguracao();
    final config = Map<String, dynamic>.from(wrapper['dados'] as Map);
    config['cidadesEntrega'] = [
      {
        'id': 'cidade_teste',
        'nome': 'Cidade Teste',
        'uf': 'SP',
        'taxa': 17.5,
        'ativa': true,
        'aliases': ['Cidade Teste'],
      },
      {
        'id': 'cidade_inativa',
        'nome': 'Cidade Inativa',
        'uf': 'SP',
        'taxa': 99.0,
        'ativa': false,
        'aliases': ['Cidade Inativa'],
      },
    ];
    banco.db.execute(
      'UPDATE configuracao SET json = ? WHERE id = 1',
      [jsonEncode(config)],
    );

    final resposta = await perguntar('quais cidades vocês atendem?');

    expect(resposta, contains('Cidade Teste'));
    expect(resposta, contains('R\$ 17,50'));
    expect(resposta, isNot(contains('Cidade Inativa')));
    expect(resposta, isNot(contains('Barra Bonita')));
  });

  test('recognizes Igaraçu without accents and reports its delivery fee',
      () async {
    final resposta = await perguntar('quanto cobra pra entrega em Igaracu?');
    expect(resposta, contains('Igaraçu do Tietê'));
    expect(resposta, contains('R\$ 10,00'));
  });

  test('does not claim delivery to another city', () async {
    final resposta = await perguntar('vocês entregam em Jaú?');
    expect(resposta, contains('Barra Bonita'));
    expect(resposta, contains('Igaraçu do Tietê'));
    expect(resposta, contains('R\$ 8,00'));
    expect(resposta, contains('R\$ 10,00'));
  });

  test('answers menu frequency questions instead of sending the menu',
      () async {
    final resposta = await perguntar('todo dia o cardápio é diferente?');
    expect(resposta, contains('muda a cada dia'));
    expect(resposta, isNot(contains('CARDÁPIO DO DIA')));
  });

  test('automatically sends configured menu for natural today-menu requests',
      () async {
    final resposta = await perguntar('oi, oq tem hj?');
    expect(resposta, contains('CARDÁPIO DO DIA'));
    expect(resposta, contains('Pequena'));
    final sessao = banco.obterSessao('5514555500001');
    expect(
        (sessao?['dados'] as Map?)?['opcoesInicioAposCardapio'], isNot(true));
  });
}

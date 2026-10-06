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
      telefone: '5514999900001',
      nome: 'Teste',
      texto: texto,
    ));
    final saidas = whatsapp.consumirMensagensSimuladas();
    return saidas
        .where((saida) => saida['type'] == 'text')
        .map((saida) => ((saida['text'] as Map)['body']).toString())
        .join('\n');
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
    expect(resposta, contains('somente em Barra Bonita'));
    expect(resposta, contains('Igaraçu do Tietê'));
    expect(resposta, contains('R\$ 8,00'));
    expect(resposta, contains('R\$ 10,00'));
  });

  test('reports the Barra Bonita delivery fee', () async {
    final resposta = await perguntar('qual a taxa para Barra Bonita?');
    expect(resposta, contains('Barra Bonita'));
    expect(resposta, contains('R\$ 8,00'));
  });

  test('recognizes Igaraçu without accents and reports its delivery fee',
      () async {
    final resposta = await perguntar('quanto cobra pra entrega em Igaracu?');
    expect(resposta, contains('Igaraçu do Tietê'));
    expect(resposta, contains('R\$ 10,00'));
  });

  test('does not claim delivery to another city', () async {
    final resposta = await perguntar('vocês entregam em Jaú?');
    expect(resposta, contains('somente em Barra Bonita'));
    expect(resposta, contains('Igaraçu do Tietê'));
    expect(resposta, contains('R\$ 8,00'));
    expect(resposta, contains('R\$ 10,00'));
  });
}

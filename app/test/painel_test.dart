import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ao_ponto_app/servicos/api_service.dart';
import 'package:ao_ponto_app/servicos/app_controller.dart';
import 'package:ao_ponto_app/servicos/fluxo_padrao.dart';
import 'package:ao_ponto_app/telas/fluxo_page.dart';
import 'package:ao_ponto_app/telas/shell_page.dart';
import 'package:ao_ponto_app/widgets/editor_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('API decodifica UTF-8 e recusa URL inadequada', () async {
    final api = ApiService(
        baseUrl: 'http://localhost:8080',
        client: MockClient((_) async => http.Response.bytes(
            utf8.encode('{"nome":"Igaraçu do Tietê"}'), 200)));
    expect((await api.health())['nome'], 'Igaraçu do Tietê');
    api.baseUrl = 'file:///tmp/arquivo';
    await expectLater(api.health(), throwsA(isA<ApiException>()));
    api.fechar();
  });

  test('trocar servidor revoga token somente na origem antiga', () async {
    SharedPreferences.setMockInitialValues({'token': 'antigo'});
    final destinos = <String>[];
    final controller = AppController();
    controller.api.fechar();
    controller.api = ApiService(
        baseUrl: 'http://antigo.local',
        token: 'antigo',
        client: MockClient((r) async {
          destinos.add(r.url.host);
          expect(r.headers['authorization'], 'Bearer antigo');
          return http.Response('{}', 200);
        }));
    await controller.trocarServidor('http://novo.local');
    expect(destinos, ['antigo.local']);
    expect(controller.api.token, isNull);
    expect(controller.api.baseUrl, 'http://novo.local');
    controller.dispose();
  });

  testWidgets('edição mantém texto em erro, valida e salva sem duplo envio',
      (tester) async {
    var chamadas = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () =>
                        editarCampos(context, titulo: 'Editar nome', campos: [
                          CampoEdicao('nome', 'Nome', 'Inicial',
                              validar: (v) =>
                                  v.isEmpty ? 'Informe o nome.' : null)
                        ], salvar: (v) async {
                          chamadas++;
                          if (chamadas == 1) {
                            throw const ApiException('Servidor indisponível');
                          }
                        }),
                    child: const Text('Editar'))))));
    await tester.tap(find.text('Editar'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '');
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();
    expect(find.text('Informe o nome.'), findsOneWidget);
    expect(chamadas, 0);
    await tester.enterText(find.byType(TextFormField), 'Nome novo');
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();
    expect(find.text('Servidor indisponível'), findsOneWidget);
    expect(find.text('Nome novo'), findsOneWidget);
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();
    expect(chamadas, 2);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('cancelar formulário alterado pede confirmação', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => editarCampos(context,
                        titulo: 'Editar',
                        campos: [const CampoEdicao('nome', 'Nome', 'Original')],
                        salvar: (_) async {}),
                    child: const Text('Abrir'))))));
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Alterado');
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.text('Descartar alterações?'), findsOneWidget);
    await tester.tap(find.text('Continuar editando'));
    await tester.pumpAndSettle();
    expect(find.text('Alterado'), findsOneWidget);
  });

  for (final largura in [390.0, 1280.0]) {
    testWidgets('painel atualiza e preserva abas em largura $largura',
        (tester) async {
      tester.view.physicalSize = Size(largura, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = AppController();
      c.configuracao = {
        'versao': 1,
        'dados': {'fluxo': fluxoPadraoApp()}
      };
      await tester.pumpWidget(MaterialApp(home: ShellPage(controller: c)));
      expect(find.text('Cliente novo'), findsNothing);
      c.pedidos = [
        {
          'id': 1,
          'numero': 1,
          'clienteNome': 'Cliente novo',
          'telefone': '551400000000',
          'status': 'novo',
          'total': 16.0,
          'recebimento': 'retirada',
          'pagamento': 'pix',
          'versao': 1,
          'itens': []
        }
      ];
      c.notifyListeners();
      await tester.pump();
      await tester.tap(find.byIcon(Icons.receipt_long_outlined).last);
      await tester.pumpAndSettle();
      expect(find.text('Cliente novo'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }

  testWidgets('editor do fluxo abre campo e mantém texto ao salvar falhando',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController();
    c.configuracao = {
      'versao': 1,
      'dados': {'fluxo': fluxoPadraoApp()}
    };
    c.api.fechar();
    c.api = ApiService(
        baseUrl: 'http://localhost',
        client: MockClient((_) async => http.Response.bytes(
            utf8.encode('{"erro":"Fluxo inválido"}'), 400)));
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: FluxoPage(controller: c))));
    await tester.tap(find.text('Pergunta principal'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Minha pergunta');
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();
    expect(find.text('Minha pergunta'), findsOneWidget);
    expect(find.text('Fluxo inválido'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}

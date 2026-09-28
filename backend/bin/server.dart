import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;

import '../lib/api/api.dart';
import '../lib/banco/banco.dart';
import '../lib/bot/bot_service.dart';
import '../lib/servicos/auth_service.dart';
import '../lib/servicos/push_service.dart';
import '../lib/servicos/whatsapp_service.dart';
import '../lib/util/env.dart';

Future<void> main() async {
  Env.carregar('.env');

  final senha = Env.get('ADMIN_PASSWORD');
  if (senha.isEmpty || senha == 'troque-esta-senha') {
    stderr
        .writeln('Configure ADMIN_PASSWORD em backend/.env antes de iniciar.');
    exitCode = 78;
    return;
  }
  if ((Env.get('WHATSAPP_ACCESS_TOKEN').isNotEmpty ||
          Env.get('WHATSAPP_PHONE_NUMBER_ID').isNotEmpty) &&
      (Env.get('WHATSAPP_ACCESS_TOKEN').isEmpty ||
          Env.get('WHATSAPP_PHONE_NUMBER_ID').isEmpty ||
          Env.get('META_APP_SECRET').isEmpty)) {
    stderr.writeln(
        'Configuração WhatsApp incompleta: confira token, número e META_APP_SECRET.');
    exitCode = 78;
    return;
  }
  final banco = Banco();
  final auth = AuthService(banco);
  final whatsapp = WhatsAppService(banco);
  final push = PushService(banco);
  final bot = BotService(banco, whatsapp);
  final api = Api(banco, auth, bot, push);

  final host = Env.get('HOST', padrao: '0.0.0.0');
  final port = Env.getInt('PORT', padrao: 8080);
  final server = await shelf_io.serve(api.handler, host, port);

  api.iniciarWorker();
  stdout.writeln('==============================================');
  stdout.writeln(' AO PONTO BOT V1.3.1 - BACKEND ATIVO');
  stdout.writeln(' http://${server.address.address}:${server.port}');
  stdout.writeln(
      ' WhatsApp: ${whatsapp.configurado ? 'configurado' : 'a configurar'}');
  stdout.writeln('==============================================');

  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\nEncerrando...');
    await server.close();
    await api.fechar();
    whatsapp.fechar();
    push.fechar();
    banco.fechar();
    exit(0);
  });
}

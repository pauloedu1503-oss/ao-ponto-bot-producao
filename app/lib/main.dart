import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'servicos/app_controller.dart';
import 'servicos/notificacao_service.dart';
import 'telas/login_page.dart';
import 'telas/shell_page.dart';

final messengerKey = GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await NotificacaoService.inicializar();
  } catch (e) {
    debugPrint('Notificações indisponíveis: ${e.runtimeType}');
  }
  FlutterError.onError = (details) {
    debugPrint('Erro de interface: ${details.exception.runtimeType}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Erro assíncrono: ${error.runtimeType}');
    messengerKey.currentState?.showSnackBar(const SnackBar(
        content: Text('Não foi possível concluir a ação. Tente novamente.')));
    return true;
  };
  ErrorWidget.builder = (_) => const Material(
      child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
              'Não foi possível exibir esta área. Reabra o painel e tente novamente.')));
  final controller = AppController();

  controller.onNovoPedido = () {
    SystemSound.play(SystemSoundType.alert);
    messengerKey.currentState?.showSnackBar(
      const SnackBar(
        content: Text('Novo pedido recebido!'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  };

  // Renderiza o Flutter primeiro. No web, nunca devemos esperar leitura de
  // sessão/rede antes do runApp(), pois uma inicialização lenta deixaria o
  // navegador totalmente branco, sem sequer mostrar uma tela de carregamento.
  runApp(AoPontoApp(controller: controller));
  unawaited(controller.iniciar());
}

class AoPontoApp extends StatelessWidget {
  final AppController controller;
  const AoPontoApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    const vermelho = Color(0xFFE71923);
    const amarelo = Color(0xFFFFD700);
    const preto = Color(0xFF171717);
    const creme = Color(0xFFFFFBF1);

    final esquema = ColorScheme.fromSeed(
      seedColor: vermelho,
      brightness: Brightness.light,
      surface: creme,
    ).copyWith(
      primary: vermelho,
      onPrimary: Colors.white,
      secondary: amarelo,
      onSecondary: preto,
      surface: creme,
      onSurface: preto,
    );

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return MaterialApp(
          title: 'Ao Ponto Bot',
          debugShowCheckedModeBanner: false,
          builder: (context, child) {
            return TooltipVisibility(
              visible: false,
              child: child ?? const SizedBox.shrink(),
            );
          },
          scaffoldMessengerKey: messengerKey,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: esquema,
            scaffoldBackgroundColor: creme,
            cardTheme: CardThemeData(
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(color: Colors.black.withValues(alpha: .08)),
              ),
            ),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:
                    BorderSide(color: Colors.black.withValues(alpha: .08)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: vermelho, width: 1.5),
              ),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 50),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          home: controller.carregando
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : controller.autenticado
                  ? ShellPage(controller: controller)
                  : LoginPage(controller: controller),
        );
      },
    );
  }
}

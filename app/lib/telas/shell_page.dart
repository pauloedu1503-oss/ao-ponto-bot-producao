import 'package:flutter/material.dart';

import '../servicos/app_controller.dart';
import 'bot_page.dart';
import 'cardapio_page.dart';
import 'configuracoes_page.dart';
import 'fluxo_page.dart';
import 'inicio_page.dart';
import 'pedidos_page.dart';

class ShellPage extends StatefulWidget {
  final AppController controller;

  const ShellPage({
    super.key,
    required this.controller,
  });

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  int index = 0;

  List<Widget> get paginas => [
        InicioPage(controller: widget.controller),
        PedidosPage(controller: widget.controller),
        CardapioPage(controller: widget.controller),
        BotPage(controller: widget.controller),
        FluxoPage(controller: widget.controller),
        ConfiguracoesPage(controller: widget.controller),
      ];

  static const destinos = [
    (Icons.home_outlined, Icons.home, 'Início'),
    (Icons.receipt_long_outlined, Icons.receipt_long, 'Pedidos'),
    (Icons.restaurant_menu_outlined, Icons.restaurant_menu, 'Cardápio'),
    (Icons.smart_toy_outlined, Icons.smart_toy, 'Bot'),
    (Icons.account_tree_outlined, Icons.account_tree, 'Fluxo'),
    (Icons.settings_outlined, Icons.settings, 'Configurações'),
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) => LayoutBuilder(
              builder: (context, constraints) {
                final desktop = constraints.maxWidth >= 900;

                return Scaffold(
                  body: Column(children: [
                    if (widget.controller.erroGlobal != null)
                      MaterialBanner(
                          content: Text(widget.controller.erroGlobal!),
                          actions: [
                            TextButton(
                                onPressed:
                                    widget.controller.atualizarSilencioso,
                                child: const Text('Tentar novamente')),
                          ]),
                    Expanded(
                        child: Row(
                      children: [
                        if (desktop) _sidebar(),
                        Expanded(
                          child: IndexedStack(
                            index: index,
                            children: paginas,
                          ),
                        ),
                      ],
                    )),
                  ]),
                  bottomNavigationBar: desktop
                      ? null
                      : NavigationBar(
                          labelBehavior: NavigationDestinationLabelBehavior
                              .onlyShowSelected,
                          selectedIndex: index,
                          onDestinationSelected: (novoIndex) {
                            setState(() {
                              index = novoIndex;
                            });
                          },
                          destinations: destinos.map((destino) {
                            return NavigationDestination(
                              icon: Icon(destino.$1),
                              selectedIcon: Icon(destino.$2),
                              label: destino.$3,
                            );
                          }).toList(),
                        ),
                );
              },
            ));
  }

  Widget _sidebar() {
    return Material(
        color: const Color(0xFF171717),
        child: SizedBox(
          width: 220,
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    16,
                    20,
                    16,
                    16,
                  ),
                  child: Row(
                    children: [
                      Image.asset(
                        'assets/logo.png',
                        width: 48,
                        height: 48,
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Ao Ponto\nBot',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(
                  color: Colors.white12,
                  height: 1,
                ),
                const SizedBox(height: 8),
                ...List.generate(
                  destinos.length,
                  (i) {
                    final selected = i == index;

                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      child: ListTile(
                        selected: selected,
                        selectedTileColor: const Color(0xFFFFD700),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        leading: Icon(
                          selected ? destinos[i].$2 : destinos[i].$1,
                          color: selected ? Colors.black : Colors.white70,
                        ),
                        title: Text(
                          destinos[i].$3,
                          style: TextStyle(
                            color: selected ? Colors.black : Colors.white,
                            fontWeight:
                                selected ? FontWeight.w800 : FontWeight.w500,
                          ),
                        ),
                        onTap: () {
                          setState(() {
                            index = i;
                          });
                        },
                      ),
                    );
                  },
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Ao Ponto Bot',
                    style: TextStyle(
                      color: Colors.white.withValues(
                        alpha: .45,
                      ),
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ));
  }
}

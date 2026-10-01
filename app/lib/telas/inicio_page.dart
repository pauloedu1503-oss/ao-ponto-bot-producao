import 'package:flutter/material.dart';
import '../servicos/app_controller.dart';
import '../widgets/ui.dart';

class InicioPage extends StatelessWidget {
  final AppController controller;
  const InicioPage({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final d = controller.dashboard;
    final estado = d['estadoBot']?.toString() ?? 'fechado';
    final configDados = Map<String, dynamic>.from(
        controller.configuracao['dados'] as Map? ?? {});
    final horarioAutomatico = configDados['usarHorarioAutomatico'] == true;
    final botAtivo = configDados['botAtivo'] != false;
    final abertos = controller.pedidos
        .where((p) => !['finalizado', 'cancelado'].contains(p['status']))
        .take(6)
        .toList();

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: controller.carregarTudo,
        child: ListView(
          padding: margemPagina(context),
          children: [
            TituloPagina(
              'Ao Ponto',
              subtitulo: 'Visão rápida do atendimento de hoje',
              acao: EstadoPill(estado),
            ),
            const SizedBox(height: 20),
            LayoutBuilder(builder: (context, c) {
              final cols = c.maxWidth >= 900
                  ? 4
                  : c.maxWidth >= 520
                      ? 2
                      : 1;
              final largura = (c.maxWidth - ((cols - 1) * 12)) / cols;
              final itens = [
                MetricaCard(
                    icon: Icons.shopping_bag_outlined,
                    titulo: 'Pedidos hoje',
                    valor: '${d['pedidosHoje'] ?? 0}'),
                MetricaCard(
                    icon: Icons.payments_outlined,
                    titulo: 'Vendas hoje',
                    valor: dinheiro(d['vendasHoje'] ?? 0)),
                MetricaCard(
                    icon: Icons.fiber_new_outlined,
                    titulo: 'Novos',
                    valor: '${d['novos'] ?? 0}'),
                MetricaCard(
                    icon: Icons.check_circle_outline,
                    titulo: 'Confirmados',
                    valor: '${d['confirmados'] ?? 0}'),
              ];
              return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: itens
                      .map((e) => SizedBox(width: largura, child: e))
                      .toList());
            }),
            const SizedBox(height: 22),
            PainelCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Controle rápido do bot',
                      style:
                          TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                  const SizedBox(height: 10),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: botAtivo,
                    title: Text(
                      botAtivo ? 'Bot ativado' : 'Bot desativado',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: botAtivo ? Colors.green.shade800 : Colors.red,
                      ),
                    ),
                    subtitle: Text(botAtivo
                        ? 'As mensagens são visualizadas e respondidas automaticamente.'
                        : 'As mensagens não são visualizadas nem respondidas pelo bot.'),
                    secondary: Icon(
                      botAtivo
                          ? Icons.smart_toy_outlined
                          : Icons.power_settings_new,
                      color: botAtivo ? Colors.green.shade800 : Colors.red,
                    ),
                    onChanged: controller.salvandoConfig
                        ? null
                        : (v) async {
                            try {
                              await controller.definirBotAtivo(v);
                            } catch (e) {
                              if (context.mounted) {
                                await mostrarErro(context, e);
                              }
                            }
                          },
                  ),
                  const Divider(height: 24),
                  Text(
                    !botAtivo
                        ? 'Ative o bot para usar os controles de atendimento.'
                        : horarioAutomatico
                            ? 'Horário automático está ativo. Fora do horário, o estado efetivo fica Fechado.'
                            : 'O estado manual controla o atendimento.',
                    style: const TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 16),
                  IgnorePointer(
                    ignoring: !botAtivo,
                    child: Opacity(
                      opacity: botAtivo ? 1 : .45,
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          _EstadoButton(
                              controller: controller,
                              estado: 'atendendo',
                              icon: Icons.play_circle_outline,
                              label: 'Atender'),
                          _EstadoButton(
                              controller: controller,
                              estado: 'pausado',
                              icon: Icons.pause_circle_outline,
                              label: 'Pausar'),
                          _EstadoButton(
                              controller: controller,
                              estado: 'esgotado',
                              icon: Icons.inventory_2_outlined,
                              label: 'Esgotou'),
                          _EstadoButton(
                              controller: controller,
                              estado: 'fechado',
                              icon: Icons.storefront_outlined,
                              label: 'Fechar'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            const Text('Pedidos abertos',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
            const SizedBox(height: 10),
            if (abertos.isEmpty)
              const PainelCard(
                  child: Text('Nenhum pedido aberto agora.',
                      style: TextStyle(color: Colors.black54)))
            else
              ...abertos.map((p) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: PainelCard(
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor:
                                Theme.of(context).colorScheme.secondary,
                            child: Text('#${p['numero']}',
                                style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.black)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      p['clienteNome']?.toString() ?? 'Cliente',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800)),
                                  const SizedBox(height: 3),
                                  Text(_resumoItens(p),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Colors.black54)),
                                ]),
                          ),
                          const SizedBox(width: 10),
                          Text(dinheiro(p['total']),
                              style:
                                  const TextStyle(fontWeight: FontWeight.w900)),
                        ],
                      ),
                    ),
                  )),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  String _resumoItens(Map<String, dynamic> pedido) {
    final itens = pedido['itens'];
    if (itens is! List || itens.isEmpty) return 'Pedido';
    return itens.map((raw) {
      final i = Map<String, dynamic>.from(raw as Map);
      return '${i['quantidade']}x ${i['tamanhoNome']}';
    }).join(' • ');
  }
}

class _EstadoButton extends StatefulWidget {
  final AppController controller;
  final String estado;
  final IconData icon;
  final String label;
  const _EstadoButton(
      {required this.controller,
      required this.estado,
      required this.icon,
      required this.label});

  @override
  State<_EstadoButton> createState() => _EstadoButtonState();
}

class _EstadoButtonState extends State<_EstadoButton> {
  bool loading = false;

  @override
  Widget build(BuildContext context) {
    final dados = widget.controller.configuracao['dados'] as Map?;
    final ativo = dados?['estadoBot'] == widget.estado;
    return FilledButton.tonalIcon(
      onPressed: loading
          ? null
          : () async {
              setState(() => loading = true);
              try {
                await widget.controller.definirEstadoBot(widget.estado);
              } catch (e) {
                await mostrarErro(context, e);
              } finally {
                if (mounted) setState(() => loading = false);
              }
            },
      icon: loading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(widget.icon),
      label: Text(ativo ? '${widget.label} ✓' : widget.label),
    );
  }
}

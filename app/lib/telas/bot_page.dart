import '../widgets/editor_dialog.dart';
import 'package:flutter/material.dart';
import '../servicos/app_controller.dart';
import '../widgets/ui.dart';

class BotPage extends StatelessWidget {
  final AppController controller;
  const BotPage({super.key, required this.controller});

  Map<String, dynamic> get _dados =>
      Map<String, dynamic>.from(controller.configuracao['dados'] as Map? ?? {});

  @override
  Widget build(BuildContext context) {
    final dados = _dados;
    final estado = dados['estadoBot']?.toString() ?? 'fechado';
    final problemas = controller.dashboard['problemasProntidao'] as List? ?? [];
    final pendentes = controller.dashboard['enviosPendentes'] as num? ?? 0;
    final mensagens =
        Map<String, dynamic>.from(dados['mensagens'] as Map? ?? {});
    final horarios = Map<String, dynamic>.from(dados['horarios'] as Map? ?? {});

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: controller.carregarTudo,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TituloPagina('Bot',
                subtitulo: 'Controle do atendimento automático',
                acao: EstadoPill(estado)),
            const SizedBox(height: 18),
            PainelCard(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(
                      problemas.isEmpty
                          ? 'Sistema pronto para atender'
                          : 'Antes de atender, corrija:',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  ...problemas.map((p) => Text('• $p')),
                  if (pendentes > 0)
                    Text(
                        'WhatsApp: $pendentes envio(s) pendente(s) ou com falha. Confira os logs e as conversas.'),
                  if (pendentes > 0)
                    TextButton.icon(
                        onPressed: () => _abrirEnvios(context),
                        icon: const Icon(Icons.mark_unread_chat_alt_outlined),
                        label: const Text('Ver envios com falha')),
                ])),
            const SizedBox(height: 16),
            PainelCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Estado do atendimento',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 6),
                    const Text(
                        'Pausado preserva o pedido em andamento por alguns minutos. Esgotado e Fechado encerram pedidos ainda não confirmados.',
                        style: TextStyle(color: Colors.black54)),
                    const SizedBox(height: 14),
                    Wrap(spacing: 10, runSpacing: 10, children: [
                      _EstadoAcao(controller, 'atendendo', 'Atendendo',
                          Icons.play_circle_outline),
                      _EstadoAcao(controller, 'pausado', 'Pausado',
                          Icons.pause_circle_outline),
                      _EstadoAcao(controller, 'esgotado', 'Esgotado',
                          Icons.inventory_2_outlined),
                      _EstadoAcao(controller, 'fechado', 'Fechado',
                          Icons.storefront_outlined),
                    ]),
                  ]),
            ),
            const SizedBox(height: 16),
            PainelCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: dados['usarHorarioAutomatico'] == true,
                      title: const Text('Horário automático',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: const Text(
                          'Quando ligado, o bot só aceita pedidos dentro do horário configurado.'),
                      onChanged: (v) =>
                          _alterarCampo(context, 'usarHorarioAutomatico', v),
                    ),
                    const Divider(),
                    ...List.generate(7, (i) {
                      final dia = i + 1;
                      final d = Map<String, dynamic>.from(
                          horarios['$dia'] as Map? ?? {});
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Checkbox(
                          value: d['ativo'] == true,
                          onChanged: (v) =>
                              _alterarDia(context, dia, ativo: v == true),
                        ),
                        title: Text(_nomeDia(dia),
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(d['ativo'] == true
                            ? '${d['inicio'] ?? '10:00'} → ${d['fim'] ?? '14:00'}'
                            : 'Fechado'),
                        trailing: IconButton(
                          icon: const Icon(Icons.schedule_outlined),
                          onPressed: () => _editarHorario(context, dia, d),
                        ),
                      );
                    }),
                  ]),
            ),
            const SizedBox(height: 16),
            PainelCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Mensagens automáticas',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 6),
                    const Text('Você pode mudar os textos sem mexer no código.',
                        style: TextStyle(color: Colors.black54)),
                    const SizedBox(height: 10),
                    _MensagemTile('Boas-vindas', 'boasVindas',
                        mensagens['boasVindas']?.toString() ?? '',
                        onTap: () => _editarMensagem(context, 'boasVindas',
                            mensagens['boasVindas']?.toString() ?? '')),
                    _MensagemTile('Fechado', 'fechado',
                        mensagens['fechado']?.toString() ?? '',
                        onTap: () => _editarMensagem(context, 'fechado',
                            mensagens['fechado']?.toString() ?? '')),
                    _MensagemTile('Pausado', 'pausado',
                        mensagens['pausado']?.toString() ?? '',
                        onTap: () => _editarMensagem(context, 'pausado',
                            mensagens['pausado']?.toString() ?? '')),
                    _MensagemTile('Esgotado', 'esgotado',
                        mensagens['esgotado']?.toString() ?? '',
                        onTap: () => _editarMensagem(context, 'esgotado',
                            mensagens['esgotado']?.toString() ?? '')),
                    _MensagemTile('Pedido enviado à loja', 'pedidoConfirmado',
                        mensagens['pedidoConfirmado']?.toString() ?? '',
                        onTap: () => _editarMensagem(
                            context,
                            'pedidoConfirmado',
                            mensagens['pedidoConfirmado']?.toString() ?? '')),
                  ]),
            ),
            const SizedBox(height: 16),
            PainelCard(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.timer_outlined),
                title: const Text('Expiração da conversa',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text(
                    '${dados['sessaoExpiraMinutos'] ?? 30} minutos sem atividade'),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => _editarTimeout(context,
                    (dados['sessaoExpiraMinutos'] as num?)?.toInt() ?? 30),
              ),
            ),
            const SizedBox(height: 16),
            PainelCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Expanded(
                          child: Text('Atendimento humano',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w900))),
                      Text('${controller.humanos.length}',
                          style: const TextStyle(fontWeight: FontWeight.w900)),
                    ]),
                    const SizedBox(height: 6),
                    const Text(
                        'Enquanto uma conversa estiver em modo humano, o bot não interfere.',
                        style: TextStyle(color: Colors.black54)),
                    const SizedBox(height: 10),
                    if (controller.humanos.isEmpty)
                      const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child:
                              Text('Nenhuma conversa em atendimento humano.'))
                    else
                      ...controller.humanos.map((h) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const CircleAvatar(
                                child: Icon(Icons.person_outline)),
                            title: Text(h['nome']?.toString().isNotEmpty == true
                                ? h['nome'].toString()
                                : h['telefone'].toString()),
                            subtitle: Text(h['telefone']?.toString() ?? ''),
                            trailing: Wrap(
                              spacing: 8,
                              children: [
                                if (h['alertaAtivo'] == true)
                                  OutlinedButton(
                                    onPressed: () => _pararAlerta(
                                      context,
                                      h['telefone'].toString(),
                                    ),
                                    child: const Text('Parar alerta'),
                                  ),
                                FilledButton.tonal(
                                  onPressed: () => _confirmarRetomar(
                                    context,
                                    h['telefone'].toString(),
                                    h['nome']?.toString() ?? '',
                                  ),
                                  child: const Text('Retomar do início'),
                                ),
                              ],
                            ),
                          )),
                  ]),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmarRetomar(
    BuildContext context,
    String telefone,
    String nome,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Retomar atendimento automático?'),
        content: Text(
          '${nome.trim().isEmpty ? telefone : nome} voltará para o menu inicial. '
          'Qualquer pedido automático que estava pela metade será descartado.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Retomar do início'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await controller.retomarBot(telefone);
    } catch (e) {
      if (context.mounted) await mostrarErro(context, e);
    }
  }

  Future<void> _pararAlerta(BuildContext context, String telefone) async {
    try {
      await controller.pararAlertaHumano(telefone);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Alerta sonoro interrompido.')),
        );
      }
    } catch (e) {
      if (context.mounted) await mostrarErro(context, e);
    }
  }

  Future<void> _abrirEnvios(BuildContext context) async {
    try {
      await controller.carregarEnvios();
    } catch (e) {
      if (context.mounted) await mostrarErro(context, e);
      return;
    }
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (sheetContext) =>
            StatefulBuilder(builder: (sheetContext, setLocal) {
              final lista = controller.enviosComFalha;
              return DraggableScrollableSheet(
                  expand: false,
                  initialChildSize: .75,
                  minChildSize: .4,
                  maxChildSize: .95,
                  builder: (sheetContext, scroll) => ListView(
                          controller: scroll,
                          padding: const EdgeInsets.all(20),
                          children: [
                            const Text('Envios que precisam de atenção',
                                style: TextStyle(
                                    fontSize: 20, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            const Text(
                                'Confira a conversa do cliente antes de reenviar. Um envio incerto pode já ter sido entregue.'),
                            const SizedBox(height: 16),
                            if (lista.isEmpty)
                              const Text('Nenhum envio com falha.'),
                            for (final envio in lista)
                              Card(
                                  child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                                'Envio #${envio['id']} • ${envio['status']} • ${envio['tipo']}',
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.bold)),
                                            Text(
                                                'Cliente: ${envio['telefone']} • ${envio['criadoEm']}'),
                                            Text(
                                                'Falha: ${envio['erro'] ?? 'não informado'}'),
                                            Wrap(spacing: 8, children: [
                                              TextButton(
                                                  onPressed: () =>
                                                      _resolverEnvio(
                                                          sheetContext,
                                                          setLocal,
                                                          envio,
                                                          'descartar'),
                                                  child:
                                                      const Text('Descartar')),
                                              FilledButton.tonal(
                                                  onPressed: () =>
                                                      _resolverEnvio(
                                                          sheetContext,
                                                          setLocal,
                                                          envio,
                                                          'reenviar'),
                                                  child:
                                                      const Text('Reenviar')),
                                            ]),
                                          ]))),
                          ]));
            }));
  }

  Future<void> _resolverEnvio(BuildContext context, StateSetter atualizar,
      Map<String, dynamic> envio, String acao) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
                title: Text(acao == 'reenviar'
                    ? 'Reenviar mensagem?'
                    : 'Descartar mensagem?'),
                content: Text(
                    'Confira primeiro a conversa de ${envio['telefone']}. Esta decisão afeta o envio #${envio['id']}.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('Voltar')),
                  FilledButton(
                      onPressed: () => Navigator.pop(c, true),
                      child:
                          Text(acao == 'reenviar' ? 'Reenviar' : 'Descartar'))
                ]));
    if (ok != true) return;
    try {
      await controller.resolverEnvio((envio['id'] as num).toInt(), acao);
      atualizar(() {});
    } catch (e) {
      if (context.mounted) await mostrarErro(context, e);
    }
  }

  Future<void> _alterarCampo(
      BuildContext context, String campo, dynamic valor) async {
    final dados = copiaMapa(_dados);
    dados[campo] = valor;
    try {
      await controller.salvarConfigDados(dados);
    } catch (e) {
      if (context.mounted) await mostrarErro(context, e);
    }
  }

  Future<void> _alterarDia(BuildContext context, int dia,
      {bool? ativo, String? inicio, String? fim}) async {
    final dados = copiaMapa(_dados);
    final horarios = Map<String, dynamic>.from(dados['horarios'] as Map? ?? {});
    final atual = Map<String, dynamic>.from(horarios['$dia'] as Map? ??
        {'ativo': true, 'inicio': '10:00', 'fim': '14:00'});
    if (ativo != null) atual['ativo'] = ativo;
    if (inicio != null) atual['inicio'] = inicio;
    if (fim != null) atual['fim'] = fim;
    horarios['$dia'] = atual;
    dados['horarios'] = horarios;
    try {
      await controller.salvarConfigDados(dados);
    } catch (e) {
      if (context.mounted) await mostrarErro(context, e);
    }
  }

  Future<void> _editarHorario(
      BuildContext context, int dia, Map<String, dynamic> atual) async {
    TimeOfDay parse(String value, TimeOfDay fallback) {
      final p = value.split(':');
      if (p.length != 2) return fallback;
      return TimeOfDay(
          hour: int.tryParse(p[0]) ?? fallback.hour,
          minute: int.tryParse(p[1]) ?? fallback.minute);
    }

    var inicio = parse(atual['inicio']?.toString() ?? '',
        const TimeOfDay(hour: 10, minute: 0));
    var fim = parse(
        atual['fim']?.toString() ?? '', const TimeOfDay(hour: 14, minute: 0));
    final result = await showDialog<(TimeOfDay, TimeOfDay)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('Horário • ${_nomeDia(dia)}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Abre'),
              trailing: Text(inicio.format(context),
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              onTap: () async {
                final v =
                    await showTimePicker(context: context, initialTime: inicio);
                if (v != null) setLocal(() => inicio = v);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Fecha'),
              trailing: Text(fim.format(context),
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              onTap: () async {
                final v =
                    await showTimePicker(context: context, initialTime: fim);
                if (v != null) setLocal(() => fim = v);
              },
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, (inicio, fim)),
                child: const Text('Salvar')),
          ],
        ),
      ),
    );
    if (result == null) return;
    String fmt(TimeOfDay t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    await _alterarDia(context, dia,
        inicio: fmt(result.$1), fim: fmt(result.$2));
  }

  Future<void> _editarMensagem(
      BuildContext context, String chave, String atual) async {
    final dados = copiaMapa(_dados);
    final versao = controller.configuracao['versao'] as int;
    await editarCampos(context, titulo: 'Editar mensagem', campos: [
      CampoEdicao('texto', 'Mensagem', atual,
          linhas: 4,
          validar: (v) => v.isEmpty || v.length > 1000
              ? 'Use de 1 a 1000 caracteres.'
              : null)
    ], salvar: (v) async {
      (dados['mensagens'] as Map)[chave] = v['texto'];
      await controller.salvarConfigDados(dados, versaoEsperada: versao);
    });
  }

  Future<void> _editarTimeout(BuildContext context, int atual) async {
    final dados = copiaMapa(_dados);
    final versao = controller.configuracao['versao'] as int;
    await editarCampos(context, titulo: 'Expiração da conversa', campos: [
      CampoEdicao('minutos', 'Minutos', '$atual', validar: (v) {
        final n = int.tryParse(v);
        return n == null || n < 5 || n > 240
            ? 'Informe de 5 a 240 minutos.'
            : null;
      })
    ], salvar: (v) async {
      dados['sessaoExpiraMinutos'] = int.parse(v['minutos']!);
      await controller.salvarConfigDados(dados, versaoEsperada: versao);
    });
  }

  String _nomeDia(int dia) => const {
        1: 'Segunda',
        2: 'Terça',
        3: 'Quarta',
        4: 'Quinta',
        5: 'Sexta',
        6: 'Sábado',
        7: 'Domingo'
      }[dia]!;
}

class _EstadoAcao extends StatelessWidget {
  final AppController controller;
  final String estado;
  final String label;
  final IconData icon;
  const _EstadoAcao(this.controller, this.estado, this.label, this.icon);

  @override
  Widget build(BuildContext context) {
    final ativo =
        (controller.configuracao['dados'] as Map?)?['estadoBot'] == estado;
    return ativo
        ? FilledButton.icon(
            onPressed: null, icon: Icon(icon), label: Text('$label ✓'))
        : FilledButton.tonalIcon(
            onPressed: () async {
              try {
                await controller.definirEstadoBot(estado);
              } catch (e) {
                if (context.mounted) await mostrarErro(context, e);
              }
            },
            icon: Icon(icon),
            label: Text(label),
          );
  }
}

class _MensagemTile extends StatelessWidget {
  final String titulo;
  final String chave;
  final String mensagem;
  final VoidCallback onTap;
  const _MensagemTile(this.titulo, this.chave, this.mensagem,
      {required this.onTap});

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        title:
            Text(titulo, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(mensagem, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.edit_outlined),
        onTap: onTap,
      );
}

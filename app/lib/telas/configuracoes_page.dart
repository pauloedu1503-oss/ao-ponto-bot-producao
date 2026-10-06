import '../widgets/editor_dialog.dart';
import 'package:flutter/material.dart';
import '../servicos/app_controller.dart';
import '../widgets/ui.dart';

class ConfiguracoesPage extends StatelessWidget {
  final AppController controller;
  const ConfiguracoesPage({super.key, required this.controller});

  Map<String, dynamic> get _dados =>
      Map<String, dynamic>.from(controller.configuracao['dados'] as Map? ?? {});

  @override
  Widget build(BuildContext context) {
    final d = _dados;
    final pagamentos = Map<String, dynamic>.from(d['pagamentos'] as Map? ?? {});
    final cidadesEntrega = List<Map<String, dynamic>>.from(
      (d['cidadesEntrega'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map)),
    );

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: controller.recarregarCardapioEConfig,
        child: ListView(
          padding: margemPagina(context),
          children: [
            const TituloPagina('Configurações',
                subtitulo: 'Dados operacionais da Ao Ponto'),
            const SizedBox(height: 18),
            PainelCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Modo de atendimento',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'bot', label: Text('Bot')),
                      ButtonSegment(value: 'ia', label: Text('IA')),
                    ],
                    selected: {
                      d['modoAtendimento'] == 'ia' ? 'ia' : 'bot',
                    },
                    onSelectionChanged: (selecionado) => _alterarCampo(
                      context,
                      'modoAtendimento',
                      selecionado.first,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    d['modoAtendimento'] == 'ia'
                        ? (controller.configuracao['iaConfigurada'] == true
                            ? 'IA ativada. Se a Groq falhar ou atingir o limite, o fluxo atual do bot assume automaticamente.'
                            : 'A chave GROQ_API_KEY ainda não está configurada no servidor. Até configurá-la, o atendimento continuará pelo fluxo atual do bot.')
                        : 'Usa o fluxo atual de atendimento.',
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (d['modoAtendimento'] == 'ia') ...[
                    const SizedBox(height: 6),
                    const Text(
                      'No modo IA, a mensagem do cliente e os dados disponíveis do cardápio/atendimento são enviados à Groq para interpretação. A chave fica somente no servidor.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            PainelCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Estabelecimento',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w900)),
                    _editTile(
                        context,
                        'Nome',
                        d['nomeEstabelecimento']?.toString() ?? '',
                        'nomeEstabelecimento'),
                    _editTile(
                        context,
                        'Endereço para retirada',
                        d['enderecoRetirada']?.toString() ?? '',
                        'enderecoRetirada',
                        multiline: true),
                  ]),
            ),
            const SizedBox(height: 16),
            PainelCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Entrega e retirada',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w900)),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: d['entregaAtiva'] == true,
                      title: const Text('Aceitar entrega'),
                      onChanged: (v) =>
                          _alterarCampo(context, 'entregaAtiva', v),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: d['retiradaAtiva'] == true,
                      title: const Text('Aceitar retirada'),
                      onChanged: (v) =>
                          _alterarCampo(context, 'retiradaAtiva', v),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 8, bottom: 4),
                      child: Text(
                        'Cidades atendidas',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    const Text(
                      'Após informar o endereço, o cliente escolhe a cidade. A taxa exibida fica congelada no pedido.',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 6),
                    ...cidadesEntrega
                        .map((cidade) => _cidadeEntregaTile(context, cidade)),
                  ]),
            ),
            const SizedBox(height: 16),
            PainelCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Pagamento',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w900)),
                    _pagamentoSwitch(
                        context, 'PIX', 'pix', pagamentos['pix'] == true),
                    _pagamentoSwitch(context, 'Dinheiro', 'dinheiro',
                        pagamentos['dinheiro'] == true),
                    _pagamentoSwitch(
                        context,
                        'Cartão de crédito',
                        'credito',
                        pagamentos['credito'] == true ||
                            (pagamentos['credito'] == null &&
                                pagamentos['cartao'] == true)),
                    _pagamentoSwitch(
                        context,
                        'Cartão de débito',
                        'debito',
                        pagamentos['debito'] == true ||
                            (pagamentos['debito'] == null &&
                                pagamentos['cartao'] == true)),
                    _editTile(context, 'Chave PIX',
                        d['chavePix']?.toString() ?? '', 'chavePix'),
                  ]),
            ),
            const SizedBox(height: 16),
            PainelCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Montagem do pedido',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w900)),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: d['permitirObservacoes'] == true,
                      title: const Text('Permitir observações'),
                      subtitle: const Text('Ex.: sem feijão.'),
                      onChanged: (v) =>
                          _alterarCampo(context, 'permitirObservacoes', v),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: d['saladaIncluida'] == true,
                      title: const Text('Salada incluída'),
                      subtitle:
                          const Text('Vale para Pequena, Média e Grande.'),
                      onChanged: (v) =>
                          _alterarCampo(context, 'saladaIncluida', v),
                    ),
                    _editTile(
                        context,
                        'Descrição da salada',
                        d['descricaoSalada']?.toString() ?? 'Salada do dia',
                        'descricaoSalada'),
                  ]),
            ),
            const SizedBox(height: 16),
            PainelCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Sistema',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w900)),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.backup_outlined),
                      title: const Text('Gerar backup'),
                      subtitle: const Text(
                          'Salva configuração, cardápio, pedidos e logs no servidor.'),
                      onTap: () => _backup(context),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.receipt_long_outlined),
                      title: const Text('Ver logs recentes'),
                      onTap: () => _logs(context),
                    ),
                    const Divider(),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.logout, color: Colors.red),
                      title: const Text('Sair deste aparelho',
                          style: TextStyle(
                              color: Colors.red, fontWeight: FontWeight.w700)),
                      onTap: controller.logout,
                    ),
                  ]),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _editTile(
          BuildContext context, String titulo, String valor, String campo,
          {bool multiline = false}) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(titulo),
        subtitle: Text(valor.isEmpty ? 'Não configurado' : valor,
            maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.edit_outlined),
        onTap: () =>
            _editarTexto(context, titulo, campo, valor, multiline: multiline),
      );

  Widget _pagamentoSwitch(
          BuildContext context, String titulo, String chave, bool valor) =>
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: Text(titulo),
        value: valor,
        onChanged: (v) async {
          final dados = copiaMapa(_dados);
          final p =
              Map<String, dynamic>.from(dados['pagamentos'] as Map? ?? {});
          p.remove('cartao');
          p[chave] = v;
          dados['pagamentos'] = p;
          try {
            await controller.salvarConfigDados(dados);
          } catch (e) {
            if (context.mounted) await mostrarErro(context, e);
          }
        },
      );

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

  Future<void> _editarTexto(
      BuildContext context, String titulo, String campo, String atual,
      {bool multiline = false}) async {
    final dados = copiaMapa(_dados);
    final versao = controller.configuracao['versao'] as int;
    await editarCampos(context, titulo: titulo, campos: [
      CampoEdicao('valor', titulo, atual,
          linhas: multiline ? 3 : 1,
          validar: (v) => campo == 'nomeEstabelecimento' && v.isEmpty
              ? 'Informe o nome.'
              : v.length > 1000
                  ? 'Use até 1000 caracteres.'
                  : null)
    ], salvar: (valores) async {
      dados[campo] = valores['valor'];
      await controller.salvarConfigDados(dados, versaoEsperada: versao);
    });
  }

  Widget _cidadeEntregaTile(BuildContext context, Map<String, dynamic> cidade) {
    final nome = cidade['nome']?.toString() ?? 'Cidade';
    final uf = cidade['uf']?.toString() ?? '';
    final taxa = (cidade['taxa'] as num?)?.toDouble() ?? 0;
    final ativa = cidade['ativa'] == true;
    final id = cidade['id']?.toString() ?? '';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Switch.adaptive(
        value: ativa,
        onChanged: (v) => _alterarCidadeEntrega(context, id, ativa: v),
      ),
      title: Text('$nome${uf.isEmpty ? '' : ' - $uf'}'),
      subtitle: Text('Taxa: ${dinheiro(taxa)}'),
      trailing: const Icon(Icons.edit_outlined),
      onTap: () => _editarTaxaCidade(context, id, nome, taxa),
    );
  }

  Future<void> _alterarCidadeEntrega(
    BuildContext context,
    String id, {
    bool? ativa,
    double? taxa,
  }) async {
    final dados = copiaMapa(_dados);
    final cidades = List<Map<String, dynamic>>.from(
      (dados['cidadesEntrega'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map)),
    );
    final index = cidades.indexWhere((e) => e['id']?.toString() == id);
    if (index < 0) return;
    final atual = Map<String, dynamic>.from(cidades[index]);
    if (ativa != null) atual['ativa'] = ativa;
    if (taxa != null) atual['taxa'] = taxa;
    cidades[index] = atual;
    dados['cidadesEntrega'] = cidades;
    try {
      await controller.salvarConfigDados(dados);
    } catch (e) {
      if (context.mounted) await mostrarErro(context, e);
    }
  }

  Future<void> _editarTaxaCidade(
      BuildContext context, String id, String nome, double atual) async {
    final dados = copiaMapa(_dados);
    final versao = controller.configuracao['versao'] as int;
    await editarCampos(context, titulo: 'Taxa de $nome', campos: [
      CampoEdicao(
          'taxa', r'Taxa (R$)', atual.toStringAsFixed(2).replaceAll('.', ','),
          validar: validarDinheiro)
    ], salvar: (valores) async {
      final cidades = dados['cidadesEntrega'] as List;
      final cidade = cidades.firstWhere((e) => e['id'] == id) as Map;
      cidade['taxa'] = double.parse(valores['taxa']!.replaceAll(',', '.'));
      await controller.salvarConfigDados(dados, versaoEsperada: versao);
    });
  }

  Future<void> _backup(BuildContext context) async {
    try {
      final caminho = await controller.gerarBackup();
      if (!context.mounted) return;
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Backup gerado'),
          content: SelectableText('Arquivo salvo no servidor em:\n\n$caminho'),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'))
          ],
        ),
      );
    } catch (e) {
      if (context.mounted) await mostrarErro(context, e);
    }
  }

  Future<void> _logs(BuildContext context) async {
    try {
      await controller.carregarLogs();
      if (!context.mounted) return;
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: .8,
          minChildSize: .5,
          maxChildSize: .95,
          builder: (context, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.all(20),
            children: [
              const Text('Logs recentes',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
              const SizedBox(height: 12),
              if (controller.logs.isEmpty)
                const Text('Nenhum log.')
              else
                ...controller.logs.map((l) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l['evento']?.toString() ?? ''),
                      subtitle: Text(
                          '${l['criadoEm'] ?? ''}\n${l['detalhes'] ?? ''}'),
                      leading: Icon(l['nivel'] == 'ERROR'
                          ? Icons.error_outline
                          : l['nivel'] == 'WARN'
                              ? Icons.warning_amber_outlined
                              : Icons.info_outline),
                    )),
            ],
          ),
        ),
      );
    } catch (e) {
      if (context.mounted) await mostrarErro(context, e);
    }
  }
}

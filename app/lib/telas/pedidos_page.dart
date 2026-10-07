import 'package:flutter/material.dart';
import '../servicos/app_controller.dart';
import '../widgets/editor_dialog.dart';
import '../widgets/ui.dart';

class PedidosPage extends StatefulWidget {
  final AppController controller;
  const PedidosPage({super.key, required this.controller});

  @override
  State<PedidosPage> createState() => _PedidosPageState();
}

class _PedidosPageState extends State<PedidosPage> {
  String filtro = 'abertos';

  @override
  Widget build(BuildContext context) {
    final todos = widget.controller.pedidos;
    final lista = todos.where((p) {
      final s = p['status']?.toString() ?? '';
      if (filtro == 'abertos') return !['finalizado', 'cancelado'].contains(s);
      if (filtro == 'todos') return true;
      return s == filtro;
    }).toList();

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: widget.controller.carregarTudo,
        child: ListView(
          padding: margemPagina(context),
          children: [
            const TituloPagina('Pedidos',
                subtitulo: 'Acompanhe e atualize sem complicação'),
            const SizedBox(height: 18),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final f in const [
                    ('abertos', 'Abertos'),
                    ('novo', 'Novos'),
                    ('confirmado', 'Confirmados'),
                    ('pronto', 'Prontos'),
                    ('finalizado', 'Finalizados'),
                    ('cancelado', 'Cancelados'),
                    ('todos', 'Todos'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(f.$2),
                        selected: filtro == f.$1,
                        onSelected: (_) => setState(() => filtro = f.$1),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (lista.isEmpty)
              const PainelCard(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                      child: Text('Nenhum pedido neste filtro.',
                          style: TextStyle(color: Colors.black54))),
                ),
              )
            else
              ...lista.map((p) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _PedidoCard(
                      pedido: p,
                      onTap: () => _abrirPedido(context, p),
                    ),
                  )),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Future<void> _abrirPedido(
      BuildContext context, Map<String, dynamic> pedido) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (context) =>
          _DetalhePedido(controller: widget.controller, pedido: pedido),
    );
  }
}

class _PedidoCard extends StatelessWidget {
  final Map<String, dynamic> pedido;
  final VoidCallback onTap;
  const _PedidoCard({required this.pedido, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final status = pedido['status']?.toString() ?? '';
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: _corStatus(status).withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(16),
                ),
                alignment: Alignment.center,
                child: Text('#${pedido['numero']}',
                    style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: _corStatus(status))),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                          child: Text(
                              pedido['clienteNome']?.toString() ?? 'Cliente',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800, fontSize: 16))),
                      Text(dinheiro(pedido['total']),
                          style: const TextStyle(fontWeight: FontWeight.w900)),
                    ]),
                    const SizedBox(height: 5),
                    Text(_resumoItens(pedido),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.black54)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 6, children: [
                      _Tag(_nomeStatus(status), _corStatus(status)),
                      _Tag(
                          pedido['recebimento'] == 'entrega'
                              ? 'Entrega'
                              : 'Retirada',
                          Colors.blueGrey),
                      _Tag(
                          _nomePagamento(pedido['pagamento']?.toString() ?? ''),
                          Colors.deepPurple),
                    ]),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }

  String _resumoItens(Map<String, dynamic> pedido) {
    final itens = pedido['itens'];
    if (itens is! List) return '';
    return itens.map((raw) {
      final i = Map<String, dynamic>.from(raw as Map);
      final base =
          '${i['arrozNome'] ?? 'Arroz'} + ${i['feijaoNome'] ?? 'Feijão'}';
      return '${i['quantidade']}x ${i['tamanhoNome']} • $base • '
          '${_nomesEscolhasItem(i, 'misturaNomes', 'misturaNome')}';
    }).join(' | ');
  }
}

String _nomesEscolhasItem(
  Map<String, dynamic> item,
  String campoLista,
  String campoLegado,
) {
  final nomes = item[campoLista];
  if (nomes is List && nomes.isNotEmpty) {
    return nomes.map((nome) => nome.toString()).join(' + ');
  }
  return item[campoLegado]?.toString() ?? '';
}

class _DetalhePedido extends StatefulWidget {
  final AppController controller;
  final Map<String, dynamic> pedido;
  const _DetalhePedido({required this.controller, required this.pedido});

  @override
  State<_DetalhePedido> createState() => _DetalhePedidoState();
}

class _DetalhePedidoState extends State<_DetalhePedido> {
  bool salvando = false;
  late Map<String, dynamic> pedido = widget.pedido;

  @override
  Widget build(BuildContext context) {
    final itens = (pedido['itens'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final bebidas = (pedido['bebidas'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .88,
      minChildSize: .55,
      maxChildSize: .96,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
        children: [
          Center(
              child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(4)))),
          const SizedBox(height: 18),
          Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Text('Pedido #${pedido['numero']}',
                    style: const TextStyle(
                        fontSize: 26, fontWeight: FontWeight.w900)),
                _Tag(_nomeStatus(pedido['status']?.toString() ?? ''),
                    _corStatus(pedido['status']?.toString() ?? '')),
              ]),
          const SizedBox(height: 6),
          Text(pedido['clienteNome']?.toString() ?? 'Cliente',
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          Text(pedido['telefone']?.toString() ?? '',
              style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 18),
          PainelCard(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Itens',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              const SizedBox(height: 10),
              for (final i in itens) ...[
                Text(
                    '${i['quantidade']}x ${i['tamanhoNome']} — ${dinheiro((i['precoUnitario'] as num?)?.toDouble() ?? 0)}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                Text(
                    '${i['arrozNome'] ?? 'Arroz'} + ${i['feijaoNome'] ?? 'Feijão'}\n'
                    '${_nomesEscolhasItem(i, 'misturaNomes', 'misturaNome')} • '
                    '${_nomesEscolhasItem(i, 'acompanhamentoNomes', 'acompanhamentoNome')}',
                    style: const TextStyle(color: Colors.black54)),
                const SizedBox(height: 10),
              ],
              if (bebidas.isNotEmpty) ...[
                const Divider(height: 22),
                const Text('Bebidas',
                    style:
                        TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                const SizedBox(height: 10),
                for (final b in bebidas)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '${b['quantidade']}x ${b['nome']} — ${dinheiro(((b['precoUnitario'] as num?)?.toDouble() ?? 0) * ((b['quantidade'] as num?)?.toInt() ?? 1))}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
              ],
            ]),
          ),
          const SizedBox(height: 12),
          PainelCard(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _linha('Recebimento',
                  pedido['recebimento'] == 'entrega' ? 'Entrega' : 'Retirada'),
              if ((pedido['endereco']?.toString().isNotEmpty ?? false))
                _linha('Endereço', pedido['endereco'].toString()),
              if ((pedido['cidadeEntrega']?.toString().isNotEmpty ?? false))
                _linha('Cidade', _cidadeUf(pedido)),
              if ((pedido['cepEntrega']?.toString().isNotEmpty ?? false))
                _linha('CEP', _formatarCep(pedido['cepEntrega'].toString())),
              if (pedido['recebimento'] == 'entrega')
                _linha(
                  'Origem da cidade',
                  (pedido['cepEntrega']?.toString().isNotEmpty ?? false)
                      ? 'Endereço validado por CEP'
                      : 'Confirmada pelo cliente',
                ),
              _linha('Pagamento',
                  _nomePagamento(pedido['pagamento']?.toString() ?? '')),
              if (pedido['trocoPara'] != null)
                _linha('Troco para', dinheiro(pedido['trocoPara'])),
              if ((pedido['observacao']?.toString().trim().isNotEmpty ?? false))
                _linha('Observação', pedido['observacao'].toString()),
              if ((pedido['motivoCancelamento']?.toString().trim().isNotEmpty ??
                  false))
                _linha('Motivo da recusa',
                    pedido['motivoCancelamento'].toString()),
              const Divider(height: 24),
              _linha('Subtotal', dinheiro(pedido['subtotal']), destaque: false),
              if ((pedido['taxaEntrega'] as num?)?.toDouble() != 0)
                _linha('Entrega', dinheiro(pedido['taxaEntrega']),
                    destaque: false),
              if ((pedido['taxaMaquininha'] as num?)?.toDouble() != 0)
                _linha('Taxa da maquininha', dinheiro(pedido['taxaMaquininha']),
                    destaque: false),
              _linha('TOTAL', dinheiro(pedido['total']), destaque: true),
            ]),
          ),
          const SizedBox(height: 18),
          _acoes(context),
        ],
      ),
    );
  }

  String _cidadeUf(Map<String, dynamic> p) {
    final cidade = p['cidadeEntrega']?.toString().trim() ?? '';
    final uf = p['ufEntrega']?.toString().trim() ?? '';
    return uf.isEmpty ? cidade : '$cidade - $uf';
  }

  String _formatarCep(String valor) {
    final c = valor.replaceAll(RegExp(r'\D'), '');
    if (c.length != 8) return valor;
    return '${c.substring(0, 5)}-${c.substring(5)}';
  }

  Widget _linha(String a, String b, {bool destaque = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: MediaQuery.sizeOf(context).width < 380 ? 88 : 110,
              child: Text(a,
                  style: TextStyle(
                      color: destaque ? Colors.black : Colors.black54,
                      fontWeight:
                          destaque ? FontWeight.w800 : FontWeight.w500))),
          Expanded(
              child: Text(b,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontWeight: destaque ? FontWeight.w900 : FontWeight.w600,
                      fontSize: destaque ? 18 : 14))),
        ]),
      );

  Widget _acoes(BuildContext context) {
    final status = pedido['status']?.toString() ?? '';
    final acoes = <(String, String, IconData)>[];
    if (status == 'novo') {
      acoes.add(('confirmado', 'Confirmar pedido', Icons.check_circle_outline));
      acoes.add(('cancelado', 'Recusar pedido', Icons.cancel_outlined));
    }
    if (status == 'confirmado') {
      acoes.add(('pronto', 'Marcar como pronto', Icons.restaurant_outlined));
    }
    if (status == 'pronto') {
      acoes.add(('finalizado', 'Finalizar pedido', Icons.done_all));
    }
    if (acoes.isEmpty) return const SizedBox.shrink();

    return Column(
      children: [
        for (final a in acoes)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SizedBox(
              width: double.infinity,
              child: a.$1 == 'cancelado'
                  ? OutlinedButton.icon(
                      onPressed: salvando ? null : _recusar,
                      icon: Icon(a.$3),
                      label: Text(a.$2))
                  : FilledButton.icon(
                      onPressed: salvando ? null : () => _mudar(a.$1),
                      icon: Icon(a.$3),
                      label: Text(a.$2)),
            ),
          ),
      ],
    );
  }

  Future<void> _mudar(String status) async {
    setState(() => salvando = true);
    try {
      await widget.controller.alterarStatusPedido(pedido, status);
      final atualizado =
          widget.controller.pedidos.firstWhere((p) => p['id'] == pedido['id']);
      if (mounted) setState(() => pedido = atualizado);
    } catch (e) {
      if (mounted) await mostrarErro(context, e);
    } finally {
      if (mounted) setState(() => salvando = false);
    }
  }

  Future<void> _recusar() async {
    await editarCampos(
      context,
      titulo: 'Recusar pedido #${pedido['numero']}',
      campos: [
        CampoEdicao('motivo', 'Motivo da recusa', '', linhas: 3,
            validar: (valor) {
          if (valor.isEmpty) return 'Informe o motivo para o cliente.';
          if (valor.length > 300) return 'Use até 300 caracteres.';
          return null;
        })
      ],
      textoCancelar: 'Voltar',
      textoSalvar: 'Recusar pedido',
      mensagemSucesso: 'Pedido recusado. O cliente será avisado.',
      salvar: (valores) async {
        await widget.controller.alterarStatusPedido(pedido, 'cancelado',
            motivoCancelamento: valores['motivo']);
        final atualizado = widget.controller.pedidos
            .firstWhere((p) => p['id'] == pedido['id']);
        if (mounted) setState(() => pedido = atualizado);
      },
    );
  }
}

class _Tag extends StatelessWidget {
  final String texto;
  final Color cor;
  const _Tag(this.texto, this.cor);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
            color: cor.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(999)),
        child: Text(texto,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w800, color: cor)),
      );
}

Color _corStatus(String s) => switch (s) {
      'novo' => Colors.orange,
      'confirmado' => Colors.blue,
      'pronto' => Colors.green,
      'finalizado' => Colors.teal,
      'cancelado' => Colors.red,
      _ => Colors.grey,
    };

String _nomeStatus(String s) => switch (s) {
      'novo' => 'NOVO',
      'confirmado' => 'CONFIRMADO',
      'pronto' => 'PRONTO',
      'finalizado' => 'FINALIZADO',
      'cancelado' => 'CANCELADO',
      _ => s.toUpperCase(),
    };

String _nomePagamento(String s) => switch (s) {
      'pix' => 'PIX',
      'dinheiro' => 'Dinheiro',
      'credito' => 'Cartão de crédito',
      'debito' => 'Cartão de débito',
      'cartao' => 'Cartão',
      _ => s,
    };

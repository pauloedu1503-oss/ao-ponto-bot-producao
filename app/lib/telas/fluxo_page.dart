import '../widgets/editor_dialog.dart';
import 'package:flutter/material.dart';

import '../servicos/app_controller.dart';
import '../servicos/fluxo_padrao.dart';
import '../widgets/ui.dart';

class FluxoPage extends StatefulWidget {
  final AppController controller;
  const FluxoPage({super.key, required this.controller});

  @override
  State<FluxoPage> createState() => _FluxoPageState();
}

class _FluxoPageState extends State<FluxoPage> {
  String selecionada = 'inicio';

  static const etapas = <_EtapaDef>[
    _EtapaDef('inicio', 'Início', Icons.waving_hand_outlined,
        'Primeiro menu que o cliente vê.'),
    _EtapaDef('cardapio', 'Cardápio', Icons.menu_book_outlined,
        'Texto mostrado quando o cliente consulta o cardápio.'),
    _EtapaDef('tamanho', 'Tamanho', Icons.straighten_outlined,
        'Escolha da Pequena, Média ou Grande.'),
    _EtapaDef('mistura', 'Mistura', Icons.lunch_dining_outlined,
        'Escolha da mistura disponível.'),
    _EtapaDef('acompanhamento', 'Acompanhamento', Icons.ramen_dining_outlined,
        'Escolha de um acompanhamento.'),
    _EtapaDef('quantidade', 'Quantidade', Icons.numbers_outlined,
        'Quantidade de marmitas iguais.'),
    _EtapaDef('adicionarOutro', 'Outro item', Icons.add_shopping_cart_outlined,
        'Adicionar outra marmita ou finalizar.'),
    _EtapaDef('recebimento', 'Entrega ou retirada',
        Icons.delivery_dining_outlined, 'Como o cliente receberá o pedido.'),
    _EtapaDef('endereco', 'Endereço', Icons.location_on_outlined,
        'Pedido do endereço quando for entrega.'),
    _EtapaDef(
      'cidadeEntrega',
      'Cidade da entrega',
      Icons.location_city_outlined,
      'Escolha da cidade e cálculo da taxa.',
    ),
    _EtapaDef('pagamento', 'Pagamento', Icons.payments_outlined,
        'PIX, dinheiro ou cartão.'),
    _EtapaDef('troco', 'Troco', Icons.currency_exchange_outlined,
        'Só aparece quando o pagamento é dinheiro.'),
    _EtapaDef('observacao', 'Observação', Icons.edit_note_outlined,
        'Etapa opcional antes do resumo.'),
    _EtapaDef('resumo', 'Resumo e confirmação', Icons.receipt_long_outlined,
        'Conferência final antes de criar o pedido.'),
    _EtapaDef('sistema', 'Mensagens do sistema', Icons.shield_outlined,
        'Cancelamento, expiração e atendimento humano.'),
  ];

  Map<String, dynamic> get _dados => Map<String, dynamic>.from(
      widget.controller.configuracao['dados'] as Map? ?? {});

  Map<String, dynamic> get _fluxo =>
      Map<String, dynamic>.from(_dados['fluxo'] as Map? ?? fluxoPadraoApp());

  Map<String, dynamic> _etapa(String chave) =>
      Map<String, dynamic>.from(_fluxo[chave] as Map? ?? {});

  @override
  Widget build(BuildContext context) {
    final def = etapas.firstWhere((e) => e.chave == selecionada);
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: widget.controller.carregarTudo,
        child: LayoutBuilder(
          builder: (context, c) {
            final desktop = c.maxWidth >= 980;
            final lista = _listaEtapas(context);
            final editor = _editor(context, def);
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                TituloPagina(
                  'Fluxo do Bot',
                  subtitulo:
                      'Você controla o que o cliente lê; a lógica crítica continua protegida.',
                  acao: OutlinedButton.icon(
                    onPressed: () => _restaurarTudo(context),
                    icon: const Icon(Icons.restore_outlined),
                    label: const Text('Restaurar padrão'),
                  ),
                ),
                const SizedBox(height: 14),
                PainelCard(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.lock_outline, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'A sequência principal, cálculos, validações e comandos de segurança ficam protegidos. '
                          'O comando 0 continua sendo Cancelar e “voltar” continua retornando uma etapa.',
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: Colors.black54),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (desktop)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 330, child: lista),
                      const SizedBox(width: 16),
                      Expanded(child: editor),
                    ],
                  )
                else ...[
                  lista,
                  const SizedBox(height: 16),
                  editor,
                ],
                const SizedBox(height: 40),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _listaEtapas(BuildContext context) {
    return PainelCard(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(10, 8, 10, 6),
            child: Text('ETAPAS',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    color: Colors.black54)),
          ),
          ...etapas.indexed.map((item) {
            final i = item.$1;
            final e = item.$2;
            final ativo = selecionada == e.chave;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: ListTile(
                selected: ativo,
                selectedTileColor: Theme.of(context)
                    .colorScheme
                    .secondary
                    .withValues(alpha: .45),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                leading: CircleAvatar(
                  radius: 17,
                  backgroundColor: ativo
                      ? Colors.black
                      : Colors.black.withValues(alpha: .06),
                  foregroundColor: ativo ? Colors.white : Colors.black87,
                  child: Text('${i + 1}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w900, fontSize: 12)),
                ),
                title: Text(e.titulo,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text(e.descricao,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: Icon(e.icon, size: 20),
                onTap: () => setState(() => selecionada = e.chave),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _editor(BuildContext context, _EtapaDef def) {
    final etapa = _etapa(def.chave);
    return Column(
      children: [
        PainelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .secondary
                          .withValues(alpha: .55),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(def.icon),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(def.titulo,
                            style: const TextStyle(
                                fontSize: 20, fontWeight: FontWeight.w900)),
                        Text(def.descricao,
                            style: const TextStyle(color: Colors.black54)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Restaurar esta etapa',
                    onPressed: () => _restaurarEtapa(context, def.chave),
                    icon: const Icon(Icons.restore_outlined),
                  ),
                ],
              ),
              const Divider(height: 28),
              ..._campos(context, def.chave, etapa),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _preview(context, def.chave, etapa),
      ],
    );
  }

  List<Widget> _campos(
      BuildContext context, String etapa, Map<String, dynamic> dados) {
    final widgets = <Widget>[];

    void campo(String chave, String titulo,
        {String? ajuda, int linhas = 3, int max = 1000}) {
      widgets.add(ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(titulo),
        subtitle: Text(dados[chave]?.toString() ?? '',
            maxLines: 3, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.edit_outlined),
        onTap: () => _editarCampo(
            context, etapa, chave, titulo, dados[chave]?.toString() ?? '',
            linhas: linhas, max: max),
      ));
      widgets.add(const SizedBox(height: 12));
    }

    void toggle(String chave, String titulo, String subtitulo) {
      widgets.add(SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        value: dados[chave] == true,
        title:
            Text(titulo, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(subtitulo),
        onChanged: (v) => _salvarCampo(context, etapa, chave, v),
      ));
      widgets.add(const SizedBox(height: 6));
    }

    switch (etapa) {
      case 'inicio':
        campo('mensagem', 'Pergunta principal', linhas: 2);
        campo('botaoPedido', 'Botão • Fazer pedido', linhas: 1, max: 20);
        campo('botaoCardapio', 'Botão • Ver cardápio', linhas: 1, max: 20);
        campo('botaoHumano', 'Botão • Atendimento humano', linhas: 1, max: 20);
        break;
      case 'cardapio':
        campo('titulo', 'Título do cardápio', linhas: 1);
        campo('rodape', 'Texto no fim do cardápio', linhas: 2);
        break;
      case 'tamanho':
        campo('mensagem', 'Pergunta ao cliente', linhas: 2);
        campo('tituloLista', 'Botão da lista quando houver muitos tamanhos',
            linhas: 1, max: 20);
        break;
      case 'mistura':
        campo('mensagem', 'Pergunta ao cliente', linhas: 2);
        campo('tituloLista', 'Botão da lista quando houver muitas misturas',
            linhas: 1, max: 20);
        break;
      case 'acompanhamento':
        campo('mensagem', 'Pergunta ao cliente', linhas: 2);
        campo('tituloLista', 'Botão da lista quando houver muitas opções',
            linhas: 1, max: 20);
        break;
      case 'quantidade':
        campo('mensagem', 'Pergunta ao cliente', linhas: 2);
        campo('ajuda', 'Texto de ajuda',
            ajuda: 'Use {max} onde deseja mostrar o limite configurado.',
            linhas: 2);
        widgets.add(ListTile(
            title: const Text('Quantidade máxima por item'),
            subtitle: Text((dados['maximo'] ?? 20).toString()),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () => _editarCampo(
                context,
                etapa,
                'maximo',
                'Quantidade máxima por item',
                (dados['maximo'] ?? 20).toString(),
                numero: true)));
        break;
      case 'adicionarOutro':
        campo('mensagem', 'Pergunta ao cliente', linhas: 2);
        campo('botaoSim', 'Botão • Adicionar outra', linhas: 1, max: 20);
        campo('botaoNao', 'Botão • Finalizar pedido', linhas: 1, max: 20);
        break;
      case 'recebimento':
        campo('mensagem', 'Pergunta ao cliente', linhas: 2);
        campo('botaoEntrega', 'Botão • Entrega', linhas: 1, max: 20);
        campo('botaoRetirada', 'Botão • Retirada', linhas: 1, max: 20);
        toggle('pularSeUnica', 'Pular pergunta quando existir só uma opção',
            'Ex.: se apenas Retirada estiver ativa, o bot assume Retirada automaticamente.');
        break;
      case 'endereco':
        campo('mensagem', 'Como pedir o endereço', linhas: 4);
        break;
      case 'cidadeEntrega':
        campo(
          'mensagem',
          'Pergunta sobre a cidade',
          linhas: 2,
        );
        break;
      case 'pagamento':
        campo('mensagem', 'Pergunta ao cliente', linhas: 2);
        campo('botaoPix', 'Botão • PIX', linhas: 1, max: 20);
        campo('botaoDinheiro', 'Botão • Dinheiro', linhas: 1, max: 20);
        toggle('pularSeUnica', 'Pular pergunta quando existir só uma forma',
            'Se apenas uma forma estiver ativa, ela será escolhida automaticamente.');
        break;
      case 'troco':
        campo('mensagem', 'Pergunta sobre troco', linhas: 3);
        campo('textoSemTroco', 'Resposta para “sem troco”',
            ajuda: 'Não use 0, cancelar, voltar ou atendente.',
            linhas: 1,
            max: 30);
        break;
      case 'observacao':
        widgets.add(const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
                'Ative ou desative esta etapa em Configurações > Montagem do pedido.')));
        campo('mensagem', 'Pergunta ao cliente', linhas: 3);
        campo('mensagemAlterar', 'Texto quando o cliente voltar para alterar',
            linhas: 2);
        campo('textoNenhuma', 'Resposta para “nenhuma observação”',
            ajuda: 'Não use 0, cancelar, voltar ou atendente.',
            linhas: 1,
            max: 30);
        break;
      case 'resumo':
        campo('titulo', 'Título do resumo', linhas: 1);
        campo('botaoConfirmar', 'Botão • Confirmar', linhas: 1, max: 20);
        campo('botaoRefazer', 'Botão • Refazer pedido', linhas: 1, max: 20);
        campo('botaoCancelar', 'Botão • Cancelar', linhas: 1, max: 20);
        break;
      case 'sistema':
        campo('sessaoExpirada', 'Sessão expirada', linhas: 3);
        campo('pedidoCancelado', 'Pedido cancelado', linhas: 3);
        campo('humanoAtivado', 'Entrou em atendimento humano', linhas: 3);
        campo('retomado', 'Bot retomado depois do atendimento humano',
            linhas: 2);
        campo('refazer', 'Ao refazer o pedido', linhas: 2);
        break;
    }
    return widgets;
  }

  Widget _preview(BuildContext context, String chave, Map<String, dynamic> d) {
    final mensagens = <String>[];
    List<String> botoes = [];
    switch (chave) {
      case 'inicio':
        mensagens.add(d['mensagem']?.toString() ?? '');
        botoes = [d['botaoPedido'], d['botaoCardapio'], d['botaoHumano']]
            .map((e) => '$e')
            .toList();
        break;
      case 'cardapio':
        mensagens.add(
            '${d['titulo'] ?? ''}\n\n• Pequena — R\$ 8,00\n• Média — R\$ 15,00\n• Grande — R\$ 20,00\n\nMisturas:\n• Bife acebolado\n• Filé de frango\n\nAcompanhamentos:\n• Macarrão\n• Batata\n\n${d['rodape'] ?? ''}');
        final inicio = _etapa('inicio');
        botoes = [
          '${inicio['botaoPedido'] ?? 'Fazer pedido'}',
          '${inicio['botaoHumano'] ?? 'Falar atendente'}'
        ];
        break;
      case 'tamanho':
        mensagens.add(d['mensagem']?.toString() ?? '');
        botoes = ['Pequena R\$ 8,00', 'Média R\$ 15,00', 'Grande R\$ 20,00'];
        break;
      case 'mistura':
        mensagens.add(d['mensagem']?.toString() ?? '');
        botoes = ['Bife acebolado', 'Filé de frango', 'Calabresa'];
        break;
      case 'acompanhamento':
        mensagens.add(d['mensagem']?.toString() ?? '');
        botoes = ['Macarrão', 'Batata'];
        break;
      case 'quantidade':
        final max = d['maximo'] ?? 20;
        mensagens.add(
            '${d['mensagem'] ?? ''}\n${(d['ajuda'] ?? '').toString().replaceAll('{max}', '$max')}\n\n0 cancela • voltar retorna');
        break;
      case 'adicionarOutro':
        mensagens.add(d['mensagem']?.toString() ?? '');
        botoes = ['${d['botaoSim']}', '${d['botaoNao']}'];
        break;
      case 'recebimento':
        mensagens.add(d['mensagem']?.toString() ?? '');
        botoes = ['${d['botaoEntrega']}', '${d['botaoRetirada']}'];
        break;
      case 'endereco':
        mensagens.add('${d['mensagem'] ?? ''}\n\nDigite voltar para retornar.');
        break;
      case 'cidadeEntrega':
        mensagens.add(
          '${d['mensagem'] ?? ''}\n\n'
          '• Barra Bonita — R\$ 8,00\n'
          '• Igaraçu do Tietê — R\$ 10,00',
        );

        botoes = [
          'Barra Bonita',
          'Igaraçu do Tietê',
        ];
        break;
      case 'pagamento':
        mensagens.add(d['mensagem']?.toString() ?? '');
        botoes = [
          '${d['botaoPix']}',
          '${d['botaoDinheiro']}',
          'Cartão de crédito',
          'Cartão de débito'
        ];
        break;
      case 'troco':
        mensagens.add(d['mensagem']?.toString() ?? '');
        break;
      case 'observacao':
        mensagens.add(
            '${d['mensagem'] ?? ''}\nDigite ${d['textoNenhuma'] ?? 'não'} para nenhuma.');
        break;
      case 'resumo':
        mensagens.add(
            '${d['titulo'] ?? ''}\n\n1x Média — R\$ 15,00\nBife acebolado • Macarrão\n🥗 Salada do dia\n\n🏠 Retirada\n💳 PIX\n\nTOTAL: R\$ 15,00');
        botoes = [
          '${d['botaoConfirmar']}',
          '${d['botaoRefazer']}',
          '${d['botaoCancelar']}'
        ];
        break;
      case 'sistema':
        mensagens.add(d['pedidoCancelado']?.toString() ?? '');
        break;
    }

    final menu = widget.controller.cardapio;
    List<Map> ativos(String colecao) => (menu[colecao] as List? ?? [])
        .whereType<Map>()
        .where((e) => e['ativo'] == true)
        .toList();
    if (chave == 'tamanho') {
      botoes = ativos('tamanhos')
          .map((e) => '${e['nome']} ${dinheiro(e['preco'])}')
          .toList();
    } else if (chave == 'mistura' || chave == 'acompanhamento') {
      botoes = ativos(chave == 'mistura' ? 'misturas' : 'acompanhamentos')
          .map((e) => e['nome'].toString())
          .toList();
    } else if (chave == 'cidadeEntrega') {
      final cidades = (_dados['cidadesEntrega'] as List? ?? [])
          .whereType<Map>()
          .where((e) => e['ativa'] == true)
          .toList();
      mensagens
        ..clear()
        ..add(
            '${d['mensagem'] ?? ''}\n\n${cidades.map((e) => '${e['nome']} — ${dinheiro(e['taxa'])}').join('\n')}');
      botoes = cidades.map((e) => e['nome'].toString()).toList();
    } else if (chave == 'recebimento') {
      botoes = [
        if (_dados['entregaAtiva'] == true) d['botaoEntrega'].toString(),
        if (_dados['retiradaAtiva'] == true) d['botaoRetirada'].toString()
      ];
    } else if (chave == 'pagamento') {
      final pagamentos = _dados['pagamentos'] as Map? ?? {};
      botoes = [
        if (pagamentos['pix'] == true) d['botaoPix'].toString(),
        if (pagamentos['dinheiro'] == true) d['botaoDinheiro'].toString(),
        if (pagamentos['credito'] == true ||
            (pagamentos['credito'] == null && pagamentos['cartao'] == true))
          'Cartão de crédito',
        if (pagamentos['debito'] == true ||
            (pagamentos['debito'] == null && pagamentos['cartao'] == true))
          'Cartão de débito'
      ];
    } else if (chave == 'cardapio') {
      mensagens
        ..clear()
        ..add([
          d['titulo'],
          ...ativos('tamanhos')
              .map((e) => '${e['nome']} — ${dinheiro(e['preco'])}'),
          'Misturas:',
          ...ativos('misturas').map((e) => e['nome']),
          'Acompanhamentos:',
          ...ativos('acompanhamentos').map((e) => e['nome']),
          d['rodape']
        ].join('\n'));
    }

    return PainelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.visibility_outlined, size: 20),
            SizedBox(width: 8),
            Text(chave == 'resumo' ? 'Exemplo de resumo' : 'Pré-visualização',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900))
          ]),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: const Color(0xFFF3EFE3),
                borderRadius: BorderRadius.circular(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...mensagens.map((m) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 520),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12)),
                        child: Text(m.replaceAll('*', ''),
                            style: const TextStyle(height: 1.35)),
                      ),
                    )),
                if (botoes.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: botoes
                        .where((b) => b.trim().isNotEmpty)
                        .map((b) =>
                            OutlinedButton(onPressed: null, child: Text(b)))
                        .toList(),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editarCampo(BuildContext context, String etapa, String campo,
      String titulo, String valor,
      {int linhas = 1, int max = 1000, bool numero = false}) async {
    final dados = copiaMapa(_dados);
    final versao = widget.controller.configuracao['versao'] as int;
    await editarCampos(context, titulo: titulo, campos: [
      CampoEdicao('valor', titulo, valor, linhas: linhas, validar: (v) {
        if (numero) {
          final n = int.tryParse(v);
          return n == null || n < 1 || n > 50 ? 'Informe de 1 a 50.' : null;
        }
        return v.isEmpty || v.length > max
            ? 'Use de 1 a $max caracteres.'
            : null;
      })
    ], salvar: (v) async {
      (dados['fluxo'] as Map)[etapa][campo] =
          numero ? int.parse(v['valor']!) : v['valor'];
      await widget.controller.salvarConfigDados(dados, versaoEsperada: versao);
      if (mounted) setState(() {});
    });
  }

  Future<void> _salvarCampo(
      BuildContext context, String etapa, String campo, dynamic valor) async {
    final dados = copiaMapa(_dados);
    final fluxo =
        Map<String, dynamic>.from(dados['fluxo'] as Map? ?? fluxoPadraoApp());
    final atual = Map<String, dynamic>.from(fluxo[etapa] as Map? ?? {});
    atual[campo] = valor;
    fluxo[etapa] = atual;
    dados['fluxo'] = fluxo;
    try {
      await widget.controller.salvarConfigDados(dados);
      if (mounted) setState(() {});
    } catch (e) {
      if (context.mounted) await mostrarErro(context, e);
    }
  }

  Future<void> _restaurarEtapa(BuildContext context, String etapa) async {
    final ok = await _confirmar(context, 'Restaurar esta etapa?',
        'Os textos e botões desta etapa voltarão ao padrão.');
    if (!ok) return;
    final padrao = fluxoPadraoApp();
    final dados = copiaMapa(_dados);
    final fluxo = Map<String, dynamic>.from(dados['fluxo'] as Map? ?? {});
    fluxo[etapa] = Map<String, dynamic>.from(padrao[etapa] as Map);
    dados['fluxo'] = fluxo;
    try {
      await widget.controller.salvarConfigDados(dados);
      if (mounted) setState(() {});
    } catch (e) {
      if (context.mounted) await mostrarErro(context, e);
    }
  }

  Future<void> _restaurarTudo(BuildContext context) async {
    final ok = await _confirmar(context, 'Restaurar todo o fluxo?',
        'Todas as mensagens das etapas e nomes de botões voltarão ao padrão. Cardápio, preços e pedidos não serão alterados.');
    if (!ok) return;
    final dados = copiaMapa(_dados);
    dados['fluxo'] = fluxoPadraoApp();
    try {
      await widget.controller.salvarConfigDados(dados);
      if (mounted) setState(() {});
    } catch (e) {
      if (context.mounted) await mostrarErro(context, e);
    }
  }

  Future<bool> _confirmar(
      BuildContext context, String titulo, String texto) async {
    return await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(titulo),
            content: Text(texto),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Cancelar')),
              FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Restaurar')),
            ],
          ),
        ) ??
        false;
  }
}

class _EtapaDef {
  final String chave;
  final String titulo;
  final IconData icon;
  final String descricao;
  const _EtapaDef(this.chave, this.titulo, this.icon, this.descricao);
}

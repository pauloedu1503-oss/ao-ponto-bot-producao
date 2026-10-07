import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../widgets/editor_dialog.dart';
import '../servicos/app_controller.dart';
import '../widgets/ui.dart';

class CardapioPage extends StatelessWidget {
  final AppController controller;
  const CardapioPage({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final cardapio = controller.cardapio;
    final tamanhos = _lista(cardapio['tamanhos']);
    final misturas = _lista(cardapio['misturas']);
    final acompanhamentos = _lista(cardapio['acompanhamentos']);
    final bebidas = _lista(cardapio['bebidas']);
    final arrozes = _lista(cardapio['arrozes']);
    final feijoes = _lista(cardapio['feijoes']);

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: controller.recarregarCardapioEConfig,
        child: ListView(
          padding: margemPagina(context),
          children: [
            const TituloPagina('Cardápio',
                subtitulo:
                    'Alterações salvas aqui passam a valer para novos pedidos'),
            const SizedBox(height: 18),
            _ModoCardapio(controller: controller),
            const SizedBox(height: 16),
            _Secao(
              titulo: 'Tamanhos e preços',
              descricao:
                  'Defina o preço e quantas misturas e acompanhamentos cada tamanho exige (de 1 a 5).',
              onAdicionar: () => _editar(context, tipo: 'tamanho'),
              children: tamanhos
                  .map((i) => _ItemCard(
                        item: {
                          ...i,
                          'nome': _nomeTamanho(i),
                        },
                        subtitulo: dinheiro(i['preco']),
                        onToggle: (v) => _toggle(context, i, 'tamanhos', v),
                        onEditar: () =>
                            _editar(context, tipo: 'tamanho', existente: i),
                        onExcluir: () => _excluir(context, i, 'tamanhos'),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),
            _FluxoBase(
              titulo: 'Fluxo do arroz',
              descricao: cardapio['fluxoArrozAtivo'] == true
                  ? 'O cliente escolhe uma opção de arroz em cada marmita.'
                  : 'Desligado: o bot continua informando arroz + feijão como hoje.',
              ativo: cardapio['fluxoArrozAtivo'] == true,
              onAtivar: (v) => _toggleFluxo(context, 'fluxoArrozAtivo', v),
              onAdicionar: () => _editar(context, tipo: 'arroz'),
              children: arrozes
                  .map((i) => _ItemCard(
                        item: i,
                        onToggle: (v) => _toggle(context, i, 'arrozes', v),
                        onEditar: () =>
                            _editar(context, tipo: 'arroz', existente: i),
                        onExcluir: () => _excluir(context, i, 'arrozes'),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),
            _FluxoBase(
              titulo: 'Fluxo do feijão',
              descricao: cardapio['fluxoFeijaoAtivo'] == true
                  ? 'O cliente escolhe uma opção de feijão em cada marmita.'
                  : 'Desligado: não cria uma pergunta separada para feijão.',
              ativo: cardapio['fluxoFeijaoAtivo'] == true,
              onAtivar: (v) => _toggleFluxo(context, 'fluxoFeijaoAtivo', v),
              onAdicionar: () => _editar(context, tipo: 'feijao'),
              children: feijoes
                  .map((i) => _ItemCard(
                        item: i,
                        onToggle: (v) => _toggle(context, i, 'feijoes', v),
                        onEditar: () =>
                            _editar(context, tipo: 'feijao', existente: i),
                        onExcluir: () => _excluir(context, i, 'feijoes'),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),
            _Secao(
              titulo: 'Bebidas',
              descricao:
                  'Defina o preço e desative rapidamente quando uma bebida esgotar.',
              onAdicionar: () => _editar(context, tipo: 'bebida'),
              children: bebidas
                  .map((i) => _ItemCard(
                        item: i,
                        subtitulo: dinheiro(i['preco']),
                        onToggle: (v) => _toggle(context, i, 'bebidas', v),
                        onEditar: () =>
                            _editar(context, tipo: 'bebida', existente: i),
                        onExcluir: () => _excluir(context, i, 'bebidas'),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),
            _Secao(
              titulo: 'Misturas',
              descricao: 'Desative em um toque quando uma opção esgotar.',
              onAdicionar: () => _editar(context, tipo: 'mistura'),
              children: misturas
                  .map((i) => _ItemCard(
                        item: i,
                        onToggle: (v) => _toggle(context, i, 'misturas', v),
                        onEditar: () =>
                            _editar(context, tipo: 'mistura', existente: i),
                        onExcluir: () => _excluir(context, i, 'misturas'),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),
            _Secao(
              titulo: 'Acompanhamentos',
              descricao: 'O cliente escolhe um acompanhamento por marmita.',
              onAdicionar: () => _editar(context, tipo: 'acompanhamento'),
              children: acompanhamentos
                  .map((i) => _ItemCard(
                        item: i,
                        onToggle: (v) =>
                            _toggle(context, i, 'acompanhamentos', v),
                        onEditar: () => _editar(context,
                            tipo: 'acompanhamento', existente: i),
                        onExcluir: () =>
                            _excluir(context, i, 'acompanhamentos'),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _lista(dynamic value) {
    if (value is! List) return [];
    return value.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  String _nomeTamanho(Map<String, dynamic> tamanho) {
    final misturas = tamanho['quantidadeMisturas'] as int? ?? 1;
    final acompanhamentos = tamanho['quantidadeAcompanhamentos'] as int? ?? 1;
    final textoMisturas = misturas == 1 ? 'mistura' : 'misturas';
    final textoAcompanhamentos =
        acompanhamentos == 1 ? 'acompanhamento' : 'acompanhamentos';
    return '${tamanho['nome']} ($misturas $textoMisturas + '
        '$acompanhamentos $textoAcompanhamentos)';
  }

  Future<void> _toggle(BuildContext context, Map<String, dynamic> item,
      String colecao, bool ativo) async {
    final novo = copiaMapa(controller.cardapio);
    final lista = (novo[colecao] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final idx = lista.indexWhere((e) => e['id'] == item['id']);
    if (idx < 0) return;
    lista[idx]['ativo'] = ativo;
    novo[colecao] = lista;
    try {
      await controller.salvarCardapio(novo);
    } catch (e) {
      if (context.mounted) await mostrarErro(context, e);
    }
  }

  Future<void> _toggleFluxo(
      BuildContext context, String campo, bool ativo) async {
    final novo = copiaMapa(controller.cardapio);
    novo[campo] = ativo;
    try {
      await controller.salvarCardapio(novo);
    } catch (e) {
      if (context.mounted) await mostrarErro(context, e);
    }
  }

  Future<void> _editar(BuildContext context,
      {required String tipo, Map<String, dynamic>? existente}) async {
    final base = copiaMapa(controller.cardapio);
    final chave = switch (tipo) {
      'tamanho' => 'tamanhos',
      'mistura' => 'misturas',
      'acompanhamento' => 'acompanhamentos',
      'arroz' => 'arrozes',
      'feijao' => 'feijoes',
      _ => 'bebidas'
    };
    await editarCampos(context,
        titulo: existente == null ? 'Adicionar $tipo' : 'Editar $tipo',
        campos: [
          CampoEdicao('nome', 'Nome', existente?['nome']?.toString() ?? '',
              validar: (v) => v.isEmpty
                  ? 'Informe o nome.'
                  : v.length > 60
                      ? 'Use até 60 caracteres.'
                      : null),
          if (tipo == 'tamanho' || tipo == 'bebida')
            CampoEdicao(
                'preco', r'Preço (R$)', existente?['preco']?.toString() ?? '',
                validar: (v) => validarDinheiro(v, permitirZero: false)),
          if (tipo == 'tamanho') ...[
            CampoEdicao(
              'quantidadeMisturas',
              'Quantas misturas? (1 a 5)',
              '${existente?['quantidadeMisturas'] ?? 1}',
              validar: _validarQuantidadeEscolhas,
            ),
            CampoEdicao(
              'quantidadeAcompanhamentos',
              'Quantos acompanhamentos? (1 a 5)',
              '${existente?['quantidadeAcompanhamentos'] ?? 1}',
              validar: _validarQuantidadeEscolhas,
            ),
          ],
        ], salvar: (valores) async {
      final novo = copiaMapa(base);
      final lista = novo[chave] as List;
      final item = existente == null
          ? <String, dynamic>{
              'id': '',
              'tipo': tipo,
              'ativo': true,
              'ordem': lista.length + 1
            }
          : lista.firstWhere((e) => e['id'] == existente['id'])
              as Map<String, dynamic>;
      item['nome'] = valores['nome'];
      if (tipo == 'tamanho' || tipo == 'bebida') {
        item['preco'] = double.parse(valores['preco']!.replaceAll(',', '.'));
      }
      if (tipo == 'tamanho') {
        item['quantidadeMisturas'] = int.parse(valores['quantidadeMisturas']!);
        item['quantidadeAcompanhamentos'] =
            int.parse(valores['quantidadeAcompanhamentos']!);
      }
      if (existente == null && !lista.contains(item)) lista.add(item);
      await controller.salvarCardapio(novo);
    });
  }

  String? _validarQuantidadeEscolhas(String valor) {
    final quantidade = int.tryParse(valor);
    if (quantidade == null || quantidade < 1 || quantidade > 5) {
      return 'Informe um número inteiro de 1 a 5.';
    }
    return null;
  }

  Future<void> _excluir(
      BuildContext context, Map<String, dynamic> item, String colecao) async {
    final novo = copiaMapa(controller.cardapio);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir opção?'),
        content: Text(
            '“${item['nome']}” será removido do cardápio. Para apenas esgotar temporariamente, prefira desativar.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Voltar')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Excluir')),
        ],
      ),
    );
    if (ok != true) return;
    final lista = (novo[colecao] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    lista.removeWhere((e) => e['id'] == item['id']);
    novo[colecao] = lista;
    try {
      await controller.salvarCardapio(novo);
    } catch (e) {
      if (context.mounted) await mostrarErro(context, e);
    }
  }
}

class _ModoCardapio extends StatefulWidget {
  final AppController controller;
  const _ModoCardapio({required this.controller});

  @override
  State<_ModoCardapio> createState() => _ModoCardapioState();
}

class _ModoCardapioState extends State<_ModoCardapio> {
  Future<Uint8List>? _imagem;

  Future<void> _selecionarImagem() async {
    final arquivos = await FilePicker.platform.pickFiles(
          type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png'],
      allowMultiple: false,
      withData: true,
    );
    if (arquivos == null || arquivos.files.isEmpty) return;
    final selecionado = arquivos.files.single;
    final bytes = selecionado.bytes;
    if (bytes == null || bytes.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Não foi possível ler essa imagem.')),
        );
      }
      return;
    }
    if (bytes.length > 5 * 1024 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A imagem deve ter no máximo 5 MB.')),
        );
      }
      return;
    }
    final extensao = selecionado.extension?.toLowerCase();
    final mimeType = extensao == 'png' ? 'image/png' : 'image/jpeg';
    try {
      await widget.controller.salvarImagemCardapio(bytes, mimeType);
      if (!mounted) return;
      setState(() => _imagem = widget.controller.api.cardapioImagem());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Imagem do cardápio salva.')),
      );
    } catch (e) {
      if (mounted) await mostrarErro(context, e);
    }
  }

  Future<void> _selecionarModo(String modo) async {
    final atual = widget.controller.cardapio;
    if (modo == 'imagem' && atual['imagemConfigurada'] != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Envie a imagem do cardápio primeiro.')),
      );
      return;
    }
    final novo = copiaMapa(atual)..['modoExibicao'] = modo;
    try {
      await widget.controller.salvarCardapio(novo);
    } catch (e) {
      if (mounted) await mostrarErro(context, e);
    }
  }

  Future<void> _removerImagem() async {
    try {
      await widget.controller.removerImagemCardapio();
      if (mounted) setState(() => _imagem = null);
    } catch (e) {
      if (mounted) await mostrarErro(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cardapio = widget.controller.cardapio;
    final modo = cardapio['modoExibicao'] == 'imagem' ? 'imagem' : 'texto';
    final imagemConfigurada = cardapio['imagemConfigurada'] == true;
    return PainelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Como enviar o cardápio?',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          const Text('Escolha se o bot envia a lista em texto ou uma imagem.'),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                  value: 'texto',
                  label: Text('Cardápio texto'),
                  icon: Icon(Icons.notes_outlined)),
              ButtonSegment(
                  value: 'imagem',
                  label: Text('Cardápio imagem'),
                  icon: Icon(Icons.image_outlined)),
            ],
            selected: {modo},
            onSelectionChanged: widget.controller.salvandoCardapio
                ? null
                : (valores) => _selecionarModo(valores.first),
          ),
          const SizedBox(height: 6),
          const Text('A imagem pode ser JPG ou PNG e ter até 5 MB.'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              onPressed:
                  widget.controller.salvandoCardapio ? null : _selecionarImagem,
              icon: const Icon(Icons.upload_file),
              label: Text(imagemConfigurada
                  ? 'Trocar imagem do cardápio'
                  : 'Enviar imagem do cardápio'),
            ),
            if (imagemConfigurada)
              TextButton.icon(
                onPressed:
                    widget.controller.salvandoCardapio ? null : _removerImagem,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remover imagem'),
              ),
          ]),
          if (imagemConfigurada) ...[
            const SizedBox(height: 12),
            FutureBuilder<Uint8List>(
              future: _imagem ??= widget.controller.api.cardapioImagem(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Text('Não foi possível carregar a prévia.');
                }
                if (!snapshot.hasData) {
                  return const LinearProgressIndicator();
                }
                return ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: Image.memory(
                      snapshot.data!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) =>
                          const Text('Não foi possível exibir a imagem.'),
                    ),
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _Secao extends StatelessWidget {
  final String titulo;
  final String descricao;
  final VoidCallback onAdicionar;
  final List<Widget> children;
  const _Secao(
      {required this.titulo,
      required this.descricao,
      required this.onAdicionar,
      required this.children});

  @override
  Widget build(BuildContext context) {
    return PainelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(titulo,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 3),
                  Text(descricao,
                      style:
                          const TextStyle(color: Colors.black54, fontSize: 12)),
                ])),
            IconButton.filledTonal(
                onPressed: onAdicionar,
                tooltip: 'Adicionar',
                icon: const Icon(Icons.add)),
          ]),
          const SizedBox(height: 12),
          if (children.isEmpty)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Text('Nenhuma opção cadastrada.'))
          else
            ...children,
        ],
      ),
    );
  }
}

class _FluxoBase extends StatelessWidget {
  final String titulo;
  final String descricao;
  final bool ativo;
  final ValueChanged<bool> onAtivar;
  final VoidCallback onAdicionar;
  final List<Widget> children;
  const _FluxoBase({
    required this.titulo,
    required this.descricao,
    required this.ativo,
    required this.onAtivar,
    required this.onAdicionar,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return PainelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: ativo,
            onChanged: onAtivar,
            title: Text(titulo,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            subtitle: Text(descricao),
          ),
          Row(
            children: [
              const Expanded(
                child: Text('Opções cadastradas',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              IconButton.filledTonal(
                onPressed: onAdicionar,
                tooltip: 'Adicionar opção',
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (children.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Adicione pelo menos uma opção antes de ativar.'),
            )
          else
            ...children,
        ],
      ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final String? subtitulo;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEditar;
  final VoidCallback onExcluir;
  const _ItemCard(
      {required this.item,
      this.subtitulo,
      required this.onToggle,
      required this.onEditar,
      required this.onExcluir});

  @override
  Widget build(BuildContext context) {
    final ativo = item['ativo'] == true;
    return LayoutBuilder(builder: (context, constraints) {
      final compacto = constraints.maxWidth < 360;
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(
          color: ativo ? Colors.white : Colors.black.withValues(alpha: .035),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.black.withValues(alpha: .07)),
        ),
        child: Row(children: [
          Switch(value: ativo, onChanged: onToggle),
          const SizedBox(width: 8),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(item['nome']?.toString() ?? '',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: ativo ? Colors.black : Colors.black45)),
                if (subtitulo != null)
                  Text(subtitulo!,
                      style: const TextStyle(color: Colors.black54)),
                if (!ativo)
                  const Text('ESGOTADO / INATIVO',
                      style: TextStyle(
                          color: Colors.red,
                          fontSize: 11,
                          fontWeight: FontWeight.w800)),
              ])),
          if (!compacto)
            IconButton(
                onPressed: onEditar,
                tooltip: 'Editar',
                icon: const Icon(Icons.edit_outlined)),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'editar') onEditar();
              if (v == 'excluir') onExcluir();
            },
            itemBuilder: (_) => [
              if (compacto)
                const PopupMenuItem(value: 'editar', child: Text('Editar')),
              const PopupMenuItem(value: 'excluir', child: Text('Excluir')),
            ],
          ),
        ]),
      );
    });
  }
}

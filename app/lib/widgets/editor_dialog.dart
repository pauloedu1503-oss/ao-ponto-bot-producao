import 'package:flutter/material.dart';
import '../servicos/api_service.dart';

class CampoEdicao {
  final String chave, titulo, valor;
  final int linhas;
  final String? Function(String)? validar;
  const CampoEdicao(this.chave, this.titulo, this.valor,
      {this.linhas = 1, this.validar});
}

Future<void> editarCampos(BuildContext context,
        {required String titulo,
        required List<CampoEdicao> campos,
        required Future<void> Function(Map<String, String>) salvar,
        String textoSalvar = 'Salvar',
        String mensagemSucesso = 'Alterações salvas.',
        String textoCancelar = 'Cancelar'}) =>
    showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _EditorDialog(
            titulo: titulo,
            campos: campos,
            salvar: salvar,
            textoSalvar: textoSalvar,
            mensagemSucesso: mensagemSucesso,
            textoCancelar: textoCancelar));

class _EditorDialog extends StatefulWidget {
  final String titulo;
  final List<CampoEdicao> campos;
  final Future<void> Function(Map<String, String>) salvar;
  final String textoSalvar, mensagemSucesso, textoCancelar;
  const _EditorDialog(
      {required this.titulo,
      required this.campos,
      required this.salvar,
      required this.textoSalvar,
      required this.mensagemSucesso,
      required this.textoCancelar});
  @override
  State<_EditorDialog> createState() => _EditorDialogState();
}

class _EditorDialogState extends State<_EditorDialog> {
  final form = GlobalKey<FormState>();
  late final controllers = {
    for (final c in widget.campos) c.chave: TextEditingController(text: c.valor)
  };
  bool salvando = false;
  bool permitirFechar = false;
  String? erro;
  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> cancelar() async {
    if (salvando) return;
    final alterado =
        widget.campos.any((c) => controllers[c.chave]!.text != c.valor);
    if (alterado) {
      final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
                  title: const Text('Descartar alterações?'),
                  content:
                      const Text('Os dados digitados ainda não foram salvos.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('Continuar editando')),
                    FilledButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('Descartar'))
                  ]));
      if (ok != true || !mounted) return;
    }
    setState(() => permitirFechar = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> salvar() async {
    if (salvando || !form.currentState!.validate()) return;
    setState(() {
      salvando = true;
      erro = null;
    });
    try {
      await widget.salvar(
          {for (final e in controllers.entries) e.key: e.value.text.trim()});
      if (!mounted) return;
      setState(() => permitirFechar = true);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(widget.mensagemSucesso)));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    } catch (e) {
      if (mounted) {
        setState(() => erro = e is ApiException
            ? e.mensagem
            : 'Não foi possível salvar. Seus dados foram mantidos. Tente novamente.');
      }
    } finally {
      if (mounted) setState(() => salvando = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: permitirFechar,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) cancelar();
      },
      child: AlertDialog(
          title: Text(widget.titulo),
          content: SizedBox(
              width: 430,
              child: SingleChildScrollView(
                  child: Form(
                      key: form,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        for (final c in widget.campos)
                          Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: TextFormField(
                                  controller: controllers[c.chave],
                                  enabled: !salvando,
                                  minLines: c.linhas,
                                  maxLines: c.linhas,
                                  validator: (v) =>
                                      c.validar?.call((v ?? '').trim()),
                                  decoration:
                                      InputDecoration(labelText: c.titulo))),
                        if (erro != null)
                          Text(erro!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error)),
                      ])))),
          actions: [
            TextButton(
                onPressed: salvando ? null : cancelar,
                child: Text(widget.textoCancelar)),
            FilledButton(
                onPressed: salvando ? null : salvar,
                child: Text(salvando ? 'Salvando…' : widget.textoSalvar))
          ]));
}

String? validarDinheiro(String v, {bool permitirZero = true}) {
  final n = double.tryParse(v.replaceAll(',', '.'));
  if (n == null ||
      !n.isFinite ||
      n < 0 ||
      (!permitirZero && n == 0) ||
      n > 10000 ||
      !RegExp(r'^\d+(?:[.,]\d{1,2})?$').hasMatch(v)) {
    return 'Informe um valor válido de ${permitirZero ? '0' : '0,01'} a 10.000, com até duas casas decimais.';
  }
  return null;
}

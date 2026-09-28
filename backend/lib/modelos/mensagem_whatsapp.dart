class MensagemWhatsApp {
  final String id;
  final String telefone;
  final String nome;
  final String texto;
  final String? respostaId;
  final DateTime? enviadaEm;

  const MensagemWhatsApp({
    required this.id,
    required this.telefone,
    required this.nome,
    required this.texto,
    this.respostaId,
    this.enviadaEm,
  });

  String get entrada => (respostaId?.trim().isNotEmpty ?? false)
      ? respostaId!.trim()
      : texto.trim();
}

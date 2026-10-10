class MensagemWhatsApp {
  final String id;
  final String telefone;
  final String nome;
  final String texto;
  final String? tipo;
  final String? mediaId;
  final String? mimeType;
  final double? latitude;
  final double? longitude;
  final String? respostaId;
  final DateTime? enviadaEm;

  const MensagemWhatsApp({
    required this.id,
    required this.telefone,
    required this.nome,
    required this.texto,
    this.tipo,
    this.mediaId,
    this.mimeType,
    this.latitude,
    this.longitude,
    this.respostaId,
    this.enviadaEm,
  });

  String get entrada => (respostaId?.trim().isNotEmpty ?? false)
      ? respostaId!.trim()
      : texto.trim();

  bool get ehMidia =>
      tipo != null &&
      tipo != 'text' &&
      tipo != 'interactive' &&
      tipo != 'button' &&
      !temLocalizacao;

  bool get temLocalizacao => latitude != null && longitude != null;
}

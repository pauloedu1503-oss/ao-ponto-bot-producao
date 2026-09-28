import 'package:flutter/material.dart';

class TituloPagina extends StatelessWidget {
  final String titulo;
  final String? subtitulo;
  final Widget? acao;
  const TituloPagina(this.titulo, {super.key, this.subtitulo, this.acao});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(titulo,
                  style: Theme.of(context)
                      .textTheme
                      .headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w800)),
              if (subtitulo != null) ...[
                const SizedBox(height: 4),
                Text(subtitulo!,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: Colors.black54)),
              ],
            ],
          ),
        ),
        if (acao != null) acao!,
      ],
    );
  }
}

class PainelCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const PainelCard(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(18)});

  @override
  Widget build(BuildContext context) =>
      Card(child: Padding(padding: padding, child: child));
}

class MetricaCard extends StatelessWidget {
  final IconData icon;
  final String titulo;
  final String valor;
  const MetricaCard(
      {super.key,
      required this.icon,
      required this.titulo,
      required this.valor});

  @override
  Widget build(BuildContext context) {
    return PainelCard(
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color:
                  Theme.of(context).colorScheme.secondary.withValues(alpha: .7),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: Colors.black87),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(titulo, style: const TextStyle(color: Colors.black54)),
                const SizedBox(height: 2),
                Text(valor,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 22)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class EstadoPill extends StatelessWidget {
  final String estado;
  const EstadoPill(this.estado, {super.key});

  @override
  Widget build(BuildContext context) {
    final config = switch (estado) {
      'atendendo' => (Colors.green, 'ATENDENDO'),
      'pausado' => (Colors.orange, 'PAUSADO'),
      'esgotado' => (Colors.red, 'ESGOTADO'),
      _ => (Colors.grey, 'FECHADO'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: config.$1.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 9,
              height: 9,
              decoration:
                  BoxDecoration(color: config.$1, shape: BoxShape.circle)),
          const SizedBox(width: 7),
          Text(config.$2,
              style: TextStyle(
                  fontWeight: FontWeight.w800, fontSize: 12, color: config.$1)),
        ],
      ),
    );
  }
}

String dinheiro(dynamic value) {
  final n = value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
  return 'R\$ ${n.toStringAsFixed(2).replaceAll('.', ',')}';
}

Future<void> mostrarErro(BuildContext context, Object e) async {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(e.toString()), behavior: SnackBarBehavior.floating),
  );
}

import 'package:flutter/material.dart';

class TituloPagina extends StatelessWidget {
  final String titulo;
  final String? subtitulo;
  final Widget? acao;
  const TituloPagina(this.titulo, {super.key, this.subtitulo, this.acao});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final compacto = constraints.maxWidth < 480 && acao != null;
      final textos = Column(
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
      );
      if (compacto) {
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          textos,
          const SizedBox(height: 12),
          acao!,
        ]);
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: textos),
        if (acao != null) ...[const SizedBox(width: 12), acao!],
      ]);
    });
  }
}

EdgeInsets margemPagina(BuildContext context) {
  final largura = MediaQuery.sizeOf(context).width;
  final horizontal = largura < 400
      ? 14.0
      : largura < 700
          ? 18.0
          : 24.0;
  return EdgeInsets.fromLTRB(horizontal, 18, horizontal, 40);
}

class PainelCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const PainelCard(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(18)});

  @override
  Widget build(BuildContext context) {
    final compacto = MediaQuery.sizeOf(context).width < 400;
    final ajuste = padding == const EdgeInsets.all(18) && compacto
        ? const EdgeInsets.all(14)
        : padding;
    return Card(child: Padding(padding: ajuste, child: child));
  }
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

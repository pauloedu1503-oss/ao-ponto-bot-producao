import 'env.dart';

DateTime agoraLocal() {
  final minutos = Env.getInt('TIMEZONE_OFFSET_MINUTES', padrao: -180);
  return DateTime.now().toUtc().add(Duration(minutes: minutos));
}

String agoraIso() => agoraLocal().toIso8601String();

String hojeChave() {
  final d = agoraLocal();
  String dois(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${dois(d.month)}-${dois(d.day)}';
}

String moeda(double valor) =>
    'R\$ ${valor.toStringAsFixed(2).replaceAll('.', ',')}';

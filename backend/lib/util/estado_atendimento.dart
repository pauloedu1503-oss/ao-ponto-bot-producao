import 'data_hora.dart';

String estadoAtendimentoEfetivo(Map<String, dynamic> config) {
  final manual = (config['estadoBot'] ?? 'fechado').toString();
  if (manual == 'pausado' || manual == 'esgotado' || manual == 'fechado') {
    return manual;
  }
  if (manual != 'atendendo') return 'fechado';
  if (config['usarHorarioAutomatico'] != true) return 'atendendo';

  final agora = agoraLocal();
  final horarios = Map<String, dynamic>.from(config['horarios'] as Map? ?? {});
  final dia =
      Map<String, dynamic>.from(horarios['${agora.weekday}'] as Map? ?? {});
  if (dia['ativo'] != true) return 'fechado';
  final inicio = _minutosDoDia(dia['inicio']?.toString() ?? '00:00');
  final fim = _minutosDoDia(dia['fim']?.toString() ?? '23:59');
  final atual = agora.hour * 60 + agora.minute;
  if (inicio == null || fim == null) return 'fechado';
  return atual >= inicio && atual < fim ? 'atendendo' : 'fechado';
}

int? _minutosDoDia(String horario) {
  final p = horario.split(':');
  if (p.length != 2) return null;
  final h = int.tryParse(p[0]);
  final m = int.tryParse(p[1]);
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
    return null;
  }
  return h * 60 + m;
}

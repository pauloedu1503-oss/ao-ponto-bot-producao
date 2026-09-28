import 'dart:io';
import 'package:sqlite3/sqlite3.dart';

/// Restaura para um caminho novo, sem sobrescrever o banco operacional.
void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
        'Uso: dart run bin/restaurar.dart backup.db data/restaurado.db');
    exitCode = 64;
    return;
  }
  final origem = File(args[0]);
  final destino = File(args[1]);
  try {
    if (!origem.existsSync()) throw StateError('Backup não encontrado.');
    if (destino.existsSync() ||
        File('${destino.path}-wal').existsSync() ||
        File('${destino.path}-shm').existsSync()) {
      throw StateError(
          'Escolha um destino novo. Nenhum banco será sobrescrito.');
    }
    final db = sqlite3.open(origem.path, mode: OpenMode.readOnly);
    try {
      if (db.select('PRAGMA integrity_check').single.values.single != 'ok') {
        throw StateError('O backup não passou na verificação de integridade.');
      }
      for (final tabela in [
        'configuracao',
        'cardapio_itens',
        'pedidos',
        'sessoes',
        'mensagens_processadas'
      ]) {
        if (db.select(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
            [tabela]).isEmpty) {
          throw StateError('Backup incompatível: falta $tabela.');
        }
      }
      destino.parent.createSync(recursive: true);
      db.execute('VACUUM INTO ?', [destino.path]);
    } finally {
      db.dispose();
    }
    stdout.writeln(
        'Restaurado em ${destino.path}. Com o backend parado, configure DATABASE_PATH para esse arquivo.');
  } catch (e) {
    stderr.writeln('Restauração não concluída: $e');
    exitCode = 1;
  }
}

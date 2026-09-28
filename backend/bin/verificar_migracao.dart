import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../lib/banco/banco.dart';

/// Copia o banco de origem em leitura e exercita a migração somente na cópia.
void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
        'Uso: dart run bin/verificar_migracao.dart origem.db copia_nova.db');
    exitCode = 64;
    return;
  }
  final origem = File(args[0]);
  final copia = File(args[1]);
  if (!origem.existsSync() || copia.existsSync()) {
    stderr.writeln('A origem deve existir e o destino deve ser novo.');
    exitCode = 64;
    return;
  }
  try {
    copia.parent.createSync(recursive: true);
    final original = sqlite3.open(origem.path, mode: OpenMode.readOnly);
    final antes = <String, int>{};
    try {
      if (original.select('PRAGMA integrity_check').single.values.single !=
          'ok') {
        throw StateError('Banco de origem sem integridade.');
      }
      for (final tabela in [
        'configuracao',
        'cardapio_itens',
        'pedidos',
        'sessoes',
        'mensagens_processadas',
        'logs'
      ]) {
        antes[tabela] = original
            .select('SELECT COUNT(*) n FROM $tabela')
            .single['n'] as int;
      }
      original.execute('VACUUM INTO ?', [copia.path]);
    } finally {
      original.dispose();
    }
    final migrado = Banco(caminhoBanco: copia.path);
    try {
      if (migrado.db.select('PRAGMA integrity_check').single.values.single !=
          'ok') {
        throw StateError('Cópia migrada sem integridade.');
      }
      for (final entrada in antes.entries) {
        final depois = migrado.db
            .select('SELECT COUNT(*) n FROM ${entrada.key}')
            .single['n'] as int;
        if (entrada.key == 'logs' && depois >= entrada.value) continue;
        if (entrada.value != depois) {
          throw StateError('${entrada.key}: contagem mudou na migração.');
        }
      }
      migrado.obterConfiguracao();
      migrado.obterCardapio();
      migrado.listarPedidos();
      stdout.writeln(
          'Migração compatível na cópia. Contagens preservadas: $antes');
    } finally {
      migrado.fechar();
    }
  } catch (e) {
    stderr.writeln('Verificação falhou: $e');
    exitCode = 1;
  }
}

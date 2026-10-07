import 'dart:convert';

import 'package:ao_ponto_backend/banco/banco.dart';
import 'package:test/test.dart';

void main() {
  late Banco banco;

  setUp(() => banco = Banco(caminhoBanco: ':memory:'));
  tearDown(() => banco.fechar());

  test('salva a imagem, permite selecionar o modo e volta ao texto ao remover',
      () {
    final inicial = banco.obterCardapio();
    expect(inicial['modoExibicao'], 'texto');
    expect(inicial['imagemConfigurada'], isFalse);

    final semImagem = Map<String, dynamic>.from(inicial)
      ..['modoExibicao'] = 'imagem';
    expect(() => banco.atualizarCardapio(semImagem), throwsArgumentError);

    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p8sAAAAASUVORK5CYII=',
    );
    banco.salvarImagemCardapio(bytes, 'image/png');
    final comImagem = banco.obterCardapio()..['modoExibicao'] = 'imagem';
    final salvo = banco.atualizarCardapio(comImagem);

    expect(salvo['modoExibicao'], 'imagem');
    expect(salvo['imagemConfigurada'], isTrue);
    expect(banco.obterImagemCardapio()!['dados'], orderedEquals(bytes));

    banco.removerImagemCardapio();
    expect(banco.obterCardapio()['modoExibicao'], 'texto');
    expect(banco.obterCardapio()['imagemConfigurada'], isFalse);
    expect(banco.obterImagemCardapio(), isNull);
  });
}

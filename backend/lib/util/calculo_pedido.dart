/// Dinheiro calculado em centavos; o contrato HTTP/SQLite continua em reais.
class CalculoPedido {
  final List<Map<String, dynamic>> itens;
  late final int _subtotal;
  late final int _taxa;
  late final int _taxaMaquininha;

  CalculoPedido(this.itens, double taxa, {double taxaMaquininha = 0}) {
    if (itens.isEmpty ||
        !taxa.isFinite ||
        taxa < 0 ||
        taxa > 10000 ||
        (taxa * 100 - (taxa * 100).round()).abs() > 0.000001 ||
        !taxaMaquininha.isFinite ||
        taxaMaquininha < 0 ||
        taxaMaquininha > 10000 ||
        (taxaMaquininha * 100 - (taxaMaquininha * 100).round()).abs() >
            0.000001) {
      throw ArgumentError('Itens ou taxa inválidos.');
    }
    _taxa = (taxa * 100).round();
    _taxaMaquininha = (taxaMaquininha * 100).round();
    var soma = 0;
    for (final item in itens) {
      final preco = item['precoUnitario'];
      final quantidade = item['quantidade'];
      if (preco is! num ||
          !preco.isFinite ||
          preco <= 0 ||
          preco > 10000 ||
          (preco * 100 - (preco * 100).round()).abs() > 0.000001 ||
          quantidade is! int ||
          quantidade < 1 ||
          quantidade > 50) {
        throw ArgumentError('Preço ou quantidade inválidos.');
      }
      soma += (preco * 100).round() * quantidade;
    }
    // Atribuição única mantém o resultado imutável.
    _subtotal = soma;
  }

  double get subtotal => _subtotal / 100;
  double get taxaEntrega => _taxa / 100;
  double get taxaMaquininha => _taxaMaquininha / 100;
  double get total => (_subtotal + _taxa + _taxaMaquininha) / 100;
}

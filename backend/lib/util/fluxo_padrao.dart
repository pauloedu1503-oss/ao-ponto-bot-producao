Map<String, dynamic> fluxoPadrao() => {
      'inicio': {
        'mensagem': 'Como podemos ajudar?',
        'botaoPedido': 'Fazer pedido',
        'botaoCardapio': 'Ver cardápio',
        'botaoHumano': 'Falar atendente',
      },
      'cardapio': {
        'titulo': '🍱 *CARDÁPIO DO DIA*',
        'rodape': 'O mesmo padrão em todos os tamanhos; muda a quantidade.',
      },
      'tamanho': {
        'mensagem': 'Escolha o tamanho da marmita:',
        'tituloLista': 'Ver tamanhos',
      },
      'mistura': {
        'mensagem': 'Escolha a mistura:',
        'tituloLista': 'Ver misturas',
      },
      'acompanhamento': {
        'mensagem': 'Escolha 1 acompanhamento:',
        'tituloLista': 'Ver opções',
      },
      'quantidade': {
        'mensagem': 'Quantas marmitas iguais a essa?',
        'ajuda': 'Digite apenas a quantidade de 1 a {max}.',
        'maximo': 20,
      },
      'adicionarOutro': {
        'mensagem': '✅ Item adicionado. Quer adicionar outra marmita?',
        'botaoSim': 'Adicionar outra',
        'botaoNao': 'Finalizar pedido',
      },
      'recebimento': {
        'mensagem': 'Como você quer receber seu pedido?',
        'botaoEntrega': 'Entrega',
        'botaoRetirada': 'Retirada',
        'pularSeUnica': true,
      },
      'endereco': {
        'mensagem':
            '📍 Envie seu endereço para entrega:\nRua, número, bairro e complemento/referência.',
      },
      'cidadeEntrega': {
        'mensagem': '🏙️ Em qual cidade será a entrega?',
      },
      'pagamento': {
        'mensagem': 'Como deseja pagar?',
        'botaoPix': 'PIX',
        'botaoDinheiro': 'Dinheiro',
        'botaoCartao': 'Cartão',
        'pularSeUnica': true,
      },
      'troco': {
        'mensagem':
            'Precisa de troco?\nDigite *não* ou informe para quanto, por exemplo: *50*.',
        'textoSemTroco': 'não',
      },
      'observacao': {
        'mensagem': 'Deseja alguma observação?\nEx.: sem feijão.',
        'mensagemAlterar': 'Altere sua observação.',
        'textoNenhuma': 'não',
      },
      'bebida': {
        'mensagem': 'Deseja adicionar uma bebida?',
        'tituloLista': 'Ver bebidas',
        'botaoSemBebida': 'Sem bebida',
      },
      'quantidadeBebida': {
        'mensagem': 'Quantas unidades desta bebida?',
        'ajuda': 'Digite apenas a quantidade de 1 a {max}.',
        'maximo': 20,
      },
      'adicionarOutraBebida': {
        'mensagem': '🥤 Bebida adicionada. Deseja adicionar outra?',
        'botaoSim': 'Adicionar outra',
        'botaoNao': 'Finalizar bebidas',
      },
      'resumo': {
        'titulo': '🧾 *CONFIRA SEU PEDIDO*',
        'botaoConfirmar': 'Confirmar',
        'botaoRefazer': 'Refazer pedido',
        'botaoCancelar': 'Cancelar',
      },
      'sistema': {
        'sessaoExpirada':
            '⏱️ Seu pedido anterior expirou por falta de atividade. Vamos começar novamente.',
        'pedidoCancelado':
            'Pedido cancelado. 🙂\nQuando quiser começar novamente, escolha uma opção:',
        'humanoAtivado':
            'Certo! 👤 O atendimento automático foi pausado para esta conversa. Um atendente continuará por aqui.',
        'retomado': '🤖 Atendimento automático retomado.',
        'refazer': 'Certo. Vamos refazer o pedido desde o começo. 👍',
      },
    };

Map<String, dynamic> mesclarFluxoComPadrao(dynamic atual) {
  final base = fluxoPadrao();
  if (atual is! Map) return base;
  for (final entry in base.entries) {
    final recebido = atual[entry.key];
    if (recebido is Map && entry.value is Map) {
      final destino = Map<String, dynamic>.from(entry.value as Map);
      destino.addAll(Map<String, dynamic>.from(recebido));
      base[entry.key] = destino;
    }
  }
  return base;
}

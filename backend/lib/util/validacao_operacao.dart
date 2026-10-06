class ValidacaoOperacao {
  ValidacaoOperacao._();

  static const _estados = {'atendendo', 'pausado', 'esgotado', 'fechado'};

  static void validarConfiguracaoEstrutural(Map<String, dynamic> dados) {
    final nome = dados['nomeEstabelecimento']?.toString().trim() ?? '';
    if (nome.isEmpty) {
      throw ArgumentError('Informe o nome do estabelecimento.');
    }

    final estado = dados['estadoBot']?.toString() ?? 'fechado';
    if (!_estados.contains(estado)) {
      throw ArgumentError('Estado do bot inválido.');
    }
    if (dados['botAtivo'] is! bool) {
      throw ArgumentError('O controle principal do bot está inválido.');
    }
    if (!{'bot', 'ia'}.contains(dados['modoAtendimento'] ?? 'bot')) {
      throw ArgumentError('Modo de atendimento inválido.');
    }
    if (dados['entregaAtiva'] != true && dados['retiradaAtiva'] != true) {
      throw ArgumentError(
          'Configurações > Entrega e retirada: ative pelo menos uma opção.');
    }
    final pagamentosValidos = dados['pagamentos'];
    if (pagamentosValidos is! Map ||
        !['pix', 'dinheiro', 'credito', 'debito', 'cartao']
            .any((p) => pagamentosValidos[p] == true)) {
      throw ArgumentError(
          'Configurações > Pagamento: ative pelo menos uma forma.');
    }

    final expira = (dados['sessaoExpiraMinutos'] as num?)?.toInt() ?? 60;
    if (expira < 5 || expira > 240) {
      throw ArgumentError(
          'A expiração da conversa deve ficar entre 5 e 240 minutos.');
    }

    final taxaLegada = (dados['taxaEntrega'] as num?)?.toDouble() ?? 0;
    if (!taxaLegada.isFinite || taxaLegada < 0 || taxaLegada > 10000) {
      throw ArgumentError(
          'A taxa de entrega legada precisa ser um valor válido.');
    }

    final cidades = dados['cidadesEntrega'] as List? ?? const [];
    if (cidades.length > 20) {
      throw ArgumentError('Há cidades de entrega demais. O limite é 20.');
    }
    final cidadesVistas = <String>{};
    final idsCidades = <String>{};
    for (final raw in cidades) {
      if (raw is! Map)
        throw ArgumentError('Existe uma cidade de entrega inválida.');
      final cidade = Map<String, dynamic>.from(raw);
      final id = cidade['id']?.toString().trim() ?? '';
      final nomeCidade = cidade['nome']?.toString().trim() ?? '';
      final uf = cidade['uf']?.toString().trim().toUpperCase() ?? '';
      final taxa = (cidade['taxa'] as num?)?.toDouble();
      if (id.isEmpty ||
          !idsCidades.add(id) ||
          nomeCidade.isEmpty ||
          nomeCidade.length > 60 ||
          !RegExp(r'^[A-Z]{2}$').hasMatch(uf)) {
        throw ArgumentError('Existe uma cidade de entrega incompleta.');
      }
      if (taxa == null ||
          !taxa.isFinite ||
          taxa < 0 ||
          taxa > 10000 ||
          (taxa * 100 - (taxa * 100).round()).abs() > 0.000001) {
        throw ArgumentError(
            'A taxa de $nomeCidade precisa ser um valor válido.');
      }
      final chave = '${_normalizar(nomeCidade)}|$uf';
      if (!cidadesVistas.add(chave)) {
        throw ArgumentError(
            'Há cidades de entrega repetidas: $nomeCidade/$uf.');
      }
    }

    final horarios = Map<String, dynamic>.from(dados['horarios'] as Map? ?? {});
    for (var dia = 1; dia <= 7; dia++) {
      final item = Map<String, dynamic>.from(horarios['$dia'] as Map? ?? {});
      if (item['ativo'] != true) continue;
      final inicio = _minutos(item['inicio']?.toString() ?? '');
      final fim = _minutos(item['fim']?.toString() ?? '');
      if (inicio == null || fim == null || inicio >= fim) {
        throw ArgumentError(
            'Horário inválido no dia $dia. O horário de abertura deve ser anterior ao fechamento.');
      }
    }

    final mensagens = dados['mensagens'];
    for (final campo in [
      'boasVindas',
      'fechado',
      'pausado',
      'esgotado',
      'pedidoConfirmado'
    ]) {
      final texto = mensagens is Map ? mensagens[campo] : null;
      if (texto is! String || texto.trim().isEmpty || texto.length > 1000) {
        throw ArgumentError(
            'Bot > Mensagens: revise $campo (1 a 1000 caracteres).');
      }
    }
    for (final campo in [
      'entregaAtiva',
      'retiradaAtiva',
      'permitirObservacoes',
      'saladaIncluida',
      'usarHorarioAutomatico'
    ]) {
      if (dados[campo] is! bool)
        throw ArgumentError('Configuração inválida: $campo.');
    }
    _validarFluxo(dados['fluxo']);
  }

  static void validarCardapioEstrutural(Map<String, dynamic> cardapio) {
    final ids = <String>{};
    for (final entrada in const [
      ('tamanhos', true),
      ('misturas', false),
      ('acompanhamentos', false),
      ('bebidas', true),
      ('arrozes', false),
      ('feijoes', false),
    ]) {
      final chave = entrada.$1;
      final exigePreco = entrada.$2;
      final lista = cardapio[chave] as List? ?? const [];
      if (lista.length > 50) {
        throw ArgumentError('Há opções demais em $chave. O limite é 50.');
      }

      final nomes = <String>{};
      for (final raw in lista) {
        if (raw is! Map) throw ArgumentError('Item inválido em $chave.');
        final item = Map<String, dynamic>.from(raw);
        final nome = item['nome']?.toString().trim() ?? '';
        if (nome.isEmpty)
          throw ArgumentError('Existe uma opção sem nome em $chave.');
        if (nome.length > 60)
          throw ArgumentError(
              'O nome “$nome” é muito longo. Use até 60 caracteres.');

        final nomeNormalizado = _normalizar(nome);
        if (!nomes.add(nomeNormalizado)) {
          throw ArgumentError('Há opções repetidas em $chave: “$nome”.');
        }

        final id = item['id']?.toString().trim() ?? '';
        if (id.isNotEmpty && !ids.add(id)) {
          throw ArgumentError(
              'Há itens com identificador duplicado no cardápio.');
        }

        if (exigePreco) {
          final preco = (item['preco'] as num?)?.toDouble();
          if (preco == null ||
              !preco.isFinite ||
              preco <= 0 ||
              preco > 10000 ||
              (preco * 100 - (preco * 100).round()).abs() > 0.000001) {
            throw ArgumentError(
                'O tamanho “$nome” precisa ter preço maior que zero.');
          }
        }
      }
    }
    for (final entrada in const [
      ('fluxoArrozAtivo', 'arrozes', 'arroz'),
      ('fluxoFeijaoAtivo', 'feijoes', 'feijão'),
    ]) {
      if (cardapio.containsKey(entrada.$1) && cardapio[entrada.$1] is! bool) {
        throw ArgumentError('O controle do fluxo de ${entrada.$3} é inválido.');
      }
      if (cardapio[entrada.$1] == true) {
        final lista = cardapio[entrada.$2] as List? ?? const [];
        if (!lista.any((e) => e is Map && e['ativo'] == true)) {
          throw ArgumentError(
              'Ative pelo menos uma opção de ${entrada.$3} antes de ligar o fluxo.');
        }
      }
    }
  }

  static List<String> problemasProntidao(
    Map<String, dynamic> config,
    Map<String, dynamic> cardapio,
  ) {
    final problemas = <String>[];
    try {
      validarConfiguracaoEstrutural(config);
    } catch (e) {
      problemas.add('Configurações/Fluxo: ' +
          (e is ArgumentError ? e.message.toString() : 'formato inválido'));
    }
    try {
      validarCardapioEstrutural(cardapio);
    } catch (_) {
      problemas.add('Cardápio: revise nomes, preços e opções');
    }

    bool existeAtivo(String chave) {
      final lista = cardapio[chave] as List? ?? const [];
      return lista.any((e) => e is Map && e['ativo'] == true);
    }

    if (!existeAtivo('tamanhos'))
      problemas.add('Cardápio > Tamanhos: ative pelo menos 1 tamanho');
    if (!existeAtivo('misturas'))
      problemas.add('Cardápio > Misturas: ative pelo menos 1 mistura');
    if (!existeAtivo('acompanhamentos'))
      problemas
          .add('Cardápio > Acompanhamentos: ative pelo menos 1 acompanhamento');

    final entrega = config['entregaAtiva'] == true;
    final retirada = config['retiradaAtiva'] == true;
    if (!entrega && !retirada) {
      problemas.add('Configurações > Entrega e retirada: ative uma opção');
    }

    if (entrega) {
      final cidades = config['cidadesEntrega'] as List? ?? const [];
      final algumaCidade = cidades.any((e) =>
          e is Map &&
          e['ativa'] == true &&
          ((e['taxa'] as num?)?.toDouble() ?? -1) >= 0);
      if (!algumaCidade) {
        problemas.add(
            'Configurações > Entrega e retirada: ative uma cidade com taxa válida');
      }
    }

    if (retirada) {
      final endereco = config['enderecoRetirada']?.toString().trim() ?? '';
      if (endereco.isEmpty)
        problemas.add(
            'Configurações > Estabelecimento: informe o endereço para retirada');
    }

    final pagamentos =
        Map<String, dynamic>.from(config['pagamentos'] as Map? ?? {});
    final pix = pagamentos['pix'] == true;
    final dinheiro = pagamentos['dinheiro'] == true;
    final credito = pagamentos['credito'] == true;
    final debito = pagamentos['debito'] == true;
    final cartaoLegado = pagamentos['cartao'] == true;
    if (!pix && !dinheiro && !credito && !debito && !cartaoLegado) {
      problemas.add('Configurações > Pagamento: ative uma forma');
    }
    if (pix && (config['chavePix']?.toString().trim().isEmpty ?? true)) {
      problemas.add(
          'Configurações > Pagamento: informe a chave PIX ou desative o PIX');
    }

    if (config['usarHorarioAutomatico'] == true) {
      final horarios =
          Map<String, dynamic>.from(config['horarios'] as Map? ?? {});
      final algumDia =
          horarios.values.any((e) => e is Map && e['ativo'] == true);
      if (!algumDia)
        problemas.add('Bot > Horário automático: ative pelo menos um dia');
    }

    return problemas;
  }

  static void validarProntidao(
    Map<String, dynamic> config,
    Map<String, dynamic> cardapio,
  ) {
    final problemas = problemasProntidao(config, cardapio);
    if (problemas.isEmpty) return;
    throw ArgumentError(
        'Antes de colocar o bot em Atendendo: ${problemas.join('; ')}.');
  }

  static void _validarFluxo(dynamic bruto) {
    if (bruto is! Map)
      throw ArgumentError('Configuração do fluxo do bot inválida.');
    final fluxo = Map<String, dynamic>.from(bruto);

    Map<String, dynamic> etapa(String chave) {
      final valor = fluxo[chave];
      if (valor is! Map)
        throw ArgumentError('A etapa “$chave” do fluxo está inválida.');
      return Map<String, dynamic>.from(valor);
    }

    void texto(Map<String, dynamic> m, String chave, String rotulo,
        {int max = 1000}) {
      final v = m[chave]?.toString().trim() ?? '';
      if (v.isEmpty) throw ArgumentError('$rotulo não pode ficar vazio.');
      if (v.length > max)
        throw ArgumentError('$rotulo deve ter no máximo $max caracteres.');
    }

    void validarComandoReservado(String valor, String rotulo,
        {Set<String> permitidos = const {}}) {
      final normal = _normalizar(valor);
      final reservados = {
        '0',
        'cancelar',
        'voltar',
        'volta',
        'atendente',
        'humano',
        'cmd_voltar',
        'inicio_humano',
        'conf_cancelar'
      };
      if (RegExp(r'^\d+$').hasMatch(normal) ||
          (reservados.contains(normal) && !permitidos.contains(normal))) {
        throw ArgumentError(
            '$rotulo não pode ser apenas um número nem usar um comando reservado.');
      }
    }

    void botoesUnicos(
      Map<String, dynamic> m,
      List<String> chaves,
      String etapaNome, {
      Map<String, Set<String>> permitidos = const {},
    }) {
      final vistos = <String>{};
      for (final chave in chaves) {
        texto(m, chave, 'Botão de $etapaNome', max: 20);
        final normal = _normalizar(m[chave].toString());
        validarComandoReservado(
          m[chave].toString(),
          'O botão “${m[chave]}”',
          permitidos: permitidos[chave] ?? const {},
        );
        const aliases = {
          'botaoPedido': {'pedido', 'fazer pedido', 'inicio_pedido'},
          'botaoCardapio': {'cardapio', 'ver cardapio', 'inicio_cardapio'},
          'botaoHumano': {
            'atendente',
            'humano',
            'falar atendente',
            'inicio_humano'
          },
          'botaoSim': {'sim', 'adicionar outra', 'outro_sim'},
          'botaoNao': {'nao', 'finalizar pedido', 'outro_nao'},
          'botaoConfirmar': {'confirmar', 'conf_confirmar'},
          'botaoRefazer': {
            'refazer',
            'alterar',
            'conf_refazer',
            'conf_alterar'
          },
          'botaoCancelar': {'cancelar', 'conf_cancelar'},
          'botaoPix': {'pag_pix'},
          'botaoDinheiro': {'pag_dinheiro'},
          'botaoCartao': {'pag_cartao'},
          'botaoEntrega': {'rec_entrega'},
          'botaoRetirada': {'rec_retirada'},
        };
        for (final outra in chaves.where((c) => c != chave)) {
          if (aliases[outra]?.contains(normal) ?? false) {
            throw ArgumentError(
                'O botão conflita com outra ação de $etapaNome.');
          }
        }
        if (!vistos.add(normal)) {
          throw ArgumentError(
              'Os botões da etapa $etapaNome precisam ter nomes diferentes.');
        }
      }
    }

    final inicio = etapa('inicio');
    texto(inicio, 'mensagem', 'Mensagem inicial');
    botoesUnicos(
      inicio,
      ['botaoPedido', 'botaoCardapio', 'botaoHumano'],
      'Início',
      permitidos: {
        'botaoHumano': {'atendente', 'humano'}
      },
    );

    final cardapio = etapa('cardapio');
    texto(cardapio, 'titulo', 'Título do cardápio');
    texto(cardapio, 'rodape', 'Rodapé do cardápio');

    final tamanho = etapa('tamanho');
    texto(tamanho, 'mensagem', 'Mensagem de tamanho');
    texto(tamanho, 'tituloLista', 'Título da lista de tamanhos', max: 20);

    final mistura = etapa('mistura');
    texto(mistura, 'mensagem', 'Mensagem de mistura');
    texto(mistura, 'tituloLista', 'Título da lista de misturas', max: 20);

    final acompanhamento = etapa('acompanhamento');
    texto(acompanhamento, 'mensagem', 'Mensagem de acompanhamento');
    texto(acompanhamento, 'tituloLista', 'Título da lista de acompanhamentos',
        max: 20);

    final quantidade = etapa('quantidade');
    texto(quantidade, 'mensagem', 'Mensagem de quantidade');
    texto(quantidade, 'ajuda', 'Ajuda de quantidade');
    final maximo = (quantidade['maximo'] as num?)?.toInt() ?? 0;
    if (maximo < 1 || maximo > 50) {
      throw ArgumentError('A quantidade máxima deve ficar entre 1 e 50.');
    }

    final outro = etapa('adicionarOutro');
    texto(outro, 'mensagem', 'Mensagem de adicionar outro item');
    botoesUnicos(outro, ['botaoSim', 'botaoNao'], 'Adicionar outra marmita');

    final recebimento = etapa('recebimento');
    texto(recebimento, 'mensagem', 'Mensagem de recebimento');
    botoesUnicos(recebimento, ['botaoEntrega', 'botaoRetirada'], 'Recebimento');

    final endereco = etapa('endereco');
    texto(endereco, 'mensagem', 'Mensagem de endereço');

    texto(etapa('cidadeEntrega'), 'mensagem', 'Pergunta da cidade');
    final pagamento = etapa('pagamento');
    texto(pagamento, 'mensagem', 'Mensagem de pagamento');
    botoesUnicos(
        pagamento, ['botaoPix', 'botaoDinheiro', 'botaoCartao'], 'Pagamento');

    final troco = etapa('troco');
    texto(troco, 'mensagem', 'Mensagem de troco');
    texto(troco, 'textoSemTroco', 'Texto para sem troco', max: 30);

    final observacao = etapa('observacao');
    texto(observacao, 'mensagem', 'Mensagem de observação');
    texto(observacao, 'mensagemAlterar', 'Mensagem para alterar observação');
    texto(observacao, 'textoNenhuma', 'Texto para nenhuma observação', max: 30);
    validarComandoReservado(
      observacao['textoNenhuma'].toString(),
      'O texto “nenhuma observação”',
    );
    validarComandoReservado(
      troco['textoSemTroco'].toString(),
      'O texto “sem troco”',
    );

    final bebida = etapa('bebida');
    texto(bebida, 'mensagem', 'Mensagem de bebidas');
    texto(bebida, 'tituloLista', 'Título da lista de bebidas', max: 20);
    texto(bebida, 'botaoSemBebida', 'Botão sem bebida', max: 20);
    validarComandoReservado(
        bebida['botaoSemBebida'].toString(), 'O botão sem bebida');

    final quantidadeBebida = etapa('quantidadeBebida');
    texto(quantidadeBebida, 'mensagem', 'Mensagem de quantidade de bebida');
    texto(quantidadeBebida, 'ajuda', 'Ajuda de quantidade de bebida');
    final maximoBebida = (quantidadeBebida['maximo'] as num?)?.toInt() ?? 0;
    if (maximoBebida < 1 || maximoBebida > 50) {
      throw ArgumentError(
          'A quantidade máxima de bebida deve ficar entre 1 e 50.');
    }

    final outraBebida = etapa('adicionarOutraBebida');
    texto(outraBebida, 'mensagem', 'Mensagem de adicionar outra bebida');
    botoesUnicos(
        outraBebida, ['botaoSim', 'botaoNao'], 'Adicionar outra bebida');

    final resumo = etapa('resumo');
    texto(resumo, 'titulo', 'Título do resumo');
    botoesUnicos(
      resumo,
      ['botaoConfirmar', 'botaoRefazer', 'botaoCancelar'],
      'Resumo',
      permitidos: {
        'botaoCancelar': {'cancelar'}
      },
    );

    final sistema = etapa('sistema');
    for (final par in const [
      ('sessaoExpirada', 'Mensagem de sessão expirada'),
      ('pedidoCancelado', 'Mensagem de pedido cancelado'),
      ('humanoAtivado', 'Mensagem de atendimento humano'),
      ('retomado', 'Mensagem de retomada'),
      ('refazer', 'Mensagem de refazer pedido'),
    ]) {
      texto(sistema, par.$1, par.$2);
    }
  }

  static int? _minutos(String valor) {
    final partes = valor.split(':');
    if (partes.length != 2) return null;
    final h = int.tryParse(partes[0]);
    final m = int.tryParse(partes[1]);
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59)
      return null;
    return h * 60 + m;
  }

  static String _normalizar(String valor) {
    return valor
        .toLowerCase()
        .replaceAll('á', 'a')
        .replaceAll('à', 'a')
        .replaceAll('ã', 'a')
        .replaceAll('â', 'a')
        .replaceAll('é', 'e')
        .replaceAll('ê', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ô', 'o')
        .replaceAll('õ', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ç', 'c')
        .trim();
  }
}

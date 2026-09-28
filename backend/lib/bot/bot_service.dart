import 'dart:async';

import '../banco/banco.dart';
import '../modelos/mensagem_whatsapp.dart';
import '../util/calculo_pedido.dart';
import '../servicos/whatsapp_service.dart';
import '../util/data_hora.dart';
import '../util/estado_atendimento.dart';

class BotService {
  final Banco banco;
  final WhatsAppService whatsapp;
  Future<void> _fila = Future<void>.value();

  BotService(this.banco, this.whatsapp);

  // Serializa as transições. Dentro da transação, WhatsApp apenas persiste a
  // saída; nenhum acesso de rede ocorre com a transação SQLite aberta.
  Future<void> processar(MensagemWhatsApp msg) {
    final atual = _fila.catchError((_) {}).then((_) async {
      banco.db.execute('BEGIN IMMEDIATE');
      try {
        await _processarInterno(msg);
        banco.db.execute('DELETE FROM webhook_entrada WHERE id = ?', [msg.id]);
        banco.db.execute('COMMIT');
      } catch (e) {
        banco.db.execute('ROLLBACK');
        banco.log('ERROR', 'bot_transacao_desfeita', e.runtimeType.toString());
        rethrow;
      }
    });
    _fila = atual;
    return atual;
  }

  Future<void> retomarAtendimentoHumano(String telefone) async {
    final sessaoAnterior = banco.obterSessao(telefone);
    final nome = sessaoAnterior?['nome']?.toString() ?? 'Cliente';
    banco.retomarModoAutomatico(telefone);

    final config = Map<String, dynamic>.from(
      banco.obterConfiguracao()['dados'] as Map,
    );
    final estado = _estadoEfetivo(config);
    if (estado == 'atendendo') {
      await whatsapp.enviarBotoes(
        telefone,
        '${_textoFluxo('sistema', 'retomado', '🤖 Atendimento automático retomado.')}\n\n${_textoFluxo('inicio', 'mensagem', 'Como podemos ajudar?')}',
        _botoesInicio(),
      );
      return;
    }

    final mensagens =
        Map<String, dynamic>.from(config['mensagens'] as Map? ?? {});
    final texto = (mensagens[estado] ??
            mensagens['fechado'] ??
            'No momento não estamos atendendo.')
        .toString();
    await whatsapp.enviarTexto(
      telefone,
      '🍱 *${config['nomeEstabelecimento']}*\n\n$texto',
    );
    banco.salvarSessao(
      telefone: telefone,
      nome: nome,
      etapa: 'inicio',
      dados: {
        'clienteNome': nome,
        'itens': <dynamic>[],
        'ultimaRespostaIndisponivel': agoraIso(),
        'somenteIndisponibilidade': true,
      },
    );
  }

  Future<void> _processarInterno(MensagemWhatsApp msg) async {
    if (!banco.iniciarProcessamentoMensagem(msg.id)) return;
    try {
      await whatsapp.marcarComoLida(msg.id);
      final configWrapper = banco.obterConfiguracao();
      final config = Map<String, dynamic>.from(configWrapper['dados'] as Map);

      var sessao = banco.obterSessao(msg.telefone);
      if (sessao?['modoHumano'] == true) {
        banco.finalizarMensagem(msg.id);
        return;
      }
      final resposta = msg.entrada;
      if (resposta.contains('|')) {
        final partes = resposta.split('|');
        final esperado = (sessao?['dados'] as Map?)?['promptId'];
        if (partes.length != 2 || partes.first != esperado) {
          await whatsapp.enviarTexto(msg.telefone,
              'Esta opção é de uma etapa anterior. Use a última mensagem ou digite voltar. Para começar novamente, digite 0.');
          banco.finalizarMensagem(msg.id);
          return;
        }
        msg = MensagemWhatsApp(
            id: msg.id,
            telefone: msg.telefone,
            nome: msg.nome,
            texto: msg.texto,
            respostaId: partes.last,
            enviadaEm: msg.enviadaEm);
      } else if (msg.respostaId != null &&
          (sessao?['dados'] as Map?)?['promptId'] != null) {
        await whatsapp.enviarTexto(
            msg.telefone, 'Use os botões da última mensagem ou digite voltar.');
        banco.finalizarMensagem(msg.id);
        return;
      }

      final expirou = _sessaoExpirou(sessao, config);
      if (expirou) {
        banco.excluirSessao(msg.telefone);
        sessao = null;
      }

      if (msg.enviadaEm != null &&
          DateTime.now().toUtc().difference(msg.enviadaEm!).inMinutes >
              (config['sessaoExpiraMinutos'] as num? ?? 30)) {
        banco.finalizarMensagem(msg.id);
        return;
      }
      if (msg.entrada.isEmpty) {
        await whatsapp.enviarTexto(msg.telefone,
            'Envie uma mensagem de texto ou escolha uma opção. Para ajuda, digite atendente.');
        banco.finalizarMensagem(msg.id);
        return;
      }
      final entrada = _normalizar(msg.entrada);
      if (_ehComandoAjuda(entrada)) {
        await _responderAjuda(msg, sessao);
        banco.finalizarMensagem(msg.id);
        return;
      }
      if (_ehComandoCancelar(entrada)) {
        _salvarInicioLimpo(msg.telefone, msg.nome);
        await whatsapp.enviarBotoes(
          msg.telefone,
          _textoFluxo('sistema', 'pedidoCancelado',
              'Pedido cancelado. 🙂\nQuando quiser começar novamente, escolha uma opção:'),
          _botoesInicio(),
        );
        banco.finalizarMensagem(msg.id);
        return;
      }

      if (_ehComandoHumano(entrada)) {
        banco.definirModoHumano(msg.telefone, true);
        await whatsapp.enviarTexto(
          msg.telefone,
          _textoFluxo('sistema', 'humanoAtivado',
              'Certo! 👤 O atendimento automático foi pausado para esta conversa. Um atendente continuará por aqui.'),
        );
        banco.finalizarMensagem(msg.id);
        return;
      }

      final estado = _estadoEfetivo(config);
      if (estado != 'atendendo') {
        await _responderIndisponivel(msg, config, estado, sessao);
        banco.finalizarMensagem(msg.id);
        return;
      }

      if (expirou) {
        await _iniciar(
          msg,
          config,
          aviso: _textoFluxo('sistema', 'sessaoExpirada',
              '⏱️ Seu pedido anterior expirou por falta de atividade. Vamos começar novamente.'),
        );
        banco.finalizarMensagem(msg.id);
        return;
      }

      if (sessao != null && _ehComandoVoltar(entrada)) {
        await _voltar(msg, config, sessao);
        banco.finalizarMensagem(msg.id);
        return;
      }

      if (sessao == null) {
        await _iniciar(msg, config);
      } else {
        await _continuar(msg, config, sessao);
      }
      banco.finalizarMensagem(msg.id);
    } catch (e) {
      banco.log('ERROR', 'bot_erro', e.runtimeType.toString());
      banco.finalizarMensagem(msg.id, sucesso: false);
      rethrow;
    }
  }

  bool _sessaoExpirou(
    Map<String, dynamic>? sessao,
    Map<String, dynamic> config,
  ) {
    if (sessao == null) return false;
    final ultima =
        DateTime.tryParse(sessao['ultimaAtividade']?.toString() ?? '');
    final minutos = (config['sessaoExpiraMinutos'] as num?)?.toInt() ?? 30;
    return ultima == null ||
        agoraLocal().difference(ultima).inMinutes >= minutos;
  }

  String _estadoEfetivo(Map<String, dynamic> config) =>
      estadoAtendimentoEfetivo(config);

  Future<void> _responderIndisponivel(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    String estado,
    Map<String, dynamic>? sessao,
  ) async {
    final dadosAnteriores =
        Map<String, dynamic>.from(sessao?['dados'] as Map? ?? {});
    final ultimaResposta = DateTime.tryParse(
      dadosAnteriores['ultimaRespostaIndisponivel']?.toString() ?? '',
    );

    final preservarPedido = estado == 'pausado';
    final dados = preservarPedido
        ? dadosAnteriores
        : <String, dynamic>{
            'clienteNome': msg.nome,
            'itens': <dynamic>[],
            if (dadosAnteriores['ultimaRespostaIndisponivel'] != null)
              'ultimaRespostaIndisponivel':
                  dadosAnteriores['ultimaRespostaIndisponivel'],
            'somenteIndisponibilidade': true,
          };

    if (ultimaResposta != null &&
        agoraLocal().difference(ultimaResposta).inMinutes < 10) {
      if (!preservarPedido) {
        banco.salvarSessao(
          telefone: msg.telefone,
          nome: msg.nome,
          etapa: 'inicio',
          dados: dados,
          modoHumano: false,
        );
      }
      return;
    }

    final mensagens =
        Map<String, dynamic>.from(config['mensagens'] as Map? ?? {});
    final texto = (mensagens[estado] ??
            mensagens['fechado'] ??
            'No momento não estamos atendendo.')
        .toString();
    await whatsapp.enviarTexto(
      msg.telefone,
      '🍱 *${config['nomeEstabelecimento']}*\n\n$texto',
    );

    dados['ultimaRespostaIndisponivel'] = agoraIso();
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: preservarPedido
          ? (sessao?['etapa']?.toString() ?? 'inicio')
          : 'inicio',
      dados: dados,
      modoHumano: false,
    );
  }

  Future<void> _iniciar(
    MensagemWhatsApp msg,
    Map<String, dynamic> config, {
    String? aviso,
  }) async {
    final dados = <String, dynamic>{
      'clienteNome': msg.nome,
      'itens': <dynamic>[],
    };
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'inicio',
      dados: dados,
    );

    final entrada = _normalizar(msg.entrada);
    if (aviso == null && _entradaEhOpcaoInicio(entrada)) {
      await _tratarInicio(msg, config, dados, entrada);
      return;
    }

    final mensagens =
        Map<String, dynamic>.from(config['mensagens'] as Map? ?? {});
    final boas = (mensagens['boasVindas'] ?? 'Olá! 👋').toString();
    final prefixo = aviso == null ? '' : '$aviso\n\n';
    const guia = '💡 *COMANDOS DURANTE O PEDIDO*\n'
        '↩️ Digite *VOLTAR* para retornar à etapa anterior.\n'
        '❌ Digite *CANCELAR* para cancelar o pedido atual.\n'
        '👤 Digite *ATENDENTE* para falar com nossa equipe.\n\n'
        'Você também pode escrever essas opções do seu jeito que eu vou entender. 😊';
    await whatsapp.enviarBotoes(
      msg.telefone,
      '${prefixo}🍱 *${config['nomeEstabelecimento']}*\n\n$boas\n\n$guia\n\n${_textoFluxo('inicio', 'mensagem', 'Como podemos ajudar?')}',
      _botoesInicio(),
    );
  }

  void _salvarInicioLimpo(String telefone, String nome) {
    banco.salvarSessao(
      telefone: telefone,
      nome: nome,
      etapa: 'inicio',
      dados: {
        'clienteNome': nome,
        'itens': <dynamic>[],
      },
    );
  }

  List<Map<String, String>> _botoesInicio() => [
        {
          'id': 'inicio_pedido',
          'titulo': _textoFluxo('inicio', 'botaoPedido', 'Fazer pedido')
        },
        {
          'id': 'inicio_cardapio',
          'titulo': _textoFluxo('inicio', 'botaoCardapio', 'Ver cardápio')
        },
        {
          'id': 'inicio_humano',
          'titulo': _textoFluxo('inicio', 'botaoHumano', 'Falar atendente')
        },
      ];

  bool _entradaEhOpcaoInicio(String entrada) {
    return _corresponde(entrada, [
      'inicio_pedido',
      'inicio_cardapio',
      'inicio_humano',
      '1',
      '2',
      '3',
      'fazer pedido',
      'pedido',
      'ver cardapio',
      'cardapio',
      'falar atendente',
      'atendente',
      _textoFluxo('inicio', 'botaoPedido', 'Fazer pedido'),
      _textoFluxo('inicio', 'botaoCardapio', 'Ver cardápio'),
      _textoFluxo('inicio', 'botaoHumano', 'Falar atendente'),
    ]);
  }

  Future<void> _continuar(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> sessao,
  ) async {
    final etapa = sessao['etapa']?.toString() ?? 'inicio';
    final dados = Map<String, dynamic>.from(sessao['dados'] as Map? ?? {});
    final entrada = _normalizar(msg.entrada);

    switch (etapa) {
      case 'inicio':
        await _tratarInicio(msg, config, dados, entrada);
        break;
      case 'tamanho':
        await _tratarTamanho(msg, config, dados, entrada);
        break;
      case 'mistura':
        await _tratarMistura(msg, config, dados, entrada);
        break;
      case 'acompanhamento':
        await _tratarAcompanhamento(msg, config, dados, entrada);
        break;
      case 'quantidade':
        await _tratarQuantidade(msg, config, dados, entrada);
        break;
      case 'adicionar_outro':
        await _tratarAdicionarOutro(msg, config, dados, entrada);
        break;
      case 'recebimento':
        await _tratarRecebimento(msg, config, dados, entrada);
        break;
      case 'endereco':
        await _tratarEndereco(msg, config, dados, entrada);
        break;
      case 'cidade_entrega':
        await _tratarCidadeEntrega(msg, config, dados, entrada);
        break;
      case 'pagamento':
        await _tratarPagamento(msg, config, dados, entrada);
        break;
      case 'troco':
        await _tratarTroco(msg, config, dados, entrada);
        break;
      case 'observacao':
        await _tratarObservacao(msg, config, dados, entrada);
        break;
      case 'confirmacao':
        await _tratarConfirmacao(msg, config, dados, entrada);
        break;
      default:
        banco.excluirSessao(msg.telefone);
        await _iniciar(msg, config);
    }
  }

  Future<void> _tratarInicio(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    if (_corresponde(entrada, [
      'inicio_pedido',
      '1',
      'fazer pedido',
      'pedido',
      _textoFluxo('inicio', 'botaoPedido', 'Fazer pedido')
    ])) {
      dados
        ..clear()
        ..addAll({'clienteNome': msg.nome, 'itens': <dynamic>[]});
      await _mostrarTamanhos(msg, dados);
      return;
    }
    if (_corresponde(entrada, [
      'inicio_cardapio',
      '2',
      'ver cardapio',
      'cardapio',
      _textoFluxo('inicio', 'botaoCardapio', 'Ver cardápio')
    ])) {
      await _mostrarCardapio(msg, config);
      return;
    }
    if (_corresponde(entrada, [
      'inicio_humano',
      '3',
      'falar atendente',
      'atendente',
      _textoFluxo('inicio', 'botaoHumano', 'Falar atendente')
    ])) {
      banco.definirModoHumano(msg.telefone, true);
      await whatsapp.enviarTexto(
        msg.telefone,
        _textoFluxo('sistema', 'humanoAtivado',
            '👤 Atendimento automático pausado. Um atendente continuará por aqui.'),
      );
      return;
    }
    await whatsapp.enviarBotoes(
      msg.telefone,
      _textoFluxo('inicio', 'mensagem', 'Escolha uma opção abaixo:'),
      _botoesInicio(),
    );
  }

  Future<void> _mostrarCardapio(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
  ) async {
    final c = banco.obterCardapio();
    final tamanhos = (c['tamanhos'] as List)
        .where((e) => (e as Map)['ativo'] == true)
        .toList();
    final misturas = (c['misturas'] as List)
        .where((e) => (e as Map)['ativo'] == true)
        .toList();
    final acompanhamentos = (c['acompanhamentos'] as List)
        .where((e) => (e as Map)['ativo'] == true)
        .toList();

    if (tamanhos.isEmpty || misturas.isEmpty || acompanhamentos.isEmpty) {
      await _semOpcao(
        msg,
        'O cardápio está temporariamente indisponível. Fale com um atendente.',
      );
      return;
    }

    final linhas = <String>[
      _textoFluxo('cardapio', 'titulo', '🍱 *CARDÁPIO DO DIA*'),
      ''
    ];
    for (final t in tamanhos) {
      final m = Map<String, dynamic>.from(t as Map);
      linhas.add('• ${m['nome']} — ${moeda((m['preco'] as num).toDouble())}');
    }
    linhas.addAll([
      '',
      '*Misturas:*',
      ...misturas.map((e) => '• ${(e as Map)['nome']}'),
    ]);
    linhas.addAll([
      '',
      '*Acompanhamentos:*',
      ...acompanhamentos.map((e) => '• ${(e as Map)['nome']}'),
    ]);
    if (config['saladaIncluida'] == true) {
      linhas
          .add('\n🥗 ${config['descricaoSalada'] ?? 'Salada do dia'} inclusa.');
    }
    linhas.add(
        '\n${_textoFluxo('cardapio', 'rodape', 'O mesmo padrão em todos os tamanhos; muda a quantidade.')}');
    await whatsapp.enviarBotoes(
      msg.telefone,
      linhas.join('\n'),
      [
        {
          'id': 'inicio_pedido',
          'titulo': _textoFluxo('inicio', 'botaoPedido', 'Fazer pedido')
        },
        {
          'id': 'inicio_humano',
          'titulo': _textoFluxo('inicio', 'botaoHumano', 'Falar atendente')
        },
      ],
    );
  }

  Future<void> _mostrarTamanhos(
    MensagemWhatsApp msg,
    Map<String, dynamic> dados,
  ) async {
    final cardapio = banco.obterCardapio();
    final tamanhos = (cardapio['tamanhos'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((e) => e['ativo'] == true)
        .toList();
    if (tamanhos.isEmpty) {
      await _semOpcao(
        msg,
        'No momento não há tamanhos disponíveis. Fale com um atendente.',
      );
      return;
    }
    dados['opcoesExibidas'] = tamanhos;
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'tamanho',
      dados: dados,
    );
    final opcoes = tamanhos
        .map((t) => <String, String>{
              'id': 'tam:${t['id']}',
              'titulo': '${t['nome']} ${moeda((t['preco'] as num).toDouble())}',
              'descricao': 'Escolher ${t['nome']}',
            })
        .toList();
    if (opcoes.length <= 3) {
      await whatsapp.enviarBotoes(
        msg.telefone,
        _textoFluxo('tamanho', 'mensagem', 'Escolha o tamanho da marmita:'),
        opcoes,
      );
    } else {
      await whatsapp.enviarLista(
        msg.telefone,
        texto:
            _textoFluxo('tamanho', 'mensagem', 'Escolha o tamanho da marmita:'),
        tituloBotao: _textoFluxo('tamanho', 'tituloLista', 'Ver tamanhos'),
        opcoes: opcoes,
      );
    }
  }

  Future<void> _tratarTamanho(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    final tamanhos = (dados['opcoesExibidas'] as List? ??
            banco.obterCardapio()['tamanhos'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((e) => e['ativo'] == true)
        .toList();
    final escolhido = _acharOpcao(entrada, tamanhos, prefixo: 'tam:');
    if (escolhido == null) {
      await _mostrarTamanhos(msg, dados);
      return;
    }
    dados['itemAtual'] = {
      'tamanhoId': escolhido['id'],
      'tamanhoNome': escolhido['nome'],
      'precoUnitario': (escolhido['preco'] as num).toDouble(),
      'saladaIncluida': config['saladaIncluida'] == true,
      'descricaoSalada': config['descricaoSalada']?.toString() ?? 'Salada',
    };
    await _mostrarMisturas(msg, dados);
  }

  Future<void> _mostrarMisturas(
    MensagemWhatsApp msg,
    Map<String, dynamic> dados,
  ) async {
    final cardapio = banco.obterCardapio();
    final lista = (cardapio['misturas'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((e) => e['ativo'] == true)
        .toList();
    if (lista.isEmpty) {
      await _semOpcao(
        msg,
        'Nenhuma mistura está disponível agora. Fale com um atendente.',
      );
      return;
    }
    dados['opcoesExibidas'] = lista;
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'mistura',
      dados: dados,
    );
    final opcoes = lista
        .map((e) => <String, String>{
              'id': 'mis:${e['id']}',
              'titulo': e['nome'].toString(),
              'descricao': 'Escolher mistura',
            })
        .toList();
    if (opcoes.length <= 3) {
      await whatsapp.enviarBotoes(msg.telefone,
          _textoFluxo('mistura', 'mensagem', 'Escolha a mistura:'), opcoes);
    } else {
      await whatsapp.enviarLista(
        msg.telefone,
        texto: _textoFluxo('mistura', 'mensagem', 'Escolha a mistura:'),
        tituloBotao: _textoFluxo('mistura', 'tituloLista', 'Ver misturas'),
        opcoes: opcoes,
      );
    }
  }

  Future<void> _tratarMistura(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    final lista = (dados['opcoesExibidas'] as List? ??
            banco.obterCardapio()['misturas'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((e) => e['ativo'] == true)
        .toList();
    final escolhido = _acharOpcao(entrada, lista, prefixo: 'mis:');
    if (escolhido == null) {
      await _mostrarMisturas(msg, dados);
      return;
    }
    final atual = Map<String, dynamic>.from(dados['itemAtual'] as Map);
    atual['misturaId'] = escolhido['id'];
    atual['misturaNome'] = escolhido['nome'];
    dados['itemAtual'] = atual;
    await _mostrarAcompanhamentos(msg, dados);
  }

  Future<void> _mostrarAcompanhamentos(
    MensagemWhatsApp msg,
    Map<String, dynamic> dados,
  ) async {
    final cardapio = banco.obterCardapio();
    final lista = (cardapio['acompanhamentos'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((e) => e['ativo'] == true)
        .toList();
    if (lista.isEmpty) {
      await _semOpcao(
        msg,
        'Nenhum acompanhamento está disponível agora. Fale com um atendente.',
      );
      return;
    }
    dados['opcoesExibidas'] = lista;
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'acompanhamento',
      dados: dados,
    );
    final opcoes = lista
        .map((e) => <String, String>{
              'id': 'aco:${e['id']}',
              'titulo': e['nome'].toString(),
              'descricao': 'Escolher acompanhamento',
            })
        .toList();
    if (opcoes.length <= 3) {
      await whatsapp.enviarBotoes(
        msg.telefone,
        _textoFluxo('acompanhamento', 'mensagem', 'Escolha 1 acompanhamento:'),
        opcoes,
      );
    } else {
      await whatsapp.enviarLista(
        msg.telefone,
        texto: _textoFluxo(
            'acompanhamento', 'mensagem', 'Escolha 1 acompanhamento:'),
        tituloBotao: _textoFluxo('acompanhamento', 'tituloLista', 'Ver opções'),
        opcoes: opcoes,
      );
    }
  }

  Future<void> _tratarAcompanhamento(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    final lista = (dados['opcoesExibidas'] as List? ??
            banco.obterCardapio()['acompanhamentos'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((e) => e['ativo'] == true)
        .toList();
    final escolhido = _acharOpcao(entrada, lista, prefixo: 'aco:');
    if (escolhido == null) {
      await _mostrarAcompanhamentos(msg, dados);
      return;
    }
    final atual = Map<String, dynamic>.from(dados['itemAtual'] as Map);
    atual['acompanhamentoId'] = escolhido['id'];
    atual['acompanhamentoNome'] = escolhido['nome'];
    dados['itemAtual'] = atual;
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'quantidade',
      dados: dados,
    );
    final maximo = _intFluxo('quantidade', 'maximo', 20).clamp(1, 50);
    final titulo = _textoFluxo(
        'quantidade', 'mensagem', 'Quantas marmitas iguais a essa?');
    final ajuda = _textoFluxo(
            'quantidade', 'ajuda', 'Digite apenas a quantidade de 1 a {max}.')
        .replaceAll('{max}', '$maximo');
    await whatsapp.enviarTexto(
      msg.telefone,
      '$titulo\n$ajuda\n\n*0* cancela • digite *voltar* para retornar.',
    );
  }

  Future<void> _tratarQuantidade(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    final maximo = _intFluxo('quantidade', 'maximo', 20).clamp(1, 50);
    final qtd = _parseQuantidade(entrada);
    if (qtd == null || qtd < 1 || qtd > maximo) {
      await whatsapp.enviarTexto(
        msg.telefone,
        'Digite somente um número de 1 a $maximo. Ex.: *2*.',
      );
      return;
    }
    final atual = Map<String, dynamic>.from(dados['itemAtual'] as Map);
    atual['quantidade'] = qtd;
    final itens = List<Map<String, dynamic>>.from(
      (dados['itens'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map)),
    );
    itens.add(atual);
    dados['itens'] = itens;
    dados.remove('itemAtual');
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'adicionar_outro',
      dados: dados,
    );
    await _mostrarAdicionarOutro(msg);
  }

  Future<void> _mostrarAdicionarOutro(MensagemWhatsApp msg) async {
    await whatsapp.enviarBotoes(
      msg.telefone,
      _textoFluxo('adicionarOutro', 'mensagem',
          '✅ Item adicionado. Quer adicionar outra marmita?'),
      [
        {
          'id': 'outro_sim',
          'titulo': _textoFluxo('adicionarOutro', 'botaoSim', 'Adicionar outra')
        },
        {
          'id': 'outro_nao',
          'titulo':
              _textoFluxo('adicionarOutro', 'botaoNao', 'Finalizar pedido')
        },
      ],
    );
  }

  Future<void> _tratarAdicionarOutro(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    if (_corresponde(entrada, [
      'outro_sim',
      '1',
      'sim',
      'adicionar outra',
      _textoFluxo('adicionarOutro', 'botaoSim', 'Adicionar outra')
    ])) {
      await _mostrarTamanhos(msg, dados);
      return;
    }
    if (_corresponde(
      entrada,
      [
        'outro_nao',
        '2',
        'nao',
        'não',
        'finalizar pedido',
        _textoFluxo('adicionarOutro', 'botaoNao', 'Finalizar pedido')
      ],
    )) {
      await _mostrarRecebimento(msg, config, dados);
      return;
    }
    await _mostrarAdicionarOutro(msg);
  }

  List<Map<String, String>> _opcoesRecebimento(Map<String, dynamic> config) {
    final opcoes = <Map<String, String>>[];
    if (config['entregaAtiva'] == true) {
      opcoes.add({
        'id': 'rec_entrega',
        'titulo': _textoFluxo('recebimento', 'botaoEntrega', 'Entrega')
      });
    }
    if (config['retiradaAtiva'] == true) {
      opcoes.add({
        'id': 'rec_retirada',
        'titulo': _textoFluxo('recebimento', 'botaoRetirada', 'Retirada')
      });
    }
    return opcoes;
  }

  Future<void> _mostrarRecebimento(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados, {
    bool permitirPulo = true,
  }) async {
    final opcoes = _opcoesRecebimento(config);
    if (opcoes.isEmpty) {
      await _semOpcao(
        msg,
        'Entrega e retirada estão temporariamente indisponíveis. Fale com um atendente.',
      );
      return;
    }
    dados['recebimentosExibidos'] = opcoes;
    if (permitirPulo &&
        opcoes.length == 1 &&
        _boolFluxo('recebimento', 'pularSeUnica', true)) {
      await _tratarRecebimento(msg, config, dados, opcoes.first['id']!);
      return;
    }
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'recebimento',
      dados: dados,
    );
    await whatsapp.enviarBotoes(
      msg.telefone,
      _textoFluxo(
          'recebimento', 'mensagem', 'Como você quer receber seu pedido?'),
      opcoes,
    );
  }

  Future<void> _tratarRecebimento(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    final atuais = _opcoesRecebimento(config);
    final opcoes = (dados['recebimentosExibidos'] as List? ?? atuais)
        .map((e) => Map<String, String>.from(e as Map))
        .toList();
    final entradaNatural = _correspondeIntencao(entrada, [
      'entrega',
      'entregar',
      'quero entrega',
      'manda entregar',
      'pode entregar',
      'receber em casa',
    ])
        ? 'rec_entrega'
        : _correspondeIntencao(entrada, [
            'retirada',
            'retirar',
            'quero retirar',
            'vou retirar',
            'vou buscar',
            'buscar no local',
          ])
            ? 'rec_retirada'
            : entrada;
    final opcao = _acharOpcaoSimples(entradaNatural, opcoes);
    if (opcao == null || !atuais.any((e) => e['id'] == opcao['id'])) {
      await _mostrarRecebimento(msg, config, dados);
      return;
    }

    _limparDepoisDoRecebimento(dados);
    if (opcao['id'] == 'rec_entrega') {
      dados['recebimento'] = 'entrega';
      await _pedirEndereco(msg, dados);
      return;
    }

    final enderecoRetirada =
        config['enderecoRetirada']?.toString().trim() ?? '';
    if (enderecoRetirada.isEmpty) {
      await _semOpcao(
        msg,
        'O endereço de retirada ainda não está configurado. Fale com um atendente.',
      );
      return;
    }
    dados['recebimento'] = 'retirada';
    dados['taxaEntregaCongelada'] = 0.0;
    dados['endereco'] = enderecoRetirada;
    await whatsapp.enviarTexto(
      msg.telefone,
      '🏠 *Retirada em:*\n$enderecoRetirada',
    );
    await _mostrarPagamentos(msg, config, dados);
  }

  void _limparDepoisDoRecebimento(Map<String, dynamic> dados) {
    dados.remove('endereco');
    dados.remove('enderecoPendente');
    dados.remove('enderecoValidado');
    dados.remove('cepEntrega');
    dados.remove('cidadeEntrega');
    dados.remove('cidadeEntregaId');
    dados.remove('ufEntrega');
    dados.remove('logradouroValidado');
    dados.remove('bairroValidado');
    dados.remove('pagamento');
    dados.remove('trocoPara');
    dados.remove('observacao');
    dados.remove('taxaEntregaCongelada');
    dados.remove('cidadeConfirmadaCliente');
  }

  Future<void> _pedirEndereco(
    MensagemWhatsApp msg,
    Map<String, dynamic> dados,
  ) async {
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'endereco',
      dados: dados,
    );

    await whatsapp.enviarTexto(
      msg.telefone,
      '${_textoFluxo(
        'endereco',
        'mensagem',
        '📍 Envie seu endereço para entrega:\nRua, número, bairro e complemento/referência.',
      )}\n\nDepois vou perguntar a cidade para calcular a taxa.\nDigite *voltar* para retornar.',
    );
  }

  Future<void> _tratarEndereco(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    final endereco =
        msg.texto.trim().isNotEmpty ? msg.texto.trim() : msg.entrada.trim();

    if (endereco.length > 300) {
      await whatsapp.enviarTexto(
        msg.telefone,
        'O endereço ficou muito longo. Resuma para até 300 caracteres, por favor.',
      );
      return;
    }

    if (msg.respostaId != null ||
        endereco.length < 8 ||
        !RegExp(r'[a-zA-ZÀ-ÿ]').hasMatch(endereco)) {
      await whatsapp.enviarTexto(
        msg.telefone,
        'Envie um endereço um pouco mais completo.\nEx.: Rua das Flores, 120, Centro.',
      );
      return;
    }

    dados['endereco'] = endereco;

    // Limpa qualquer cidade/taxa de uma tentativa anterior.
    dados.remove('cepEntrega');
    dados.remove('cidadeEntrega');
    dados.remove('cidadeEntregaId');
    dados.remove('ufEntrega');
    dados.remove('logradouroValidado');
    dados.remove('bairroValidado');
    dados.remove('cidadeConfirmadaCliente');
    dados.remove('taxaEntregaCongelada');
    dados.remove('pagamento');
    dados.remove('trocoPara');
    dados.remove('observacao');

    await _mostrarCidadeEntrega(
      msg,
      config,
      dados,
    );
  }

  Future<void> _mostrarCidadeEntrega(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
  ) async {
    final cidades = <Map<String, dynamic>>[];

    for (final raw in config['cidadesEntrega'] as List? ?? const []) {
      if (raw is! Map) continue;

      final cidade = Map<String, dynamic>.from(raw);

      if (cidade['ativa'] != true) continue;

      final nome = cidade['nome']?.toString().trim() ?? '';
      final id = cidade['id']?.toString().trim() ?? '';
      final taxa = (cidade['taxa'] as num?)?.toDouble();

      if (nome.isEmpty || id.isEmpty || taxa == null || taxa < 0) {
        continue;
      }

      cidades.add(cidade);
    }

    if (cidades.isEmpty) {
      await _semOpcao(
        msg,
        'Nenhuma cidade está disponível para entrega no momento. Fale com um atendente.',
      );
      return;
    }

    dados['cidadesExibidas'] = cidades;
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'cidade_entrega',
      dados: dados,
    );

    final opcoes = <Map<String, String>>[];

    for (final cidade in cidades) {
      opcoes.add({
        'id': 'cid:${cidade['id']}',
        'titulo': cidade['nome'].toString(),
      });
    }

    final mensagem = _textoFluxo(
      'cidadeEntrega',
      'mensagem',
      '🏙️ Em qual cidade será a entrega?',
    );

    if (opcoes.length <= 3) {
      await whatsapp.enviarBotoes(
        msg.telefone,
        mensagem,
        opcoes,
      );
    } else {
      final numeradas = cidades.indexed.map((item) {
        final indice = item.$1 + 1;
        final cidade = item.$2;
        return '$indice - ${cidade['nome']}';
      }).join('\n');

      await whatsapp.enviarTexto(
        msg.telefone,
        '$mensagem\n\n$numeradas\n\nDigite o número da cidade.',
      );
    }
  }

  Future<void> _tratarCidadeEntrega(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    final cidades = <Map<String, dynamic>>[];

    for (final raw in dados['cidadesExibidas'] as List? ??
        config['cidadesEntrega'] as List? ??
        const []) {
      if (raw is! Map) continue;

      final cidade = Map<String, dynamic>.from(raw);

      if (cidade['ativa'] == true) {
        cidades.add(cidade);
      }
    }

    final opcoes = cidades.map<Map<String, String>>((cidade) {
      return {
        'id': 'cid:${cidade['id']}',
        'titulo': cidade['nome'].toString(),
      };
    }).toList();

    final opcao = _acharOpcaoSimples(
      entrada,
      opcoes,
    );

    if (opcao == null) {
      await _mostrarCidadeEntrega(
        msg,
        config,
        dados,
      );
      return;
    }

    final idEscolhido = (opcao['id'] ?? '').replaceFirst('cid:', '');

    Map<String, dynamic>? cidadeEscolhida;

    for (final cidade in cidades) {
      if (cidade['id']?.toString() == idEscolhido) {
        cidadeEscolhida = cidade;
        break;
      }
    }

    if (cidadeEscolhida == null) {
      await _mostrarCidadeEntrega(
        msg,
        config,
        dados,
      );
      return;
    }

    final taxa = (cidadeEscolhida['taxa'] as num?)?.toDouble();

    if (taxa == null || taxa < 0) {
      await _semOpcao(
        msg,
        'A taxa dessa cidade está indisponível. Fale com um atendente.',
      );
      return;
    }

    dados['cidadeEntrega'] = cidadeEscolhida['nome'].toString();

    dados['cidadeEntregaId'] = cidadeEscolhida['id'].toString();

    dados['ufEntrega'] = cidadeEscolhida['uf']?.toString() ?? 'SP';

    dados['cidadeConfirmadaCliente'] = true;

    // A cidade é confirmada pelo cliente; não houve validação externa de CEP.
    dados['enderecoValidado'] = false;

    dados['taxaEntregaCongelada'] = taxa;

    dados.remove('cepEntrega');
    dados.remove('logradouroValidado');
    dados.remove('bairroValidado');
    dados.remove('pagamento');
    dados.remove('trocoPara');
    dados.remove('observacao');

    await _mostrarPagamentos(
      msg,
      config,
      dados,
    );
  }

  Map<String, dynamic>? _cidadeEntregaConfigurada(
    Map<String, dynamic> config,
    String cidade,
    String uf,
  ) {
    final cidadeNormal = _normalizarBusca(cidade);
    final ufNormal = uf.trim().toUpperCase();
    for (final raw in config['cidadesEntrega'] as List? ?? const []) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      if (_normalizarBusca(item['nome']?.toString() ?? '') == cidadeNormal &&
          (item['uf']?.toString().trim().toUpperCase() ?? '') == ufNormal) {
        return item;
      }
    }
    return null;
  }

  String _normalizarBusca(String valor) {
    return _normalizar(valor)
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _formatarCep(String cep) {
    final c = cep.replaceAll(RegExp(r'\D'), '');
    if (c.length != 8) return cep;
    return '${c.substring(0, 5)}-${c.substring(5)}';
  }

  List<Map<String, String>> _opcoesPagamento(Map<String, dynamic> config) {
    final pagamentos =
        Map<String, dynamic>.from(config['pagamentos'] as Map? ?? {});
    final opcoes = <Map<String, String>>[];
    if (pagamentos['pix'] == true) {
      opcoes.add({
        'id': 'pag_pix',
        'titulo': _textoFluxo('pagamento', 'botaoPix', 'PIX')
      });
    }
    if (pagamentos['dinheiro'] == true) {
      opcoes.add({
        'id': 'pag_dinheiro',
        'titulo': _textoFluxo('pagamento', 'botaoDinheiro', 'Dinheiro')
      });
    }
    if (pagamentos['cartao'] == true) {
      opcoes.add({
        'id': 'pag_cartao',
        'titulo': _textoFluxo('pagamento', 'botaoCartao', 'Cartão')
      });
    }
    return opcoes;
  }

  Future<void> _mostrarPagamentos(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados, {
    bool permitirPulo = true,
  }) async {
    final opcoes = _opcoesPagamento(config);
    if (opcoes.isEmpty) {
      await _semOpcao(
        msg,
        'Nenhuma forma de pagamento está disponível. Fale com um atendente.',
      );
      return;
    }
    dados['pagamentosExibidos'] = opcoes;
    if (permitirPulo &&
        opcoes.length == 1 &&
        _boolFluxo('pagamento', 'pularSeUnica', true)) {
      await _tratarPagamento(msg, config, dados, opcoes.first['id']!);
      return;
    }
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'pagamento',
      dados: dados,
    );
    await whatsapp.enviarBotoes(
      msg.telefone,
      _textoFluxo('pagamento', 'mensagem', 'Como deseja pagar?'),
      opcoes,
    );
  }

  Future<void> _tratarPagamento(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    final atuais = _opcoesPagamento(config);
    final opcoes = (dados['pagamentosExibidos'] as List? ?? atuais)
        .map((e) => Map<String, String>.from(e as Map))
        .toList();
    final entradaNatural = _correspondeIntencao(entrada, [
      'pix',
      'pagar no pix',
      'vou pagar no pix',
    ])
        ? 'pag_pix'
        : _correspondeIntencao(entrada, [
            'dinheiro',
            'pagar em dinheiro',
            'vou pagar em dinheiro',
          ])
            ? 'pag_dinheiro'
            : _correspondeIntencao(entrada, [
                'cartao',
                'credito',
                'debito',
                'cartao de credito',
                'cartao de debito',
                'pagar no cartao',
              ])
                ? 'pag_cartao'
                : entrada;
    final opcao = _acharOpcaoSimples(entradaNatural, opcoes);
    if (opcao == null || !atuais.any((e) => e['id'] == opcao['id'])) {
      await _mostrarPagamentos(msg, config, dados);
      return;
    }

    final pagamento = switch (opcao['id']) {
      'pag_pix' => 'pix',
      'pag_dinheiro' => 'dinheiro',
      'pag_cartao' => 'cartao',
      _ => '',
    };
    if (pagamento.isEmpty) {
      await _mostrarPagamentos(msg, config, dados);
      return;
    }

    dados['pagamento'] = pagamento;
    dados.remove('trocoPara');
    dados.remove('observacao');
    if (pagamento == 'dinheiro') {
      await _pedirTroco(msg, dados);
      return;
    }
    await _irParaObservacaoOuResumo(msg, config, dados);
  }

  Future<void> _pedirTroco(
    MensagemWhatsApp msg,
    Map<String, dynamic> dados,
  ) async {
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'troco',
      dados: dados,
    );
    await whatsapp.enviarTexto(
      msg.telefone,
      _textoFluxo('troco', 'mensagem',
          'Precisa de troco?\nDigite *não* ou informe para quanto, por exemplo: *50*.'),
    );
  }

  Future<void> _tratarTroco(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    if (_corresponde(entrada, [
      'nao',
      'não',
      'n',
      'sem troco',
      'nao precisa',
      'nao preciso',
      _textoFluxo('troco', 'textoSemTroco', 'não')
    ])) {
      dados['trocoPara'] = null;
      await _irParaObservacaoOuResumo(msg, config, dados);
      return;
    }

    final valor = _parseValorMonetario(entrada);
    if (valor == null || valor <= 0) {
      await whatsapp.enviarTexto(
        msg.telefone,
        'Informe um valor válido para o troco, por exemplo *50*, ou digite *${_textoFluxo('troco', 'textoSemTroco', 'não')}*.',
      );
      return;
    }

    final total = _calcular(dados, config).total;
    if (valor < total) {
      await whatsapp.enviarTexto(
        msg.telefone,
        'O total do pedido é *${moeda(total)}*. Para o troco, informe um valor igual ou maior que o total.',
      );
      return;
    }

    dados['trocoPara'] = valor;
    await _irParaObservacaoOuResumo(msg, config, dados);
  }

  Future<void> _irParaObservacaoOuResumo(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
  ) async {
    if (config['permitirObservacoes'] == true) {
      await _pedirObservacao(msg, dados);
    } else {
      dados['observacao'] = null;
      await _mostrarResumo(msg, config, dados);
    }
  }

  Future<void> _pedirObservacao(
    MensagemWhatsApp msg,
    Map<String, dynamic> dados, {
    bool alterando = false,
  }) async {
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'observacao',
      dados: dados,
    );
    final nenhuma = _textoFluxo('observacao', 'textoNenhuma', 'não');
    final base = alterando
        ? _textoFluxo('observacao', 'mensagemAlterar', 'Altere sua observação.')
        : _textoFluxo('observacao', 'mensagem',
            'Deseja alguma observação?\nEx.: sem feijão, pouca salada.');
    await whatsapp.enviarTexto(
      msg.telefone,
      '$base\nDigite *$nenhuma* para nenhuma.',
    );
  }

  Future<void> _tratarObservacao(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    if (_corresponde(
      entrada,
      [
        'nao',
        'não',
        'n',
        'nenhuma',
        'nada',
        'sem nada',
        'nao tenho',
        'sem observacao',
        'sem observação',
        _textoFluxo('observacao', 'textoNenhuma', 'não')
      ],
    )) {
      dados['observacao'] = null;
      await _mostrarResumo(msg, config, dados);
      return;
    }

    final original =
        msg.texto.trim().isNotEmpty ? msg.texto.trim() : msg.entrada.trim();
    if (original.length > 300) {
      await whatsapp.enviarTexto(
        msg.telefone,
        'A observação ficou muito longa. Resuma para até 300 caracteres, por favor.',
      );
      return;
    }
    dados['observacao'] = original;
    await _mostrarResumo(msg, config, dados);
  }

  Future<void> _mostrarResumo(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
  ) async {
    final calculo = _calcular(dados, config);
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'confirmacao',
      dados: dados,
    );
    final linhas = <String>[
      _textoFluxo('resumo', 'titulo', '🧾 *CONFIRA SEU PEDIDO*'),
      ''
    ];
    for (final item in calculo.itens) {
      final qtd = (item['quantidade'] as num).toInt();
      final preco = (item['precoUnitario'] as num).toDouble();
      linhas.add('*${qtd}x ${item['tamanhoNome']} — ${moeda(preco * qtd)}*');
      linhas.add('${item['misturaNome']} • ${item['acompanhamentoNome']}');
      if (item['saladaIncluida'] == true) {
        linhas.add('🥗 ${item['descricaoSalada'] ?? 'Salada'}');
      }
      linhas.add('');
    }

    final recebimento = dados['recebimento']?.toString() ?? '';
    linhas.add(recebimento == 'entrega' ? '🚚 Entrega' : '🏠 Retirada');
    if (recebimento == 'entrega') {
      linhas.add('📍 ${dados['endereco']}');
      final cidade = dados['cidadeEntrega']?.toString().trim() ?? '';
      final uf = dados['ufEntrega']?.toString().trim() ?? '';
      final cep = dados['cepEntrega']?.toString().trim() ?? '';
      if (cidade.isNotEmpty)
        linhas.add('🏙️ $cidade${uf.isEmpty ? '' : ' - $uf'}');
      if (cep.isNotEmpty) linhas.add('📮 CEP ${_formatarCep(cep)}');
    } else {
      final enderecoRetirada = dados['endereco']?.toString().trim() ??
          config['enderecoRetirada']?.toString().trim() ??
          '';
      if (enderecoRetirada.isNotEmpty) linhas.add('📍 $enderecoRetirada');
    }

    linhas.add('💳 ${_pagamentoNome(dados['pagamento']?.toString() ?? '')}');
    if (dados['trocoPara'] != null) {
      linhas.add(
          '💵 Troco para ${moeda((dados['trocoPara'] as num).toDouble())}');
    }
    if ((dados['observacao']?.toString().trim().isNotEmpty ?? false)) {
      linhas.add('📝 ${dados['observacao']}');
    }
    linhas.add('');
    linhas.add('Subtotal: ${moeda(calculo.subtotal)}');
    if (calculo.taxaEntrega > 0) {
      linhas.add('Entrega: ${moeda(calculo.taxaEntrega)}');
    }
    linhas.add('*TOTAL: ${moeda(calculo.total)}*');

    await whatsapp.enviarBotoes(
      msg.telefone,
      linhas.join('\n'),
      [
        {
          'id': 'conf_confirmar',
          'titulo': _textoFluxo('resumo', 'botaoConfirmar', 'Confirmar')
        },
        {
          'id': 'conf_refazer',
          'titulo': _textoFluxo('resumo', 'botaoRefazer', 'Refazer pedido')
        },
        {
          'id': 'conf_cancelar',
          'titulo': _textoFluxo('resumo', 'botaoCancelar', 'Cancelar')
        },
      ],
    );
  }

  Future<void> _tratarConfirmacao(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    if (_corresponde(entrada, [
      'conf_cancelar',
      'cancelar',
      '3',
      _textoFluxo('resumo', 'botaoCancelar', 'Cancelar')
    ])) {
      _salvarInicioLimpo(msg.telefone, msg.nome);
      await whatsapp.enviarBotoes(
        msg.telefone,
        _textoFluxo('sistema', 'pedidoCancelado',
            'Pedido cancelado. 🙂\nEscolha uma opção quando quiser:'),
        _botoesInicio(),
      );
      return;
    }

    if (_corresponde(
      entrada,
      [
        'conf_refazer',
        'conf_alterar',
        'refazer',
        'alterar',
        '2',
        _textoFluxo('resumo', 'botaoRefazer', 'Refazer pedido')
      ],
    )) {
      final nome = dados['clienteNome']?.toString() ?? msg.nome;
      dados
        ..clear()
        ..addAll({'clienteNome': nome, 'itens': <dynamic>[]});
      await whatsapp.enviarTexto(
        msg.telefone,
        _textoFluxo('sistema', 'refazer',
            'Certo. Vamos refazer o pedido desde o começo. 👍'),
      );
      await _mostrarTamanhos(msg, dados);
      return;
    }

    if (!_corresponde(entrada, [
      'conf_confirmar',
      'confirmar',
      '1',
      _textoFluxo('resumo', 'botaoConfirmar', 'Confirmar')
    ])) {
      await _mostrarResumo(msg, config, dados);
      return;
    }

    final itens = dados['itens'] as List? ?? const [];
    if (itens.isEmpty) {
      final nome = dados['clienteNome']?.toString() ?? msg.nome;
      dados
        ..clear()
        ..addAll({'clienteNome': nome, 'itens': <dynamic>[]});
      await whatsapp.enviarTexto(
        msg.telefone,
        'Seu carrinho está vazio. Vamos montar o pedido novamente.',
      );
      await _mostrarTamanhos(msg, dados);
      return;
    }

    final indisponiveis = _itensIndisponiveis(dados);
    if (indisponiveis.isNotEmpty) {
      final nome = dados['clienteNome']?.toString() ?? msg.nome;
      dados
        ..clear()
        ..addAll({'clienteNome': nome, 'itens': <dynamic>[]});
      await whatsapp.enviarTexto(
        msg.telefone,
        '😕 ${indisponiveis.join(', ')} ficou indisponível enquanto montávamos seu pedido. Vamos montar novamente com as opções atuais.',
      );
      await _mostrarTamanhos(msg, dados);
      return;
    }

    final recebimento = dados['recebimento']?.toString() ?? '';
    final recebimentoValido =
        (recebimento == 'entrega' && config['entregaAtiva'] == true) ||
            (recebimento == 'retirada' && config['retiradaAtiva'] == true);
    if (!recebimentoValido) {
      dados.remove('recebimento');
      _limparDepoisDoRecebimento(dados);
      await whatsapp.enviarTexto(
        msg.telefone,
        'A forma de receber escolhida ficou indisponível. Escolha uma opção atual:',
      );
      await _mostrarRecebimento(msg, config, dados);
      return;
    }

    if (recebimento == 'entrega') {
      final enderecoOk =
          (dados['endereco']?.toString().trim().isNotEmpty ?? false) &&
              dados['cidadeConfirmadaCliente'] == true &&
              (dados['cidadeEntrega']?.toString().trim().isNotEmpty ?? false) &&
              (dados['taxaEntregaCongelada'] as num?) != null;
      if (!enderecoOk) {
        await whatsapp.enviarTexto(
          msg.telefone,
          'Precisamos confirmar seu endereço e a cidade da entrega antes de continuar.',
        );
        await _pedirEndereco(msg, dados);
        return;
      }

      final cidadeAtual = _cidadeEntregaConfigurada(
        config,
        dados['cidadeEntrega']?.toString() ?? '',
        dados['ufEntrega']?.toString() ?? '',
      );
      if (cidadeAtual == null || cidadeAtual['ativa'] != true) {
        _limparDepoisDoRecebimento(dados);
        dados['recebimento'] = 'entrega';
        await whatsapp.enviarTexto(
          msg.telefone,
          'A entrega para a cidade do seu endereço ficou indisponível. Envie outro endereço atendido ou digite *voltar* para escolher retirada.',
        );
        await _pedirEndereco(msg, dados);
        return;
      }
    }

    if (recebimento == 'retirada' &&
        (config['enderecoRetirada']?.toString().trim().isEmpty ?? true)) {
      await _semOpcao(
        msg,
        'O endereço de retirada ficou indisponível. Fale com um atendente.',
      );
      return;
    }

    final pagamento = dados['pagamento']?.toString() ?? '';
    if (!_pagamentoAtivo(config, pagamento)) {
      dados.remove('pagamento');
      dados.remove('trocoPara');
      await whatsapp.enviarTexto(
        msg.telefone,
        'A forma de pagamento escolhida ficou indisponível. Escolha outra:',
      );
      await _mostrarPagamentos(msg, config, dados);
      return;
    }

    if (pagamento == 'pix' &&
        (config['chavePix']?.toString().trim().isEmpty ?? true)) {
      dados.remove('pagamento');
      await whatsapp.enviarTexto(
        msg.telefone,
        'O PIX está temporariamente indisponível. Escolha outra forma de pagamento.',
      );
      await _mostrarPagamentos(msg, config, dados);
      return;
    }

    if (pagamento == 'dinheiro' && dados['trocoPara'] != null) {
      final calculoTroco = _calcular(dados, config);
      final trocoPara = (dados['trocoPara'] as num).toDouble();
      if (trocoPara < calculoTroco.total) {
        await whatsapp.enviarTexto(
          msg.telefone,
          'O valor informado para troco ficou menor que o total atual. Vamos corrigir.',
        );
        await _pedirTroco(msg, dados);
        return;
      }
    }

    final calculo = _calcular(dados, config);
    final pedido = banco.criarPedido(
      telefone: msg.telefone,
      mensagemId: msg.id,
      clienteNome: (dados['clienteNome']?.toString().trim().isNotEmpty ?? false)
          ? dados['clienteNome'].toString()
          : msg.nome,
      recebimento: recebimento,
      endereco: dados['endereco']?.toString(),
      cepEntrega: dados['cepEntrega']?.toString(),
      cidadeEntrega: dados['cidadeEntrega']?.toString(),
      ufEntrega: dados['ufEntrega']?.toString(),
      enderecoValidado: dados['enderecoValidado'] == true,
      pagamento: pagamento,
      trocoPara: (dados['trocoPara'] as num?)?.toDouble(),
      observacao: dados['observacao']?.toString(),
      subtotal: calculo.subtotal,
      taxaEntrega: calculo.taxaEntrega,
      itens: calculo.itens,
    );

    // Pedido confirmado encerra totalmente o carrinho anterior. Assim o próximo
    // pedido do mesmo telefone sempre nasce limpo e um segundo clique em um botão
    // antigo de confirmação não cria outro pedido.
    _salvarInicioLimpo(msg.telefone, msg.nome);

    final mensagens =
        Map<String, dynamic>.from(config['mensagens'] as Map? ?? {});
    final confirmado =
        (mensagens['pedidoConfirmado'] ?? 'Pedido enviado para a loja.')
            .toString();
    final extraPix = pagamento == 'pix' &&
            (config['chavePix']?.toString().trim().isNotEmpty ?? false)
        ? '\n\n💠 PIX: ${config['chavePix']}'
        : '';
    final extraRetirada = recebimento == 'retirada' &&
            (config['enderecoRetirada']?.toString().trim().isNotEmpty ?? false)
        ? '\n\n🏠 Retirada em: ${config['enderecoRetirada']}'
        : '';
    await whatsapp.enviarTexto(
      msg.telefone,
      '✅ *PEDIDO #${pedido['numero']} RECEBIDO*\n\n$confirmado\nTotal: ${moeda((pedido['total'] as num).toDouble())}$extraPix$extraRetirada',
    );
  }

  CalculoPedido _calcular(
      Map<String, dynamic> dados, Map<String, dynamic> config) {
    final itens = (dados['itens'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final taxa = dados['recebimento'] == 'entrega'
        ? (dados['taxaEntregaCongelada'] as num?)?.toDouble() ?? 0
        : 0.0;
    return CalculoPedido(itens, taxa);
  }

  List<String> _itensIndisponiveis(Map<String, dynamic> dados) {
    final cardapio = banco.obterCardapio();
    Set<String> ativos(String chave) => (cardapio[chave] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((e) => e['ativo'] == true)
        .map((e) => e['id'].toString())
        .toSet();

    final tamanhos = ativos('tamanhos');
    final misturas = ativos('misturas');
    final acompanhamentos = ativos('acompanhamentos');
    final indisponiveis = <String>[];
    for (final raw in (dados['itens'] as List? ?? const [])) {
      final item = Map<String, dynamic>.from(raw as Map);
      if (!tamanhos.contains(item['tamanhoId']?.toString())) {
        indisponiveis.add(item['tamanhoNome'].toString());
      }
      if (!misturas.contains(item['misturaId']?.toString())) {
        indisponiveis.add(item['misturaNome'].toString());
      }
      if (!acompanhamentos.contains(item['acompanhamentoId']?.toString())) {
        indisponiveis.add(item['acompanhamentoNome'].toString());
      }
    }
    return indisponiveis.toSet().toList();
  }

  Map<String, dynamic>? _acharOpcao(
    String entrada,
    List<Map<String, dynamic>> lista, {
    required String prefixo,
  }) {
    final id =
        entrada.startsWith(prefixo) ? entrada.substring(prefixo.length) : null;
    if (id != null) {
      for (final item in lista) {
        if (item['id'].toString() == id) return item;
      }
    }
    final numero = int.tryParse(entrada);
    if (numero != null && numero >= 1 && numero <= lista.length) {
      return lista[numero - 1];
    }
    for (final item in lista) {
      if (_normalizar(item['nome'].toString()) == entrada) return item;
    }
    return null;
  }

  Map<String, String>? _acharOpcaoSimples(
    String entrada,
    List<Map<String, String>> opcoes,
  ) {
    for (final opcao in opcoes) {
      if (_normalizar(opcao['id'] ?? '') == entrada ||
          _normalizar(opcao['titulo'] ?? '') == entrada) {
        return opcao;
      }
    }
    final numero = int.tryParse(entrada);
    if (numero != null && numero >= 1 && numero <= opcoes.length) {
      return opcoes[numero - 1];
    }
    return null;
  }

  bool _pagamentoAtivo(Map<String, dynamic> config, String pagamento) {
    final pagamentos =
        Map<String, dynamic>.from(config['pagamentos'] as Map? ?? {});
    return switch (pagamento) {
      'pix' => pagamentos['pix'] == true,
      'dinheiro' => pagamentos['dinheiro'] == true,
      'cartao' => pagamentos['cartao'] == true,
      _ => false,
    };
  }

  double? _parseValorMonetario(String entrada) {
    var valor = entrada.toLowerCase().replaceAll('r\$', '').replaceAll(' ', '');
    if (!RegExp(r'^\d+(?:[\.,]\d{1,2})?$').hasMatch(valor)) return null;
    valor = valor.replaceAll(',', '.');
    final n = double.tryParse(valor);
    return n != null && n.isFinite && n <= 1000000 ? n : null;
  }

  Future<void> _semOpcao(
    MensagemWhatsApp msg,
    String texto,
  ) async {
    await whatsapp.enviarBotoes(
      msg.telefone,
      texto,
      [
        {
          'id': 'inicio_humano',
          'titulo': _textoFluxo('inicio', 'botaoHumano', 'Falar atendente')
        },
      ],
    );
  }

  bool _corresponde(String entrada, List<String> opcoes) =>
      opcoes.any((o) => entrada == _normalizar(o));

  bool _ehComandoCancelar(String entrada) => _correspondeIntencao(entrada, [
        '0',
        'cancelar',
        'cancela',
        'cancelar pedido',
        'cancela pedido',
        'cancelar meu pedido',
        'cancela meu pedido',
        'quero cancelar',
        'pode cancelar',
        'desistir do pedido',
        'desisti do pedido',
        'nao quero mais',
        'conf_cancelar',
      ]);

  bool _ehComandoHumano(String entrada) => _correspondeIntencao(entrada, [
        'humano',
        'atendente',
        'inicio_humano',
        'falar com atendente',
        'falar com um atendente',
        'quero falar com atendente',
        'quero falar com um atendente',
        'chamar atendente',
        'chama atendente',
        'atendimento humano',
        'falar com alguem',
        'quero falar com alguem',
        'preciso de um atendente',
        'preciso de ajuda humana',
      ]);

  // Não usamos mais o número 9 como comando global. Quantidade pode ser 9 e
  // listas podem ter 9/10 opções. A palavra “voltar” não conflita com números.
  bool _ehComandoVoltar(String entrada) => _correspondeIntencao(entrada, [
        'voltar',
        'volta',
        'volte',
        'cmd_voltar',
        'quero voltar',
        'pode voltar',
        'voltar etapa',
        'voltar uma etapa',
        'etapa anterior',
        'opcao anterior',
        'resposta anterior',
        'escolhi errado',
        'digitei errado',
      ]);

  bool _ehComandoAjuda(String entrada) => _correspondeIntencao(entrada, [
        'ajuda',
        'help',
        'me ajuda',
        'preciso de ajuda',
        'nao entendi',
        'o que eu faco',
        'o que faco',
        'como funciona',
      ]);

  Future<void> _responderAjuda(
    MensagemWhatsApp msg,
    Map<String, dynamic>? sessao,
  ) async {
    final etapa = sessao?['etapa']?.toString() ?? 'inicio';
    final orientacao = switch (etapa) {
      'tamanho' => 'Escolha o tamanho da marmita na lista.',
      'mistura' => 'Escolha uma mistura na lista.',
      'acompanhamento' => 'Escolha um acompanhamento na lista.',
      'quantidade' => 'Digite quantas marmitas iguais você deseja. Ex.: *2*.',
      'adicionar_outro' =>
        'Escolha se deseja adicionar outra marmita ou finalizar o pedido.',
      'recebimento' => 'Escolha *Entrega* ou *Retirada*.',
      'endereco' => 'Envie rua, número, bairro e complemento ou referência.',
      'cidade_entrega' => 'Escolha a cidade da entrega.',
      'pagamento' => 'Escolha PIX, dinheiro ou cartão.',
      'troco' => 'Digite *não* ou o valor para o troco. Ex.: *50*.',
      'observacao' =>
        'Escreva a observação ou digite *não* se não tiver nenhuma.',
      'confirmacao' =>
        'Confira o resumo e escolha confirmar, refazer ou cancelar.',
      _ => 'Escolha uma das opções exibidas para começar.',
    };
    await whatsapp.enviarTexto(
      msg.telefone,
      '❓ *AJUDA*\n$orientacao\n\n'
      'Digite *VOLTAR* para retornar, *CANCELAR* para cancelar ou '
      '*ATENDENTE* para falar com nossa equipe.',
    );
  }

  int? _parseQuantidade(String entrada) {
    final texto = _normalizar(entrada)
        .replaceFirst(RegExp(r'^(quero|preciso de|vou querer) '), '')
        .replaceFirst(RegExp(r' marmitas?$'), '');
    final numero = int.tryParse(texto);
    if (numero != null) return numero;
    return const {
      'uma': 1,
      'um': 1,
      'duas': 2,
      'dois': 2,
      'tres': 3,
      'quatro': 4,
      'cinco': 5,
      'seis': 6,
      'sete': 7,
      'oito': 8,
      'nove': 9,
      'dez': 10,
    }[texto];
  }

  bool _correspondeIntencao(String entrada, List<String> intencoes) {
    final texto = _normalizar(entrada)
        .replaceFirst(RegExp(r'^por favor '), '')
        .replaceFirst(RegExp(r'^eu '), '')
        .replaceFirst(RegExp(r' por favor$'), '');
    return intencoes.any((intencao) => texto == _normalizar(intencao));
  }

  Future<void> _voltar(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> sessao,
  ) async {
    final etapa = sessao['etapa']?.toString() ?? 'inicio';
    final dados = Map<String, dynamic>.from(sessao['dados'] as Map? ?? {});
    switch (etapa) {
      case 'cidade_entrega':
        await _pedirEndereco(msg, dados);
        return;
      case 'mistura':
        await _mostrarTamanhos(msg, dados);
        return;
      case 'acompanhamento':
        await _mostrarMisturas(msg, dados);
        return;
      case 'quantidade':
        await _mostrarAcompanhamentos(msg, dados);
        return;
      case 'adicionar_outro':
        final itens = List<Map<String, dynamic>>.from(
          (dados['itens'] as List? ?? const [])
              .map((e) => Map<String, dynamic>.from(e as Map)),
        );
        if (itens.isNotEmpty) {
          final ultimo = Map<String, dynamic>.from(itens.removeLast());
          final quantidade =
              (ultimo.remove('quantidade') as num?)?.toInt() ?? 1;
          dados['itens'] = itens;
          dados['itemAtual'] = ultimo;
          banco.salvarSessao(
            telefone: msg.telefone,
            nome: msg.nome,
            etapa: 'quantidade',
            dados: dados,
          );
          await whatsapp.enviarTexto(
            msg.telefone,
            'Altere a quantidade da última marmita (atual: $quantidade).\nDigite de 1 a ${_intFluxo('quantidade', 'maximo', 20).clamp(1, 50)}.',
          );
        } else {
          await _mostrarTamanhos(msg, dados);
        }
        return;
      case 'recebimento':
        banco.salvarSessao(
          telefone: msg.telefone,
          nome: msg.nome,
          etapa: 'adicionar_outro',
          dados: dados,
        );
        await _mostrarAdicionarOutro(msg);
        return;
      case 'endereco':
        await _mostrarRecebimento(msg, config, dados, permitirPulo: false);
        return;
      case 'pagamento':
        if (dados['recebimento'] == 'entrega') {
          await _mostrarCidadeEntrega(
            msg,
            config,
            dados,
          );
        } else {
          await _mostrarRecebimento(msg, config, dados, permitirPulo: false);
        }
        return;
      case 'troco':
        await _mostrarPagamentos(msg, config, dados, permitirPulo: false);
        return;
      case 'observacao':
        if (dados['pagamento'] == 'dinheiro') {
          await _pedirTroco(msg, dados);
        } else {
          await _mostrarPagamentos(msg, config, dados, permitirPulo: false);
        }
        return;
      case 'confirmacao':
        if (config['permitirObservacoes'] == true) {
          await _pedirObservacao(msg, dados, alterando: true);
        } else if (dados['pagamento'] == 'dinheiro') {
          await _pedirTroco(msg, dados);
        } else {
          await _mostrarPagamentos(msg, config, dados, permitirPulo: false);
        }
        return;
      case 'tamanho':
        final itens = dados['itens'] as List? ?? const [];
        if (itens.isNotEmpty) {
          banco.salvarSessao(
            telefone: msg.telefone,
            nome: msg.nome,
            etapa: 'adicionar_outro',
            dados: dados,
          );
          await _mostrarAdicionarOutro(msg);
        } else {
          _salvarInicioLimpo(msg.telefone, msg.nome);
          await whatsapp.enviarBotoes(
            msg.telefone,
            _textoFluxo('inicio', 'mensagem', 'Escolha uma opção:'),
            _botoesInicio(),
          );
        }
        return;
      case 'inicio':
      default:
        _salvarInicioLimpo(msg.telefone, msg.nome);
        await whatsapp.enviarBotoes(
          msg.telefone,
          _textoFluxo('inicio', 'mensagem', 'Escolha uma opção:'),
          _botoesInicio(),
        );
    }
  }

  Map<String, dynamic> _etapaFluxo(String etapa) {
    final wrapper = banco.obterConfiguracao();
    final config = Map<String, dynamic>.from(wrapper['dados'] as Map? ?? {});
    final fluxo = Map<String, dynamic>.from(config['fluxo'] as Map? ?? {});
    return Map<String, dynamic>.from(fluxo[etapa] as Map? ?? {});
  }

  String _textoFluxo(String etapa, String campo, String fallback) {
    final valor = _etapaFluxo(etapa)[campo]?.toString().trim() ?? '';
    return valor.isEmpty ? fallback : valor;
  }

  bool _boolFluxo(String etapa, String campo, bool fallback) {
    final valor = _etapaFluxo(etapa)[campo];
    return valor is bool ? valor : fallback;
  }

  int _intFluxo(String etapa, String campo, int fallback) {
    final valor = _etapaFluxo(etapa)[campo];
    return valor is num ? valor.toInt() : fallback;
  }

  String _normalizar(String valor) {
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
        .replaceAll(RegExp(r'[^a-z0-9_]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _pagamentoNome(String valor) {
    switch (valor) {
      case 'pix':
        return 'PIX';
      case 'dinheiro':
        return 'Dinheiro';
      case 'cartao':
        return 'Cartão';
      default:
        return valor;
    }
  }
}

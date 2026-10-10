import 'dart:async';
import 'dart:typed_data';

import '../banco/banco.dart';
import '../modelos/mensagem_whatsapp.dart';
import '../util/calculo_pedido.dart';
import '../servicos/whatsapp_service.dart';
import '../servicos/groq_atendimento_service.dart';
import '../util/data_hora.dart';
import '../util/estado_atendimento.dart';

class BotService {
  final Banco banco;
  final WhatsAppService whatsapp;
  final GroqAtendimentoService ia;
  Future<void> _fila = Future<void>.value();

  BotService(this.banco, this.whatsapp, {GroqAtendimentoService? ia})
      : ia = ia ?? GroqAtendimentoService();

  // Serializa as transições. Dentro da transação, WhatsApp apenas persiste a
  // saída; nenhum acesso de rede ocorre com a transação SQLite aberta.
  Future<void> processar(MensagemWhatsApp msg) {
    final atual = _fila.catchError((_) {}).then((_) async {
      var mensagemProcessada = msg;
      String? respostaIA;
      Map<String, dynamic>? pedidoIA;
      String? motivoTransferenciaIA;
      String? tipoInterpretacaoIA;
      var iaFalhou = false;
      final etapaAntes =
          banco.obterSessao(msg.telefone)?['etapa']?.toString() ?? 'inicio';
      try {
        final sessaoAtual = banco.obterSessao(msg.telefone);
        if (!msg.temLocalizacao &&
            msg.ehMidia &&
            sessaoAtual?['modoHumano'] != true) {
          final textoDaMidia = await _interpretarMidia(msg);
          if (textoDaMidia == null) {
            motivoTransferenciaIA = 'midia_nao_processada';
            respostaIA =
                'Recebi sua mídia, mas não consegui interpretá-la com segurança. Encaminhei a conversa para um atendente.';
          } else {
            mensagemProcessada = MensagemWhatsApp(
              id: msg.id,
              telefone: msg.telefone,
              nome: msg.nome,
              texto: textoDaMidia,
              tipo: 'text',
              enviadaEm: msg.enviadaEm,
            );
          }
        }
        final bebidaNoResumo = _modoIaAtivo &&
                sessaoAtual?['etapa'] == 'confirmacao' &&
                !_sessaoExpirou(
                  sessaoAtual,
                  Map<String, dynamic>.from(
                      banco.obterConfiguracao()['dados'] as Map),
                )
            ? _capturarBebidaAdicional(mensagemProcessada.entrada)
            : null;
        if (msg.temLocalizacao || motivoTransferenciaIA != null) {
          // Localização e mídia inconclusiva já têm tratamento determinístico.
          // Não envie essas entradas outra vez para a IA.
        } else if (bebidaNoResumo != null) {
          pedidoIA = {'_adicionarBebidaResumo': bebidaNoResumo};
        } else {
          // A IA precisa receber o conteúdo já transcrito/extraído da mídia.
          // Usar `msg` aqui descartava o áudio ou a imagem e analisava apenas
          // a legenda (ou uma entrada vazia).
          final interpretacao = await _interpretarComIA(mensagemProcessada);
          if (interpretacao != null) {
            banco.log(
              'INFO',
              'ia_interpretacao',
              'etapa=${banco.obterSessao(msg.telefone)?['etapa'] ?? 'inicio'};'
                  'tipo=${interpretacao.tipo};'
                  'motivo=${interpretacao.motivoHumano ?? ''};'
                  'tamanho=${mensagemProcessada.entrada.length}',
            );
            if (interpretacao.tipo == 'pedido') {
              tipoInterpretacaoIA = 'pedido';
              pedidoIA = interpretacao.pedido;
            } else if (interpretacao.tipo == 'humano') {
              tipoInterpretacaoIA = 'humano';
              motivoTransferenciaIA =
                  interpretacao.motivoHumano ?? 'duvida_nao_respondida';
              respostaIA = interpretacao.texto;
            } else if (interpretacao.tipo == 'escolha') {
              tipoInterpretacaoIA = 'escolha';
              mensagemProcessada = MensagemWhatsApp(
                id: msg.id,
                telefone: msg.telefone,
                nome: msg.nome,
                texto: interpretacao.texto,
                enviadaEm: msg.enviadaEm,
              );
            } else if (!_textoIaRepeteCliente(
                interpretacao.texto, mensagemProcessada.entrada)) {
              tipoInterpretacaoIA = interpretacao.tipo;
              respostaIA = interpretacao.texto;
            }
          }
        }
      } catch (e) {
        // A IA é opcional: falha de rede/cota usa a entrada original no fluxo
        // determinístico, sem deixar a mensagem presa na fila.
        final detalhe =
            e is HttpExceptionSeguro ? e.message : e.runtimeType.toString();
        banco.log('WARN', 'ia_indisponivel_fallback_bot', detalhe);
        iaFalhou = true;
      }
      if (motivoTransferenciaIA != null) {
        banco.definirModoHumano(
          msg.telefone,
          true,
          preservarDados: true,
          origem: 'ia',
          motivo: motivoTransferenciaIA,
        );
      }
      banco.db.execute('BEGIN IMMEDIATE');
      try {
        await _processarInterno(
          mensagemProcessada,
          respostaIA: respostaIA,
          pedidoIA: pedidoIA,
        );
        final etapaDepois =
            banco.obterSessao(msg.telefone)?['etapa']?.toString() ?? 'inicio';
        _registrarDiagnosticoConversa(
          mensagemProcessada,
          etapaAntes: etapaAntes,
          etapaDepois: etapaDepois,
          tipoIa: tipoInterpretacaoIA,
          motivoTransferencia: motivoTransferenciaIA,
          pedidoIa: pedidoIA,
          iaFalhou: iaFalhou,
        );
        _registrarHistoricoIa(mensagemProcessada);
        banco.db.execute('DELETE FROM webhook_entrada WHERE id = ?', [msg.id]);
        banco.db.execute('COMMIT');
        if (motivoTransferenciaIA != null && respostaIA != null) {
          await whatsapp.enviarTexto(msg.telefone, respostaIA);
        }
      } catch (e) {
        banco.db.execute('ROLLBACK');
        banco.log('ERROR', 'bot_transacao_desfeita', e.runtimeType.toString());
        rethrow;
      }
    });
    _fila = atual;
    return atual;
  }

  void _registrarHistoricoIa(MensagemWhatsApp msg) {
    if (msg.entrada.isEmpty) return;
    final sessao = banco.obterSessao(msg.telefone);
    if (sessao == null || sessao['modoHumano'] == true) return;
    final dados = Map<String, dynamic>.from(sessao['dados'] as Map? ?? {});
    final historico = (dados['historicoIa'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    historico.add({
      'texto': _sanitizarMensagemParaIa(msg.entrada).substring(
        0,
        _sanitizarMensagemParaIa(msg.entrada).length.clamp(0, 240),
      ),
      'etapa': sessao['etapa']?.toString() ?? 'inicio',
      'em': agoraIso(),
    });
    if (historico.length > 6) {
      historico.removeRange(0, historico.length - 6);
    }
    dados['historicoIa'] = historico;
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: sessao['nome'] as String?,
      etapa: sessao['etapa']?.toString() ?? 'inicio',
      dados: dados,
      modoHumano: false,
    );
  }

  Future<void> retomarAtendimentoHumano(String telefone) async {
    final anterior = _fila;
    final atual = anterior.catchError((_) {}).then((_) async {
      final sessaoAnterior = banco.obterSessao(telefone);
      final nome = sessaoAnterior?['nome']?.toString() ?? 'Cliente';
      banco.retomarModoAutomatico(telefone);

      final config = Map<String, dynamic>.from(
        banco.obterConfiguracao()['dados'] as Map,
      );
      if (config['botAtivo'] == false) return;
      final estado = _estadoEfetivo(config);
      if (estado == 'atendendo') {
        _salvarInicioLimpo(
          telefone,
          nome,
          boasVindasNaProximaMensagem: true,
        );
        return;
      }

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
    });
    _fila = atual;
    await atual;
  }

  Future<InterpretacaoAtendimento?> _interpretarComIA(
    MensagemWhatsApp msg,
  ) async {
    if (msg.respostaId != null || msg.entrada.isEmpty) return null;
    final mensagensAnteriores = banco.db.select(
      'SELECT status FROM mensagens_processadas WHERE id = ?',
      [msg.id],
    );
    if (mensagensAnteriores.any((row) => row['status'] == 'done')) return null;
    final wrapper = banco.obterConfiguracao();
    final config = Map<String, dynamic>.from(wrapper['dados'] as Map);
    if (config['modoAtendimento'] != 'ia' ||
        config['botAtivo'] == false ||
        _estadoEfetivo(config) != 'atendendo') {
      return null;
    }
    final sessao = banco.obterSessao(msg.telefone);
    if (sessao?['modoHumano'] == true || _sessaoExpirou(sessao, config)) {
      return null;
    }
    final trocaEntreCategorias =
        _respostaTrocaEntreCategorias(msg.entrada, banco.obterCardapio());
    if (trocaEntreCategorias != null) {
      return InterpretacaoAtendimento('duvida', trocaEntreCategorias);
    }
    if (_ehConsultaStatusPedido(msg.entrada)) {
      return InterpretacaoAtendimento(
        'duvida',
        _resumirPedidoEmAndamento(sessao),
      );
    }
    if (!ia.configurado) return null;
    final entrada = _normalizar(msg.entrada);
    if (_ehSaudacaoSimples(entrada) ||
        _ehNegacaoPedido(entrada) ||
        _ehAgradecimentoSimples(entrada) ||
        _ehDesistenciaExplicita(entrada) ||
        (_ehReclamacao(entrada)) ||
        ((_ehElogioOuComentarioPositivo(entrada) || _ehIndecisao(entrada)) &&
            !_mensagemPedeAcaoNoPedido(entrada)) ||
        _ehSolicitacaoCardapio(entrada) ||
        RegExp(r'^[\s?!.…]+$').hasMatch(msg.entrada)) {
      return null;
    }
    if (sessao?['etapa']?.toString() == 'ia_pedido' &&
        (_ehPararDeAdicionarMarmitas(entrada) ||
            RegExp(r'^e so essa(s)?$').hasMatch(entrada))) {
      return const InterpretacaoAtendimento('escolha', 'so essa');
    }
    final respostaConhecida = _responderPerguntaConhecida(
      entrada,
      config,
      sessao,
      msg.telefone,
      msg.nome,
    );
    if (respostaConhecida != null) {
      return InterpretacaoAtendimento('duvida', respostaConhecida);
    }
    final etapaAtual = sessao?['etapa']?.toString() ?? 'inicio';
    if (etapaAtual == 'inicio' &&
        _ehPedidoDeUmaMarmitaSemDetalhes(msg.entrada)) {
      return const InterpretacaoAtendimento(
        'pedido',
        '',
        pedido: {
          'itens': [
            {'indice': 1, 'quantidade': 1}
          ],
          'finalizarItens': false,
        },
      );
    }
    if (etapaAtual == 'adicionar_outro') {
      final cardapioAtual = banco.obterCardapio();
      final mencionaOpcao = [
        ..._itensAtivos(cardapioAtual, 'tamanhos'),
        ..._itensAtivos(cardapioAtual, 'misturas'),
        ..._itensAtivos(cardapioAtual, 'acompanhamentos'),
      ].any((opcao) => _resolverOpcaoNatural(msg.entrada, [opcao]) != null);
      if (!mencionaOpcao &&
          (_ehNegacaoOpcional(entrada) || _ehFinalizacaoItens(entrada))) {
        return const InterpretacaoAtendimento('escolha', 'outro_nao');
      }
      if (!mencionaOpcao && _ehIntencaoOutraMarmita(entrada)) {
        return const InterpretacaoAtendimento('escolha', 'outro_sim');
      }
    }
    if (etapaAtual == 'confirmacao') {
      if (_ehConfirmacaoDoResumo(entrada)) {
        return const InterpretacaoAtendimento('escolha', 'conf_confirmar');
      }
      if (_ehRecusaDeAdicionarMarmita(entrada)) {
        return const InterpretacaoAtendimento(
          'escolha',
          'confirmacao_sem_adicionar_marmita',
        );
      }
      if (_ehPedidoRemocaoUnitariaMarmita(entrada)) return null;
      if (!_ehComandoCancelar(entrada) && _ehNegacaoOpcional(entrada)) {
        return const InterpretacaoAtendimento(
          'duvida',
          'Sem problemas! O que você gostaria de alterar? Posso refazer o '
              'pedido, trocar um item ou cancelar.',
        );
      }
      if (_ehComandoCancelar(entrada) || !_ehPerguntaExplicita(entrada)) {
        // Declarações e alterações seguem pelo tratador determinístico do
        // resumo. Somente perguntas seguem à IA; sua saída abaixo é limitada
        // a dúvidas e não pode executar confirmações.
        return null;
      }
    }
    if (etapaAtual == 'confirmar_cancelamento') {
      if (_ehNegacaoOpcional(entrada)) {
        return const InterpretacaoAtendimento('escolha', 'cancelar_nao');
      }
      if (_ehIntencaoConfirmarCancelamento(entrada)) {
        return const InterpretacaoAtendimento('escolha', 'cancelar_sim');
      }
      return const InterpretacaoAtendimento(
        'duvida',
        'Para cancelar, diga “sim, cancelar pedido”. Se quiser continuar, diga “não”.',
      );
    }
    if (etapaAtual == 'ia_pedido') {
      final recusaEscolhaExtra =
          _capturarRecusaEscolhaExtra(msg.entrada, sessao);
      if (recusaEscolhaExtra != null) {
        return InterpretacaoAtendimento(
          'pedido',
          '',
          pedido: {
            'itens': [recusaEscolhaExtra],
            'finalizarItens': false,
          },
        );
      }
      final conflito = _perguntarSobreTrocaDeMistura(
        msg.entrada,
        sessao,
      );
      if (conflito != null) {
        return InterpretacaoAtendimento('duvida', conflito);
      }
      final correcao = _interpretarCorrecaoDeItem(msg.entrada, sessao);
      if (correcao != null) {
        return InterpretacaoAtendimento(
          'pedido',
          '',
          pedido: {
            'itens': [correcao],
            'finalizarItens': false,
          },
        );
      }
      final compostas = _capturarOpcoesPedidoCompostas(msg.entrada, sessao);
      if (compostas != null) {
        return InterpretacaoAtendimento(
          'pedido',
          '',
          pedido: {'itens': compostas, 'finalizarItens': false},
        );
      }
      final tamanhos = _capturarTamanhosPedido(msg.entrada, sessao);
      if (tamanhos != null) {
        return InterpretacaoAtendimento(
          'pedido',
          '',
          pedido: {'itens': tamanhos, 'finalizarItens': false},
        );
      }
      final capturaDireta = _capturarOpcaoPedidoCurta(msg.entrada, sessao);
      if (capturaDireta != null) {
        return InterpretacaoAtendimento(
          'pedido',
          '',
          pedido: {
            'itens': [capturaDireta],
            'finalizarItens': false,
          },
        );
      }
      final quantidadePendente =
          _capturarQuantidadePendente(msg.entrada, sessao);
      if (quantidadePendente != null) {
        return InterpretacaoAtendimento(
          'pedido',
          '',
          pedido: {
            'itens': [quantidadePendente],
            'finalizarItens': false,
          },
        );
      }
    }
    final campoLivre = const {'endereco', 'observacao'}.contains(etapaAtual);
    final perguntaSegura =
        campoLivre ? _extrairPerguntaSemDadosPessoais(msg.entrada) : null;
    final perguntaDeEtapaLivre = perguntaSegura != null ||
        (etapaAtual == 'endereco' && _ehPerguntaQueNaoEhEndereco(msg.entrada));
    if (campoLivre && !perguntaDeEtapaLivre) return null;
    final opcoesDiretasEtapa = const {
      'tamanho',
      'arroz',
      'feijao',
      'mistura',
      'acompanhamento',
      'bebida',
      'cidade_entrega',
      'pagamento',
      'recebimento',
    }.contains(etapaAtual)
        ? _opcoesEtapaIA(etapaAtual, sessao, config)
        : const <Map<String, String>>[];
    if (opcoesDiretasEtapa.isNotEmpty && !_ehPerguntaExplicita(entrada)) {
      final opcaoEscolhida = etapaAtual == 'tamanho'
          ? _resolverTamanhoOpcaoTexto(msg.entrada, opcoesDiretasEtapa)
          : _resolverOpcaoTexto(msg.entrada, opcoesDiretasEtapa);
      if (opcaoEscolhida != null) {
        return InterpretacaoAtendimento('escolha', opcaoEscolhida['valor']!);
      }
    }
    final etapaComOpcoesDeterministicas = const {
      'tamanho',
      'arroz',
      'feijao',
      'mistura',
      'acompanhamento',
      'bebida',
      'cidade_entrega',
      'pagamento',
      'recebimento',
    }.contains(etapaAtual);
    final quantidadeDireta =
        const {'quantidade', 'quantidade_bebida'}.contains(etapaAtual) &&
            _parseQuantidade(entrada) != null;
    final trocoDireto = etapaAtual == 'troco' &&
        (_parseValorMonetario(entrada) != null ||
            _ehNegacaoOpcional(entrada) ||
            _ehConfirmacaoOpcional(entrada));
    if (quantidadeDireta ||
        trocoDireto ||
        _ehComandoAjuda(entrada) ||
        _ehComandoHumano(entrada) ||
        _ehComandoCancelar(entrada) ||
        _ehComandoVoltar(entrada) ||
        _ehComandoCorrigir(entrada) ||
        (sessao?['etapa'] == 'inicio' &&
            _resolverOpcaoInicio(entrada) == 'inicio_humano') ||
        (sessao?['etapa'] == 'inicio' &&
            _resolverOpcaoInicio(entrada) == 'inicio_cardapio') ||
        (etapaComOpcoesDeterministicas &&
            _opcoesEtapaIA(etapaAtual, sessao, config)
                .any((opcao) => _normalizar(opcao['nome'] ?? '') == entrada)) ||
        (_resolverOpcaoInicio(entrada) != null &&
            _resolverOpcaoInicio(entrada) != 'inicio_pedido')) {
      return null;
    }

    final cardapio = banco.obterCardapio();
    final opcoesMenu = <String, dynamic>{};
    for (final chave in [
      'tamanhos',
      'misturas',
      'acompanhamentos',
      'bebidas',
      'arrozes',
      'feijoes'
    ]) {
      final fluxoDesativado =
          (chave == 'arrozes' && cardapio['fluxoArrozAtivo'] != true) ||
              (chave == 'feijoes' && cardapio['fluxoFeijaoAtivo'] != true);
      opcoesMenu[chave] = fluxoDesativado
          ? const []
          : (cardapio[chave] as List? ?? const [])
              .where((item) => item is Map && item['ativo'] == true)
              .map((item) {
              final opcao = item as Map;
              return {
                'nome': opcao['nome'],
                if (opcao['preco'] is num) 'preco': opcao['preco'],
                if (chave == 'tamanhos') ...{
                  'quantidadeMisturas': opcao['quantidadeMisturas'] ?? 1,
                  'quantidadeAcompanhamentos':
                      opcao['quantidadeAcompanhamentos'] ?? 1,
                },
              };
            }).toList();
    }
    final etapa = sessao?['etapa']?.toString() ?? 'inicio';
    final contexto = <String, dynamic>{
      'estabelecimento': config['nomeEstabelecimento'],
      'baseIncluidaEmTodasAsMarmitas': _descricaoBase(cardapio),
      'saladaIncluida': config['saladaIncluida'] == true,
      'descricaoSalada': config['descricaoSalada'],
      'opcoesCardapio': opcoesMenu,
      'entregaAtiva': config['entregaAtiva'] == true,
      'retiradaAtiva': config['retiradaAtiva'] == true,
      'estadoAtendimento': _estadoEfetivo(config),
      'horarioAutomatico': config['usarHorarioAutomatico'] == true,
      'horarios': config['horarios'],
      'mensagensAtendimento': {
        'fechado': (config['mensagens'] as Map?)?['fechado'],
        'pausado': (config['mensagens'] as Map?)?['pausado'],
        'esgotado': (config['mensagens'] as Map?)?['esgotado'],
      },
      'cidadesAtendidas': _cidadesAtendidasConhecidas(),
      'formasPagamento': _opcoesPagamento(config)
          .where((opcao) => _pagamentoAtivo(
                config,
                opcao['id'] == 'pag_pix'
                    ? 'pix'
                    : opcao['id'] == 'pag_dinheiro'
                        ? 'dinheiro'
                        : opcao['id'] == 'pag_credito'
                            ? 'credito'
                            : 'debito',
              ))
          .map((opcao) => opcao['titulo'])
          .toList(),
      'enderecoRetirada': config['enderecoRetirada'],
      if (_pagamentoAtivo(config, 'pix') &&
          (config['chavePix']?.toString().trim().isNotEmpty ?? false)) ...{
        'chavePix': config['chavePix'],
        'nomePix': config['nomePix'],
      },
      'fluxoArrozAtivo': cardapio['fluxoArrozAtivo'] == true,
      'fluxoFeijaoAtivo': cardapio['fluxoFeijaoAtivo'] == true,
      'rascunhoPedidoAtual':
          (sessao?['dados'] as Map?)?['rascunhoPedidoIA'] ?? const {},
      'historicoRecente':
          (sessao?['dados'] as Map?)?['historicoIa'] ?? const [],
      'etapaAtual': etapa,
      'opcoesDaEtapa': _opcoesEtapaIA(etapa, sessao, config),
    };
    final interpretacao = await ia.interpretar(
      mensagem: campoLivre
          ? (perguntaSegura ?? _sanitizarMensagemParaIa(msg.entrada))
          : _sanitizarMensagemParaIa(msg.entrada),
      etapa: etapa,
      contexto: contexto,
    );
    if (etapa == 'confirmacao' && interpretacao != null) {
      if (interpretacao.tipo == 'duvida') return interpretacao;
      return const InterpretacaoAtendimento(
        'duvida',
        'Para confirmar, diga “sim, confirmar pedido”. Se quiser alterar algo, me diga o que devo mudar.',
      );
    }
    return interpretacao;
  }

  String? _responderPerguntaConhecida(
    String entrada,
    Map<String, dynamic> config,
    Map<String, dynamic>? sessao,
    String telefone,
    String nome,
  ) {
    if (_cidadeMencionada(entrada) != null &&
        (_contemTermo(entrada, ['entrega', 'taxa', 'cobra']) ||
            _parecePerguntaDoCliente(entrada))) {
      final dados = Map<String, dynamic>.from(
        (sessao?['dados'] as Map?)?.cast<String, dynamic>() ?? const {},
      )..['contextoPerguntaConhecida'] = entrada;
      if (sessao != null) {
        banco.salvarSessao(
          telefone: telefone,
          nome: sessao['nome'] as String? ?? nome,
          etapa: sessao['etapa'] as String? ?? 'inicio',
          dados: dados,
          modoHumano: sessao['modoHumano'] == true,
        );
      }
    }
    final mencionaCardapio = _contemTermo(entrada, ['cardapio', 'menu']);
    final perguntaSobreVariacao = mencionaCardapio &&
        _contemTermo(entrada, [
          'diferente',
          'muda',
          'mudam',
          'variavel',
          'varia',
          'todo dia',
          'cada dia',
          'diariamente',
        ]);
    if (perguntaSobreVariacao) {
      return 'Sim 😊 O cardápio muda a cada dia.';
    }

    final perguntaCidadesAtendidas =
        _contemTermo(entrada, ['cidade', 'cidades']) &&
            _contemTermo(entrada, [
              'atende',
              'atendem',
              'atendida',
              'atendidas',
              'entrega',
              'entregam',
              'entregamos',
            ]);
    if (perguntaCidadesAtendidas) {
      return _textoCidadesComTaxa();
    }

    final perguntaTaxa = _contemTermo(entrada, [
          'taxa',
          'taxas',
          'cobra',
          'cobram',
          'custo',
          'valor da entrega',
          'preco da entrega',
        ]) ||
        (_ehPerguntaIsoladaDeValor(entrada) &&
            _cidadeContextual(sessao) != null);
    final cidade = _cidadeMencionada(entrada) ??
        (_ehPerguntaIsoladaDeValor(entrada) ? _cidadeContextual(sessao) : null);
    if (perguntaTaxa) {
      if (config['entregaAtiva'] != true) {
        return 'No momento não estamos fazendo entregas.';
      }
      if (cidade != null) {
        final taxa = (cidade['taxa'] as num?)?.toDouble();
        if (taxa == null || taxa < 0) return null;
        return 'A taxa de entrega para ${cidade['nome']} é ${moeda(taxa)}.';
      }
      return _textoCidadesComTaxa();
    }

    final perguntaEntrega = _contemTermo(
          entrada,
          ['entrega', 'entregam', 'entregar', 'delivery'],
        ) &&
        _parecePerguntaDoCliente(entrada);
    if (perguntaEntrega) {
      if (config['entregaAtiva'] != true) {
        return 'No momento não estamos fazendo entregas.';
      }
      if (cidade != null) {
        final taxa = (cidade['taxa'] as num?)?.toDouble();
        final taxaTexto =
            taxa == null || taxa < 0 ? '' : ' A taxa é ${moeda(taxa)}.';
        return 'Sim, entregamos em ${cidade['nome']}!$taxaTexto';
      }
      return cidade == null
          ? '${_textoCidadesComTaxa()} Qual é a sua cidade?'
          : 'Entregamos em ${cidade['nome']}. Qual é o seu endereço?';
    }

    final perguntaRetirada = _contemTermo(
          entrada,
          ['retirada', 'retirar', 'retira', 'buscar', 'busca'],
        ) &&
        _parecePerguntaDoCliente(entrada);
    if (perguntaRetirada) {
      if (config['retiradaAtiva'] != true) {
        return 'No momento não estamos aceitando retirada.';
      }
      final endereco = config['enderecoRetirada']?.toString().trim() ?? '';
      return endereco.isEmpty ? null : 'A retirada é em $endereco.';
    }

    final perguntaPagamento = _contemTermo(
          entrada,
          [
            'pix',
            'pagamento',
            'pagar',
            'cartao',
            'credito',
            'debito',
            'dinheiro',
          ],
        ) &&
        _parecePerguntaDoCliente(entrada);
    if (perguntaPagamento) {
      final pagamentos = _opcoesPagamento(config);
      final forma = _normalizar(entrada);
      final ids = <String, String>{
        'pix': 'pag_pix',
        'dinheiro': 'pag_dinheiro',
        'credito': 'pag_credito',
        'debito': 'pag_debito',
      };
      final mencionados = ids.entries
          .where((entry) => _contemTermo(forma, [entry.key]))
          .toList();
      if (mencionados.length == 1) {
        final id = mencionados.single.value;
        final ativa = pagamentos.any((opcao) => opcao['id'] == id);
        if (!ativa) return 'No momento não aceitamos essa forma de pagamento.';
        if (id == 'pag_pix' && _contemTermo(forma, ['chave', 'copia e cola'])) {
          final chave = config['chavePix']?.toString().trim() ?? '';
          return chave.isEmpty
              ? 'Ainda não tenho uma chave Pix disponível para informar. Posso chamar um atendente.'
              : 'A chave Pix é: $chave';
        }
        final titulo =
            pagamentos.firstWhere((opcao) => opcao['id'] == id)['titulo'];
        return 'Sim, aceitamos $titulo.';
      }
      return pagamentos.isEmpty
          ? 'Ainda não há formas de pagamento configuradas. Posso chamar um atendente.'
          : 'Você pode pagar com ${_juntarEmPortugues(pagamentos.map((opcao) => opcao['titulo']!).toList())}.';
    }

    final cardapio = banco.obterCardapio();
    if (_parecePerguntaDoCliente(entrada)) {
      final perguntaDisponibilidade = _contemTermo(
        entrada,
        ['tem', 'vende', 'disponivel', 'disponiveis', 'acabou'],
      );
      final perguntaPreco = _contemTermo(
        entrada,
        ['preco', 'custa', 'valor', 'quanto'],
      );
      for (final tipo in const [
        ('tamanhos', 'tamanho'),
        ('misturas', 'mistura'),
        ('acompanhamentos', 'acompanhamento'),
        ('bebidas', 'bebida'),
      ]) {
        for (final opcao
            in (cardapio[tipo.$1] as List? ?? const []).whereType<Map>()) {
          final nome = opcao['nome']?.toString() ?? '';
          final palavras = _normalizar(nome)
              .split(' ')
              .where((palavra) => palavra.length >= 4);
          if (!palavras.any((palavra) =>
              RegExp('\\b${RegExp.escape(palavra)}\\b')
                  .hasMatch(_normalizar(entrada)))) {
            continue;
          }
          if (perguntaPreco && tipo.$1 == 'tamanhos') {
            final preco = opcao['preco'];
            return preco is num
                ? '$nome custa ${moeda(preco.toDouble())}.'
                : null;
          }
          if (perguntaDisponibilidade) {
            return opcao['ativo'] == true
                ? 'Sim, $nome está disponível.'
                : 'No momento, $nome não está disponível.';
          }
        }
      }
    }

    return null;
  }

  bool _ehPerguntaIsoladaDeValor(String entrada) => RegExp(
        r'^(?:(?:e )?quanto(?: que)? (?:fica|e|custa|da|vai dar)|qual (?:o )?valor|e a taxa|quanto mesmo)(?:\\?)?$',
      ).hasMatch(_normalizarIntencao(entrada));

  Map<String, dynamic>? _cidadeContextual(
    Map<String, dynamic>? sessao,
  ) {
    final dados = sessao?['dados'];
    if (dados is! Map) return null;
    final contexto = dados['contextoPerguntaConhecida'];
    if (contexto is! String) return null;
    return _cidadeMencionada(_normalizar(contexto));
  }

  Map<String, dynamic>? _cidadeMencionada(String entrada) {
    for (final cidade in _cidadesAtendidasConhecidas()) {
      final nomes = <String>{
        cidade['nome'].toString(),
        ...((cidade['aliases'] as List? ?? const [])
            .map((alias) => alias.toString())),
      };
      final bateCidade = nomes.any((nomeBusca) {
        final normalizado = _normalizar(nomeBusca);
        if (normalizado.isEmpty) return false;
        final primeiroNome = normalizado.split(' ').first;
        return entrada.contains(normalizado) ||
            RegExp('\\b${RegExp.escape(primeiroNome)}\\b').hasMatch(entrada);
      });
      if (bateCidade) return cidade;
    }
    return null;
  }

  List<Map<String, dynamic>> _cidadesAtendidasConhecidas() {
    final dados = banco.obterConfiguracao()['dados'] as Map? ?? const {};
    return (dados['cidadesEntrega'] as List? ?? const [])
        .whereType<Map>()
        .map((cidade) => Map<String, dynamic>.from(cidade))
        .where((cidade) =>
            cidade['ativa'] == true &&
            (cidade['nome']?.toString().trim().isNotEmpty ?? false))
        .toList();
  }

  String _textoCidadesComTaxa() {
    final cidades = _cidadesAtendidasConhecidas();
    if (cidades.isEmpty) {
      return 'Não há cidades disponíveis para entrega no momento.';
    }
    final nomes = cidades.map((cidade) {
      final nome = cidade['nome'].toString();
      final taxa = (cidade['taxa'] as num?)?.toDouble();
      return taxa == null || taxa < 0 ? nome : '$nome (taxa ${moeda(taxa)})';
    }).toList();
    return 'Atendemos em ${nomes.join(' e ')}.';
  }

  bool _parecePerguntaDoCliente(String entrada) {
    if (entrada.contains('?')) return true;
    return RegExp(
      r'^(?:(?:voces|vcs|voce|vc)\s+)?(?:entregam|entrega|entregar|aceita|aceitam|tem|vende|vendem|qual|quais|quanto|como|onde|pode|posso|fazem|consegue)\b',
    ).hasMatch(_normalizarIntencao(entrada));
  }

  String _juntarEmPortugues(List<String> valores) {
    if (valores.length < 2) return valores.join();
    if (valores.length == 2) return '${valores[0]} e ${valores[1]}';
    return '${valores.sublist(0, valores.length - 1).join(', ')} e ${valores.last}';
  }

  String? _extrairPerguntaSemDadosPessoais(String entrada) {
    final indicePergunta = entrada.lastIndexOf('?');
    final antesDaPergunta =
        indicePergunta < 0 ? entrada : entrada.substring(0, indicePergunta);
    final partes = antesDaPergunta.split(
      RegExp(r'[,;.!?\n]|\s+(?:e|mas|porem|por[eé]m)\s+', caseSensitive: false),
    );
    var pergunta = partes.last.trim();
    pergunta = pergunta.replaceFirst(
      RegExp(r'^(?:(?:e|mas|porem|por[eé]m)\s+)+', caseSensitive: false),
      '',
    );
    final normalizada = _normalizar(pergunta);
    if (normalizada.length < 3 ||
        !RegExp(
          r'^(?:voces|voce|vc|vcs|quanto|qual|quais|que|como|onde|quando|aceita|aceitam|tem|faz|funciona|pode|posso|entrega|entregam|taxa|a taxa|o cardapio|a entrega|o pagamento|pix|cartao|todo dia|sempre|sera que|e verdade|porque|pq)\b',
        ).hasMatch(normalizada)) {
      return null;
    }
    return '$pergunta?';
  }

  String _sanitizarMensagemParaIa(String entrada) {
    var segura = entrada.replaceAll(
      RegExp(
        r'\b(?:rua|avenida|av\.?|travessa|alameda|estrada|rodovia|bairro|endereco|referencia)\b[\s\S]*',
        caseSensitive: false,
      ),
      '[dados de endereço omitidos]',
    );
    segura = segura.replaceAll(
      RegExp(r'\b(?:observacao|obs\.?)\s*[:=-][\s\S]*', caseSensitive: false),
      '[observação omitida]',
    );
    return segura;
  }

  Future<void> _processarPedidoIA(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic>? sessao,
    Map<String, dynamic> captura,
  ) async {
    final dados = Map<String, dynamic>.from(sessao?['dados'] as Map? ?? {});
    final observacaoNoPedido = _extrairObservacaoNoMeioDoPedido(msg.entrada);
    if (observacaoNoPedido != null) {
      dados['observacao'] = observacaoNoPedido;
    }
    // Retomar pelo painel é silencioso. A primeira mensagem seguinte é entrada
    // real do cliente e não deve deixar o marcador preso no rascunho.
    if (dados.remove('aguardaBoasVindas') == true) {
      dados['boasVindasEnviada'] = true;
    }
    dados.putIfAbsent('clienteNome', () => msg.nome);
    dados.putIfAbsent('itens', () => <dynamic>[]);
    if ((sessao == null ||
            ((sessao['dados'] as Map?)?['boasVindasEnviada'] != true &&
                (sessao['dados'] as Map?)?['aguardaBoasVindas'] != true)) &&
        config['modoAtendimento'] == 'ia') {
      await whatsapp.enviarTexto(msg.telefone, _saudacaoIa());
      dados['boasVindasEnviada'] = true;
    }

    final cardapio = banco.obterCardapio();
    final rascunho = Map<String, dynamic>.from(
      dados['rascunhoPedidoIA'] as Map? ?? const {},
    );
    final rascunhoAnterior = (rascunho['itens'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final itens = <Map<String, dynamic>>[];
    for (final raw in (dados['itens'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final misturas = item['misturaNomes'] is List
          ? List<String>.from(item['misturaNomes'] as List)
          : [if (item['misturaNome'] != null) item['misturaNome'].toString()];
      final acompanhamentos = item['acompanhamentoNomes'] is List
          ? List<String>.from(item['acompanhamentoNomes'] as List)
          : [
              if (item['acompanhamentoNome'] != null)
                item['acompanhamentoNome'].toString()
            ];
      itens.add({
        'indice': itens.length + 1,
        'tamanho': item['tamanhoNome'],
        'quantidade': item['quantidade'],
        'quantidadeMisturas': item['quantidadeMisturas'] ?? 1,
        'quantidadeAcompanhamentos': item['quantidadeAcompanhamentos'] ?? 1,
        'misturas': misturas,
        if (misturas.isNotEmpty) 'mistura': misturas.first,
        'acompanhamentos': acompanhamentos,
        if (acompanhamentos.isNotEmpty) 'acompanhamento': acompanhamentos.first,
        'arroz': item['arrozNome'],
        'feijao': item['feijaoNome'],
      });
    }
    if (rascunhoAnterior.isNotEmpty) {
      if (itens.isEmpty) {
        itens.addAll(rascunhoAnterior);
      } else {
        String chave(Map<String, dynamic> linha) => [
              _normalizar(linha['tamanho']?.toString() ?? ''),
              _valoresEscolhidosRascunho(linha, 'misturas', 'mistura')
                  .map(_normalizar)
                  .join(','),
              _valoresEscolhidosRascunho(
                linha,
                'acompanhamentos',
                'acompanhamento',
              ).map(_normalizar).join(','),
              _normalizar(linha['arroz']?.toString() ?? ''),
              _normalizar(linha['feijao']?.toString() ?? ''),
            ].join('|');
        final presentes = itens.map(chave).toSet();
        for (final linha in rascunhoAnterior) {
          if (_rascunhoItemCompleto(
            Map<String, dynamic>.from(linha),
            arrozAtivo: cardapio['fluxoArrozAtivo'] == true,
            feijaoAtivo: cardapio['fluxoFeijaoAtivo'] == true,
          )) {
            continue;
          }
          if (presentes.add(chave(linha))) itens.add(linha);
        }
      }
      for (var i = 0; i < itens.length; i++) {
        itens[i]['indice'] = i + 1;
      }
    }
    final totalSolicitado = _extrairTotalMarmitas(msg.entrada);
    if (totalSolicitado != null) {
      rascunho['quantidadeTotalSolicitada'] = totalSolicitado;
    }
    final atualizacoes = captura['itens'];
    final temAtualizacaoDeItem = atualizacoes is List &&
        atualizacoes.whereType<Map>().any((item) => const [
              'tamanho',
              'quantidade',
              'mistura',
              'misturas',
              'acompanhamento',
              'acompanhamentos',
              'arroz',
              'feijao',
              'quantidadeMisturasDesejada',
              'quantidadeAcompanhamentosDesejada',
            ].any((campo) =>
                item[campo] != null &&
                item[campo].toString().trim().isNotEmpty));
    if (atualizacoes is List) {
      for (final original in atualizacoes.whereType<Map>()) {
        final raw = _corrigirCamposEscolhasIA(
          Map<String, dynamic>.from(original),
          cardapio,
        );
        final indiceRaw = raw['indice'];
        var indice = indiceRaw is num ? indiceRaw.toInt() : 0;
        if (indice < 1) {
          indice = itens.indexWhere((item) => !_rascunhoItemCompleto(
                    item,
                    arrozAtivo: cardapio['fluxoArrozAtivo'] == true,
                    feijaoAtivo: cardapio['fluxoFeijaoAtivo'] == true,
                  )) +
              1;
          if (indice < 1) indice = itens.length + 1;
        }
        if (indice > 20) continue;
        while (itens.length < indice) {
          itens.add({'indice': itens.length + 1});
        }
        final destino = itens[indice - 1];
        for (final campo in const [
          'quantidadeMisturasDesejada',
          'quantidadeAcompanhamentosDesejada',
        ]) {
          final valor = raw[campo];
          final quantidade =
              valor is num ? valor.toInt() : int.tryParse('$valor');
          if (quantidade != null && quantidade >= 1 && quantidade <= 5) {
            destino[campo] = quantidade;
          }
        }
        final substituirCampo = raw['substituirCampo']?.toString();
        if (substituirCampo != null &&
            (substituirCampo == 'mistura' ||
                substituirCampo == 'acompanhamento')) {
          final plural = '${substituirCampo}s';
          final escolhasAtuais = _valoresEscolhidosRascunho(
            destino,
            plural,
            substituirCampo,
          );
          final indiceSubstituido = raw['substituirIndice'] is num
              ? (raw['substituirIndice'] as num).toInt()
              : -1;
          if (indiceSubstituido >= 0 &&
              indiceSubstituido < escolhasAtuais.length) {
            escolhasAtuais.removeAt(indiceSubstituido);
            destino[plural] = escolhasAtuais;
            destino[substituirCampo] =
                escolhasAtuais.isEmpty ? null : escolhasAtuais.first;
          } else {
            destino[plural] = <String>[];
            destino[substituirCampo] = null;
          }
        }
        for (final escolha in const [
          ('mistura', 'misturas', 'mistura'),
          ('acompanhamento', 'acompanhamentos', 'acompanhamento'),
        ]) {
          final rawPlural = raw[escolha.$2];
          final recebidas = rawPlural is List
              ? rawPlural.map((valor) => valor.toString().trim()).toList()
              : <String>[];
          final rawSingular = raw[escolha.$1];
          if (rawSingular is String && rawSingular.trim().isNotEmpty) {
            recebidas.add(rawSingular.trim());
          }
          if (recebidas.isEmpty) continue;
          final existentes = _valoresEscolhidosRascunho(
            destino,
            escolha.$2,
            escolha.$3,
          );
          final novas = <String>[...existentes];
          var indiceInsercao = raw['substituirCampo'] == escolha.$1 &&
                  raw['substituirIndice'] is num
              ? (raw['substituirIndice'] as num).toInt()
              : -1;
          for (final valor in recebidas.where((valor) => valor.isNotEmpty)) {
            if (indiceInsercao >= 0 && indiceInsercao <= novas.length) {
              novas.insert(indiceInsercao, valor);
              indiceInsercao++;
            } else {
              novas.add(valor);
            }
          }
          final unicas = novas.toSet().take(5).toList();
          destino[escolha.$2] = unicas;
          destino[escolha.$3] = unicas.isEmpty ? null : unicas.first;
        }
        for (final campo in const [
          'tamanho',
          'quantidade',
          'arroz',
          'feijao',
        ]) {
          final valor = raw[campo];
          if (valor == null || valor.toString().trim().isEmpty) continue;
          if (campo == 'quantidade') {
            final quantidade = valor is num && valor == valor.toInt()
                ? valor.toInt()
                : int.tryParse(valor.toString());
            if (quantidade != null && quantidade >= 1 && quantidade <= 50) {
              destino[campo] = quantidade;
            }
          } else if (valor is String && valor.trim().length <= 100) {
            if ((campo == 'arroz' && cardapio['fluxoArrozAtivo'] != true) ||
                (campo == 'feijao' && cardapio['fluxoFeijaoAtivo'] != true)) {
              continue;
            }
            destino[campo] = valor.trim();
            if (campo == 'tamanho') {
              final tamanho = _resolverOpcaoNatural(
                valor,
                _itensAtivos(cardapio, 'tamanhos'),
              );
              if (tamanho != null) {
                destino['tamanho'] = tamanho['nome'];
                destino['quantidadeMisturas'] =
                    tamanho['quantidadeMisturas'] ?? 1;
                destino['quantidadeAcompanhamentos'] =
                    tamanho['quantidadeAcompanhamentos'] ?? 1;
              }
            }
          }
        }
      }
    }
    if (atualizacoes is List && atualizacoes.isNotEmpty) {
      // Mudança nas marmitas invalida dados derivados do resumo anterior.
      for (final campo in const [
        'recebimento',
        'endereco',
        'enderecoPendente',
        'enderecoValidado',
        'cepEntrega',
        'cidadeEntrega',
        'cidadeEntregaId',
        'ufEntrega',
        'cidadeConfirmadaCliente',
        'taxaEntregaCongelada',
        'pagamento',
        'trocoPara',
        'bebidas',
      ]) {
        dados.remove(campo);
      }
      dados['bebidas'] = <dynamic>[];
    }
    rascunho['itens'] = itens;
    dados['rascunhoPedidoIA'] = rascunho;

    if (itens.isEmpty && _indicaUmaMarmita(msg.entrada)) {
      // Preserve the explicit quantity while details arrive in later messages.
      itens.add({'indice': 1, 'quantidade': 1});
      rascunho['itens'] = itens;
      dados['rascunhoPedidoIA'] = rascunho;
    }

    // Mensagens como "vou querer" não completam nem adicionam uma marmita.
    // Preserve os itens prontos e continue perguntando pelo próximo dado.
    if (!temAtualizacaoDeItem &&
        captura['finalizarItens'] != true &&
        itens.isNotEmpty &&
        itens.every((item) => _rascunhoItemCompleto(
              item,
              arrozAtivo: cardapio['fluxoArrozAtivo'] == true,
              feijaoAtivo: cardapio['fluxoFeijaoAtivo'] == true,
            ))) {
      banco.salvarSessao(
        telefone: msg.telefone,
        nome: msg.nome,
        etapa: 'ia_pedido',
        dados: dados,
      );
      await whatsapp.enviarTexto(
        msg.telefone,
        'Qual tamanho você prefere para a próxima marmita?',
      );
      return;
    }

    if (itens.isEmpty) {
      banco.salvarSessao(
        telefone: msg.telefone,
        nome: msg.nome,
        etapa: 'ia_pedido',
        dados: dados,
      );
      final totalMarmitas = rascunho['quantidadeTotalSolicitada'] is num
          ? (rascunho['quantidadeTotalSolicitada'] as num).toInt()
          : null;
      final jaIndicouMarmita = _contemTermo(
        msg.entrada,
        ['marmita', 'marmitas', 'pequena', 'media', 'grande'],
      );
      if (totalMarmitas == null && !jaIndicouMarmita) {
        await whatsapp.enviarTexto(
          msg.telefone,
          'Quantas marmitas vai ser?',
        );
      } else if (totalMarmitas == null && jaIndicouMarmita) {
        await whatsapp.enviarTexto(
          msg.telefone,
          'Vamos montar a sua marmita. Quantas marmitas vai ser?',
        );
      } else if ((totalMarmitas ?? 0) > 1) {
        itens.addAll(List.generate(
          totalMarmitas!,
          (indice) => <String, dynamic>{
            'indice': indice + 1,
            'quantidade': 1,
          },
        ));
        rascunho['itens'] = itens;
        dados['rascunhoPedidoIA'] = rascunho;
      } else {
        await whatsapp.enviarTexto(
          msg.telefone,
          'Vamos montar a sua marmita. Qual tamanho você prefere?',
        );
      }
      if (itens.isEmpty) return;
    }

    final normalizados = <Map<String, dynamic>>[];
    String? perguntaPendente;
    for (var i = 0; i < itens.length; i++) {
      final item = itens[i];
      final tamanho = _resolverOpcaoNatural(
          item['tamanho'], _itensAtivos(cardapio, 'tamanhos'));
      if (tamanho != null) {
        final misturasPadrao =
            (tamanho['quantidadeMisturas'] as num?)?.toInt() ?? 1;
        final acompanhamentosPadrao =
            (tamanho['quantidadeAcompanhamentos'] as num?)?.toInt() ?? 1;
        final misturasDesejadas =
            (item['quantidadeMisturasDesejada'] as num?)?.toInt();
        final acompanhamentosDesejados =
            (item['quantidadeAcompanhamentosDesejada'] as num?)?.toInt();
        item['quantidadeMisturas'] = misturasDesejadas != null &&
                misturasDesejadas >= 1 &&
                misturasDesejadas <= misturasPadrao
            ? misturasDesejadas
            : misturasPadrao;
        item['quantidadeAcompanhamentos'] = acompanhamentosDesejados != null &&
                acompanhamentosDesejados >= 1 &&
                acompanhamentosDesejados <= acompanhamentosPadrao
            ? acompanhamentosDesejados
            : acompanhamentosPadrao;
      }
      var quantidadeMisturas =
          (item['quantidadeMisturas'] as num?)?.toInt() ?? 1;
      var quantidadeAcompanhamentos =
          (item['quantidadeAcompanhamentos'] as num?)?.toInt() ?? 1;
      List<Map<String, dynamic>> resolverEscolhas(
        String plural,
        String singular,
        String colecao,
      ) {
        final opcoes = _itensAtivos(cardapio, colecao);
        final valores = _valoresEscolhidosRascunho(item, plural, singular);
        final resultado = <Map<String, dynamic>>[];
        for (final valor in valores) {
          final resolvida = _resolverOpcaoNatural(valor, opcoes);
          if (resolvida != null &&
              !resultado
                  .any((existente) => existente['id'] == resolvida['id'])) {
            resultado.add(resolvida);
          }
        }
        return resultado;
      }

      final misturas = resolverEscolhas('misturas', 'mistura', 'misturas');
      final acompanhamentos = resolverEscolhas(
        'acompanhamentos',
        'acompanhamento',
        'acompanhamentos',
      );
      final quantidadeMisturasAnterior =
          (item['quantidadeMisturasDesejada'] as num?)?.toInt();
      final quantidadeAcompanhamentosAnterior =
          (item['quantidadeAcompanhamentosDesejada'] as num?)?.toInt();
      final quantidadeMisturasDeclarada =
          _quantidadeEscolhasDeclarada(msg.entrada, 'mistura');
      if (quantidadeMisturasDeclarada != null) {
        item['quantidadeMisturasDesejada'] = quantidadeMisturasDeclarada;
        quantidadeMisturas = quantidadeMisturasDeclarada;
        item['quantidadeMisturas'] = quantidadeMisturasDeclarada;
      } else if (quantidadeMisturasAnterior != null &&
          misturas.length > quantidadeMisturasAnterior) {
        item.remove('quantidadeMisturasDesejada');
        quantidadeMisturas =
            (tamanho?['quantidadeMisturas'] as num?)?.toInt() ?? 1;
        item['quantidadeMisturas'] = quantidadeMisturas;
      }
      final quantidadeAcompanhamentosDeclarada =
          _quantidadeEscolhasDeclarada(msg.entrada, 'acompanhamento');
      if (quantidadeAcompanhamentosDeclarada != null) {
        item['quantidadeAcompanhamentosDesejada'] =
            quantidadeAcompanhamentosDeclarada;
        quantidadeAcompanhamentos = quantidadeAcompanhamentosDeclarada;
        item['quantidadeAcompanhamentos'] = quantidadeAcompanhamentosDeclarada;
      } else if (quantidadeAcompanhamentosAnterior != null &&
          acompanhamentos.length > quantidadeAcompanhamentosAnterior) {
        item.remove('quantidadeAcompanhamentosDesejada');
        quantidadeAcompanhamentos =
            (tamanho?['quantidadeAcompanhamentos'] as num?)?.toInt() ?? 1;
        item['quantidadeAcompanhamentos'] = quantidadeAcompanhamentos;
      }
      final mistura = misturas.isEmpty ? null : misturas.first;
      final acompanhamento =
          acompanhamentos.isEmpty ? null : acompanhamentos.first;
      final arrozAtivo = cardapio['fluxoArrozAtivo'] == true;
      final feijaoAtivo = cardapio['fluxoFeijaoAtivo'] == true;
      final arroz = arrozAtivo
          ? _resolverOpcaoNatural(
              item['arroz'], _itensAtivos(cardapio, 'arrozes'))
          : null;
      final feijao = feijaoAtivo
          ? _resolverOpcaoNatural(
              item['feijao'], _itensAtivos(cardapio, 'feijoes'))
          : null;
      final quantidade = item['quantidade'] is num
          ? (item['quantidade'] as num).toInt()
          : null;

      if (tamanho == null) {
        // Cada marmita é coletada com a mesma pergunta simples. Os índices
        // continuam apenas no estado interno para associar as respostas.
        perguntaPendente = _perguntaDetalhesPrimeiraMarmita(cardapio);
      } else if (arrozAtivo && arroz == null) {
        final referencia = _referenciaMarmitaIa(
          itens,
          i,
          totalSolicitado: rascunho['quantidadeTotalSolicitada'] as num?,
        );
        perguntaPendente = _perguntaOpcaoIA(
          'Qual arroz você prefere $referencia?',
          _itensAtivos(cardapio, 'arrozes'),
          'arroz',
        );
      } else if (feijaoAtivo && feijao == null) {
        final referencia = _referenciaMarmitaIa(
          itens,
          i,
          totalSolicitado: rascunho['quantidadeTotalSolicitada'] as num?,
        );
        perguntaPendente = _perguntaOpcaoIA(
          'Qual feijão você prefere $referencia?',
          _itensAtivos(cardapio, 'feijoes'),
          'feijão',
        );
      } else if (misturas.length > quantidadeMisturas) {
        item['misturas'] = <String>[];
        item['mistura'] = null;
        perguntaPendente = _perguntaOpcaoIA(
          'Quais misturas você prefere?',
          _itensAtivos(cardapio, 'misturas'),
          'mistura',
        );
      } else if (misturas.length < quantidadeMisturas) {
        final referencia = _referenciaMarmitaIa(
          itens,
          i,
          totalSolicitado: rascunho['quantidadeTotalSolicitada'] as num?,
        );
        final restantes = _itensAtivos(cardapio, 'misturas')
            .where((opcao) =>
                !misturas.any((escolhida) => escolhida['id'] == opcao['id']))
            .toList();
        final tamanhoNome = tamanho['nome']?.toString().trim() ?? '';
        final pergunta = quantidadeMisturas == 1
            ? 'Qual mistura você prefere $referencia?'
            : misturas.length == 1 && tamanhoNome.isNotEmpty
                ? 'Você pode escolher a segunda mistura para sua marmita $tamanhoNome. Vai querer qual?'
                : 'Você pode escolher mais uma mistura $referencia. Vai querer qual?';
        perguntaPendente = _perguntaOpcaoIA(
          pergunta,
          restantes,
          'mistura',
        );
      } else if (acompanhamentos.length > quantidadeAcompanhamentos) {
        item['acompanhamentos'] = <String>[];
        item['acompanhamento'] = null;
        perguntaPendente = _perguntaOpcaoIA(
          'Quais acompanhamentos você prefere?',
          _itensAtivos(cardapio, 'acompanhamentos'),
          'acompanhamento',
        );
      } else if (acompanhamentos.length < quantidadeAcompanhamentos) {
        final referencia = _referenciaMarmitaIa(
          itens,
          i,
          totalSolicitado: rascunho['quantidadeTotalSolicitada'] as num?,
        );
        final restantes = _itensAtivos(cardapio, 'acompanhamentos')
            .where((opcao) => !acompanhamentos
                .any((escolhida) => escolhida['id'] == opcao['id']))
            .toList();
        final tamanhoNome = tamanho['nome']?.toString().trim() ?? '';
        final pergunta = quantidadeAcompanhamentos == 1
            ? 'Qual acompanhamento você prefere $referencia?'
            : acompanhamentos.length == 1 && tamanhoNome.isNotEmpty
                ? 'Você pode escolher o segundo acompanhamento para sua marmita $tamanhoNome. Vai querer qual?'
                : 'Você pode escolher mais um acompanhamento $referencia. Vai querer qual?';
        perguntaPendente = _perguntaOpcaoIA(
          pergunta,
          restantes,
          'acompanhamento',
        );
      } else if (quantidade == null) {
        perguntaPendente = 'Quantas marmitas iguais a essa você gostaria?';
      }
      if (perguntaPendente != null) break;
      if (tamanho == null ||
          mistura == null ||
          acompanhamento == null ||
          misturas.length < quantidadeMisturas ||
          acompanhamentos.length < quantidadeAcompanhamentos ||
          quantidade == null ||
          (arrozAtivo && arroz == null) ||
          (feijaoAtivo && feijao == null)) {
        break;
      }

      normalizados.add({
        'tamanhoId': tamanho['id'],
        'tamanhoNome': tamanho['nome'],
        'precoUnitario': (tamanho['preco'] as num).toDouble(),
        'saladaIncluida': config['saladaIncluida'] == true,
        'descricaoSalada': config['descricaoSalada']?.toString() ?? 'Salada',
        if (arrozAtivo) 'arrozId': arroz!['id'],
        if (arrozAtivo) 'arrozNome': arroz!['nome'],
        if (feijaoAtivo) 'feijaoId': feijao!['id'],
        if (feijaoAtivo) 'feijaoNome': feijao!['nome'],
        'quantidadeMisturas': quantidadeMisturas,
        'quantidadeAcompanhamentos': quantidadeAcompanhamentos,
        'misturaId': mistura['id'],
        'misturaNome': mistura['nome'],
        'misturaIds': misturas.map((opcao) => opcao['id']).toList(),
        'misturaNomes': misturas.map((opcao) => opcao['nome']).toList(),
        'acompanhamentoId': acompanhamento['id'],
        'acompanhamentoNome': acompanhamento['nome'],
        'acompanhamentoIds':
            acompanhamentos.map((opcao) => opcao['id']).toList(),
        'acompanhamentoNomes':
            acompanhamentos.map((opcao) => opcao['nome']).toList(),
        'quantidade': quantidade,
        if (!arrozAtivo) 'arrozDesativado': true,
        if (!feijaoAtivo) 'feijaoDesativado': true,
      });
    }

    if (perguntaPendente != null) {
      if (normalizados.isNotEmpty) {
        dados['itens'] = normalizados;
      }
      banco.salvarSessao(
        telefone: msg.telefone,
        nome: msg.nome,
        etapa: 'ia_pedido',
        dados: dados,
      );
      await whatsapp.enviarTexto(msg.telefone, perguntaPendente);
      return;
    }

    // Uma linha por combinação: combinações idênticas podem ser agregadas,
    // diferentes permanecem separadas mesmo com o mesmo tamanho.
    final agregados = <String, Map<String, dynamic>>{};
    for (final item in normalizados) {
      final chave = [
        item['tamanhoId'],
        item['arrozId'],
        item['feijaoId'],
        item['arrozDesativado'],
        item['feijaoDesativado'],
        _chaveIdsEscolhas(item['misturaIds'], item['misturaId']),
        _chaveIdsEscolhas(item['acompanhamentoIds'], item['acompanhamentoId']),
      ].join('|');
      final existente = agregados[chave];
      if (existente == null) {
        agregados[chave] = item;
      } else {
        final total =
            (existente['quantidade'] as int) + (item['quantidade'] as int);
        if (total > 50) {
          await whatsapp.enviarTexto(msg.telefone,
              'O limite por combinação é 50 marmitas. Ajuste as quantidades, por favor.');
          return;
        }
        existente['quantidade'] = total;
      }
    }
    dados['itens'] = agregados.values.toList();
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'ia_pedido',
      dados: dados,
    );
    if (captura['finalizarItens'] == true) {
      await _mostrarRecebimento(msg, config, dados);
    } else {
      banco.salvarSessao(
        telefone: msg.telefone,
        nome: msg.nome,
        etapa: 'adicionar_outro',
        dados: dados,
      );
      await _mostrarAdicionarOutro(msg);
    }
  }

  String _perguntaDetalhesPrimeiraMarmita(Map<String, dynamic> cardapio) {
    return 'Qual será o tamanho, a mistura e o acompanhamento?';
  }

  int? _quantidadeEscolhasDeclarada(String entrada, String tipo) {
    final texto = _normalizarIntencao(entrada);
    final nome = tipo == 'mistura' ? 'mistura' : 'acompanhamento';
    final plural = tipo == 'mistura' ? 'misturas' : 'acompanhamentos';
    final marcouUmaSo = RegExp(
      r'\b(?:so|somente|apenas)\s+(?:uma|um|1)\b',
    ).hasMatch(texto);
    if (marcouUmaSo && RegExp('\\b(?:$nome|$plural)\\b').hasMatch(texto)) {
      return 1;
    }
    if (RegExp(
      '\\b(?:so|somente|apenas)\\s+(?:uma|um|1)\\s+' + '(?:$nome|$plural)\\b',
    ).hasMatch(texto)) {
      return 1;
    }
    if (RegExp(
      '\\b(?:uma|um|1)\\s+(?:$nome|$plural)\\s+(?:so|apenas)\\b',
    ).hasMatch(texto)) {
      return 1;
    }
    return null;
  }

  Map<String, dynamic>? _capturarRecusaEscolhaExtra(
    String entrada,
    Map<String, dynamic>? sessao,
  ) {
    final texto = _normalizarIntencao(entrada);
    if (!const {
      'nao',
      'n',
      'nao quero',
      'nao precisa',
      'dispenso',
      'so essa',
      'so esse',
      'so uma',
      'so um',
      'apenas essa',
      'apenas esse',
      'apenas uma',
      'apenas um',
      'essa basta',
      'esse basta',
      'nao quero outra',
      'nao quero outro',
      'nao vou querer outra',
      'nao vou querer outro',
    }.contains(texto)) {
      return null;
    }
    final dados = Map<String, dynamic>.from(sessao?['dados'] as Map? ?? {});
    final rascunho = Map<String, dynamic>.from(
      dados['rascunhoPedidoIA'] as Map? ?? const {},
    );
    final itens =
        (rascunho['itens'] as List? ?? const []).whereType<Map>().toList();
    final cardapio = banco.obterCardapio();
    for (var i = 0; i < itens.length; i++) {
      final item = Map<String, dynamic>.from(itens[i]);
      final tamanho = _resolverOpcaoNatural(
        item['tamanho'],
        _itensAtivos(cardapio, 'tamanhos'),
      );
      if (tamanho == null) continue;
      final misturas = _valoresEscolhidosRascunho(item, 'misturas', 'mistura');
      final acompanhamentos = _valoresEscolhidosRascunho(
        item,
        'acompanhamentos',
        'acompanhamento',
      );
      final quantidadeMisturas =
          (item['quantidadeMisturas'] as num?)?.toInt() ??
              (tamanho['quantidadeMisturas'] as num?)?.toInt() ??
              1;
      final quantidadeAcompanhamentos =
          (item['quantidadeAcompanhamentos'] as num?)?.toInt() ??
              (tamanho['quantidadeAcompanhamentos'] as num?)?.toInt() ??
              1;
      if (misturas.isNotEmpty && misturas.length < quantidadeMisturas) {
        return {
          'indice': i + 1,
          'quantidadeMisturasDesejada': misturas.length,
        };
      }
      if (acompanhamentos.isNotEmpty &&
          acompanhamentos.length < quantidadeAcompanhamentos) {
        return {
          'indice': i + 1,
          'quantidadeAcompanhamentosDesejada': acompanhamentos.length,
        };
      }
    }
    return null;
  }

  Future<String?> _interpretarMidia(MensagemWhatsApp msg) async {
    final mediaId = msg.mediaId;
    if (mediaId == null || mediaId.trim().isEmpty) return null;
    final midia = await whatsapp.baixarMidia(
      mediaId,
      mimeType: msg.mimeType,
    );
    if (midia == null) return null;
    if (msg.tipo == 'audio' || msg.tipo == 'voice') {
      final extensao = midia.mimeType.split('/').last.split(';').first;
      final transcricao = await ia.transcreverAudio(
        Uint8List.fromList(midia.bytes),
        filename: 'audio.$extensao',
      );
      if (transcricao == null) return null;
      return [
        if (msg.texto.trim().isNotEmpty) msg.texto.trim(),
        transcricao,
      ].join('\n');
    }
    if (msg.tipo == 'image') {
      final leitura = await ia.interpretarImagem(
        Uint8List.fromList(midia.bytes),
        mimeType: midia.mimeType,
      );
      if (leitura == null) return null;
      return [
        if (msg.texto.trim().isNotEmpty) msg.texto.trim(),
        leitura,
      ].join('\n');
    }
    return null;
  }

  String? _extrairObservacaoNoMeioDoPedido(String entrada) {
    final valor = RegExp(
      r'^\s*(?:(?:obs(?:erva(?:c|ç)(?:a|ã)o)?|observa(?:c|ç)(?:a|ã)o)|(?:anota|anote|pode anotar|detalhe|detalhe importante)|(?:quero|vai|pode)\s+sem)\s*[:=-]?\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(entrada.trim());
    final observacao = valor?.group(1)?.trim();
    if (observacao == null ||
        observacao.isEmpty ||
        observacao.length > 300 ||
        RegExp(r'^(?:bebida|marmita|pedido)\b', caseSensitive: false)
            .hasMatch(observacao)) {
      return null;
    }
    return observacao;
  }

  bool _rascunhoItemCompleto(
    Map<String, dynamic> item, {
    required bool arrozAtivo,
    required bool feijaoAtivo,
  }) {
    final misturas = _valoresEscolhidosRascunho(item, 'misturas', 'mistura');
    final acompanhamentos = _valoresEscolhidosRascunho(
      item,
      'acompanhamentos',
      'acompanhamento',
    );
    final quantidadeMisturas =
        (item['quantidadeMisturas'] as num?)?.toInt() ?? 1;
    final quantidadeAcompanhamentos =
        (item['quantidadeAcompanhamentos'] as num?)?.toInt() ?? 1;
    return item['tamanho'] != null &&
        misturas.length >= quantidadeMisturas &&
        acompanhamentos.length >= quantidadeAcompanhamentos &&
        item['quantidade'] != null &&
        (!arrozAtivo || item['arroz'] != null) &&
        (!feijaoAtivo || item['feijao'] != null);
  }

  List<String> _valoresEscolhidosRascunho(
    Map<String, dynamic> item,
    String campoPlural,
    String campoSingular,
  ) {
    final plural = item[campoPlural];
    final valores = plural is List
        ? plural.map((value) => value.toString().trim())
        : item[campoSingular] == null
            ? const <String>[]
            : [item[campoSingular].toString().trim()];
    final filtrados = valores.where((value) => value.isNotEmpty).toList();
    // Permite valores repetidos quando a quantidade permitida é maior que 1.
    // Isso permite que o cliente escolha duas misturas iguais, por exemplo.
    final quantidadePermitida = campoPlural == 'misturas'
        ? (item['quantidadeMisturas'] as num?)?.toInt() ?? 1
        : (item['quantidadeAcompanhamentos'] as num?)?.toInt() ?? 1;
    if (quantidadePermitida > 1) {
      return filtrados;
    }
    return filtrados.toSet().toList();
  }

  List<Map<String, dynamic>> _itensAtivos(
    Map<String, dynamic> cardapio,
    String chave,
  ) =>
      (cardapio[chave] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .where((item) => item['ativo'] == true)
          .toList();

  Map<String, dynamic>? _resolverOpcaoNatural(
    dynamic entrada,
    List<Map<String, dynamic>> opcoes,
  ) {
    final procurada = _limparRespostaOpcao(entrada?.toString() ?? '');
    if (procurada.isEmpty) return null;
    if (_ehPerguntaExplicita(entrada?.toString() ?? '') ||
        _contemTermo(procurada, ['nao', 'nunca', 'sem'])) {
      return null;
    }
    final exatas = opcoes
        .where(
            (item) => _normalizar(item['nome']?.toString() ?? '') == procurada)
        .toList();
    if (exatas.length == 1) return exatas.single;
    final aliases = opcoes.where((item) {
      final lista = item['aliases'];
      return lista is List &&
          lista.any(
            (alias) => _normalizar(alias.toString()) == procurada,
          );
    }).toList();
    if (aliases.length == 1) return aliases.single;
    final palavrasEntrada = procurada.split(' ');
    if (palavrasEntrada.length > 4 ||
        palavrasEntrada.any((palavra) => const {
              'e',
              'com',
              'mas',
              'porque',
              'pq',
              'talvez',
              'acho'
            }.contains(palavra))) {
      return null;
    }
    if (palavrasEntrada.length > 1) {
      final prefixos = opcoes.where((item) {
        final nome = _normalizar(item['nome']?.toString() ?? '');
        return nome.startsWith('$procurada ');
      }).toList();
      return prefixos.length == 1 ? prefixos.single : null;
    }

    // Uma palavra só pode selecionar por prefixo ou por erro de digitação
    // pequeno. Para nomes longos permitimos duas edições, mas somente quando
    // existe um único candidato claramente melhor.
    if (procurada.length < 4) return null;
    final prefixos = opcoes.where((item) {
      final nome = _normalizar(item['nome']?.toString() ?? '');
      return nome.split(' ').any((palavra) => palavra.startsWith(procurada));
    }).toList();
    if (prefixos.length == 1) return prefixos.single;
    if (prefixos.length > 1) return null;

    final distancias = <(Map<String, dynamic>, int)>[];
    final limiteDistancia = procurada.length >= 7 ? 2 : 1;
    for (final item in opcoes) {
      final nome = _normalizar(item['nome']?.toString() ?? '');
      final palavrasNome = nome.split(' ');
      var melhor = 999;
      for (final candidata in palavrasNome) {
        if (candidata.length < 5) continue;
        final distancia = _distanciaEdicao(procurada, candidata);
        if (distancia <= limiteDistancia && distancia < melhor) {
          melhor = distancia;
        }
      }
      if (melhor < 999) distancias.add((item, melhor));
    }
    if (distancias.isEmpty) return null;
    distancias.sort((a, b) => a.$2.compareTo(b.$2));
    if (distancias.length > 1 && distancias[0].$2 == distancias[1].$2) {
      return null;
    }
    return distancias.first.$1;
  }

  Map<String, dynamic>? _resolverTamanhoOpcaoNatural(
    String entrada,
    List<Map<String, dynamic>> opcoes,
  ) {
    final tamanho = _tamanhoPorAbreviacao(entrada);
    if (tamanho != null) {
      final correspondentes = opcoes
          .where(
              (item) => _normalizar(item['nome']?.toString() ?? '') == tamanho)
          .toList();
      if (correspondentes.length == 1) return correspondentes.single;
    }
    return _resolverOpcaoNatural(entrada, opcoes);
  }

  Map<String, String>? _resolverTamanhoOpcaoTexto(
    String entrada,
    List<Map<String, String>> opcoes,
  ) {
    final tamanho = _tamanhoPorAbreviacao(entrada);
    if (tamanho != null) {
      final correspondentes = opcoes
          .where((item) => _normalizar(item['nome'] ?? '') == tamanho)
          .toList();
      if (correspondentes.length == 1) return correspondentes.single;
    }
    return _resolverOpcaoTexto(entrada, opcoes);
  }

  String? _tamanhoPorAbreviacao(String entrada) {
    final texto = _limparRespostaOpcao(entrada);
    return const {'p': 'pequena', 'm': 'media', 'g': 'grande'}[texto];
  }

  Map<String, dynamic>? _capturarOpcaoPedidoCurta(
    String entrada,
    Map<String, dynamic>? sessao,
  ) {
    if (_ehPerguntaExplicita(entrada)) return null;
    final texto = _limparRespostaOpcao(entrada);
    if (texto.isEmpty ||
        texto.split(' ').length > 5 ||
        RegExp(r'\b(?:e|com|mas|porem)\b').hasMatch(texto)) {
      return null;
    }

    final cardapio = banco.obterCardapio();
    final arrozAtivo = cardapio['fluxoArrozAtivo'] == true;
    final feijaoAtivo = cardapio['fluxoFeijaoAtivo'] == true;
    final dados = Map<String, dynamic>.from(sessao?['dados'] as Map? ?? {});
    final rascunho = Map<String, dynamic>.from(
      dados['rascunhoPedidoIA'] as Map? ?? const {},
    );
    final itens = (rascunho['itens'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final incompleto = itens.indexWhere((item) => !_rascunhoItemCompleto(
          item,
          arrozAtivo: arrozAtivo,
          feijaoAtivo: feijaoAtivo,
        ));
    final indice = incompleto >= 0 ? incompleto + 1 : itens.length + 1;
    final item = incompleto >= 0 ? itens[incompleto] : <String, dynamic>{};

    final quantidadeMisturas =
        (item['quantidadeMisturas'] as num?)?.toInt() ?? 1;
    final quantidadeAcompanhamentos =
        (item['quantidadeAcompanhamentos'] as num?)?.toInt() ?? 1;
    final String? campo = item['tamanho'] == null
        ? 'tamanho'
        : arrozAtivo && item['arroz'] == null
            ? 'arroz'
            : feijaoAtivo && item['feijao'] == null
                ? 'feijao'
                : _valoresEscolhidosRascunho(item, 'misturas', 'mistura')
                            .length <
                        quantidadeMisturas
                    ? 'mistura'
                    : _valoresEscolhidosRascunho(
                              item,
                              'acompanhamentos',
                              'acompanhamento',
                            ).length <
                            quantidadeAcompanhamentos
                        ? 'acompanhamento'
                        : null;
    if (campo == null) return null;

    final opcoes = switch (campo) {
      'tamanho' => _itensAtivos(cardapio, 'tamanhos'),
      'arroz' => _itensAtivos(cardapio, 'arrozes'),
      'feijao' => _itensAtivos(cardapio, 'feijoes'),
      'mistura' => _itensAtivos(cardapio, 'misturas'),
      'acompanhamento' => _itensAtivos(cardapio, 'acompanhamentos'),
      _ => const <Map<String, dynamic>>[],
    };
    final escolhido = campo == 'tamanho'
        ? _resolverTamanhoOpcaoNatural(texto, opcoes)
        : _resolverOpcaoNatural(texto, opcoes);
    if (escolhido == null && campo == 'acompanhamento') {
      // Customers sometimes give the next marmita's mixture while we are
      // still collecting this marmita's accompaniment. Keep it on that next
      // sized item and continue asking for the current missing detail.
      final misturaSeguinte = _resolverOpcaoNatural(
        texto,
        _itensAtivos(cardapio, 'misturas'),
      );
      if (misturaSeguinte != null) {
        for (var i = indice; i < itens.length; i++) {
          if (itens[i]['tamanho'] != null && itens[i]['mistura'] == null) {
            return {
              'indice': i + 1,
              'mistura': misturaSeguinte['nome']?.toString(),
            };
          }
        }
      }
    }
    if (escolhido == null) return null;
    return {
      'indice': indice,
      campo: escolhido['nome']?.toString(),
    };
  }

  Map<String, dynamic>? _interpretarCorrecaoDeItem(
    String entrada,
    Map<String, dynamic>? sessao,
  ) {
    if (_ehPerguntaExplicita(entrada)) return null;
    final texto = _normalizarIntencao(entrada);
    final match = RegExp(
      r'^(?:eu\s+)?(?:quero|queria|gostaria\s+de|vou)?\s*(?:trocar|troca|mudar|muda|colocar|coloca|passar|passa|alterar|altera)\s+(?:a|o|as|os)?\s*(mistura|acompanhamento)\s+(?:para|por)\s+(.+)$',
    ).firstMatch(texto);
    final cardapio = banco.obterCardapio();
    String? campo = match?.group(1);
    String? candidato = match?.group(2)?.trim();
    String? origem;
    if (match == null) {
      // Também reconhece a forma cotidiana "troca a batata por macarrão".
      // A categoria é inferida somente quando a opção de origem e a nova
      // opção apontam sem ambiguidade para a mesma lista do cardápio.
      final troca = RegExp(
        r'^(?:eu\s+)?(?:quero|queria|gostaria\s+de|vou)?\s*(?:trocar|troca|mudar|muda|colocar|coloca|passar|passa|alterar|altera)\s+(?:a|o|as|os)?\s*(.+?)\s+(?:para|por|no lugar de)\s+(.+)$',
      ).firstMatch(texto);
      if (troca == null) return null;
      origem = troca.group(1)?.trim();
      candidato = troca.group(2)?.trim();
      final opcoes = <String, List<Map<String, dynamic>>>{
        'mistura': _itensAtivos(cardapio, 'misturas'),
        'acompanhamento': _itensAtivos(cardapio, 'acompanhamentos'),
      };
      final tiposOrigem = opcoes.entries
          .where((entry) => _resolverOpcaoNatural(origem, entry.value) != null)
          .map((entry) => entry.key)
          .toList();
      final tiposDestino = opcoes.entries
          .where(
              (entry) => _resolverOpcaoNatural(candidato, entry.value) != null)
          .map((entry) => entry.key)
          .toSet();
      if (tiposOrigem.length != 1 ||
          !tiposDestino.contains(tiposOrigem.single)) {
        return null;
      }
      campo = tiposOrigem.single;
    }
    if (campo == null || candidato == null || candidato.isEmpty) return null;
    final chave = campo == 'mistura' ? 'misturas' : 'acompanhamentos';
    final opcao =
        _resolverOpcaoNatural(candidato, _itensAtivos(cardapio, chave));
    if (opcao == null) return null;

    final dados = Map<String, dynamic>.from(sessao?['dados'] as Map? ?? {});
    final rascunho = Map<String, dynamic>.from(
      dados['rascunhoPedidoIA'] as Map? ?? const {},
    );
    final itens = (rascunho['itens'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    if (itens.isEmpty) return null;
    var indice = -1;
    if (origem != null) {
      final opcaoOrigem =
          _resolverOpcaoNatural(origem, _itensAtivos(cardapio, chave));
      if (opcaoOrigem != null) {
        final encontrados = <int>[];
        for (var i = 0; i < itens.length; i++) {
          final escolhas = _valoresEscolhidosRascunho(
            itens[i],
            campo == 'mistura' ? 'misturas' : 'acompanhamentos',
            campo,
          );
          if (escolhas.any((valor) =>
              _normalizar(valor) ==
              _normalizar(opcaoOrigem['nome'].toString()))) {
            encontrados.add(i);
          }
        }
        if (encontrados.length == 1) indice = encontrados.single;
        if (encontrados.length > 1) return null;
      }
    }
    if (indice < 0) {
      final incompletos = <int>[];
      for (var i = 0; i < itens.length; i++) {
        final escolhas = _valoresEscolhidosRascunho(
          itens[i],
          campo == 'mistura' ? 'misturas' : 'acompanhamentos',
          campo,
        );
        final quantidade = campo == 'mistura'
            ? (itens[i]['quantidadeMisturas'] as num?)?.toInt() ?? 1
            : (itens[i]['quantidadeAcompanhamentos'] as num?)?.toInt() ?? 1;
        if (escolhas.length < quantidade) incompletos.add(i);
      }
      if (incompletos.length == 1) indice = incompletos.single;
      if (indice < 0 && itens.length == 1) indice = 0;
    }
    if (indice < 0) return null;

    final resultado = <String, dynamic>{
      'indice': indice + 1,
      campo: opcao['nome']?.toString(),
      'substituirCampo': campo,
    };
    if (origem != null) {
      final nomeOrigem = _resolverOpcaoNatural(
        origem,
        _itensAtivos(cardapio, chave),
      )?['nome']
          ?.toString();
      final escolhas = _valoresEscolhidosRascunho(
        itens[indice],
        campo == 'mistura' ? 'misturas' : 'acompanhamentos',
        campo,
      );
      final substituiIndice = escolhas.indexWhere(
        (escolha) =>
            nomeOrigem != null &&
            _normalizar(escolha) == _normalizar(nomeOrigem),
      );
      if (substituiIndice >= 0) {
        resultado['substituirIndice'] = substituiIndice;
      }
    }
    return resultado;
  }

  String? _respostaTrocaEntreCategorias(
    String entrada,
    Map<String, dynamic> cardapio,
  ) {
    final troca = RegExp(
      r'^(?:eu\s+)?(?:quero|queria|gostaria\s+de|vou)?\s*(?:trocar|troca|mudar|muda|colocar|coloca|passar|passa|alterar|altera)\s+(?:a|o|as|os)?\s*(.+?)\s+(?:para|por|no lugar de)\s+(.+)$',
    ).firstMatch(_normalizarIntencao(entrada));
    if (troca == null) return null;
    final origem = troca.group(1)?.trim() ?? '';
    final destino = troca.group(2)?.trim() ?? '';
    final opcoes = <String, List<Map<String, dynamic>>>{
      'mistura': _itensAtivos(cardapio, 'misturas'),
      'acompanhamento': _itensAtivos(cardapio, 'acompanhamentos'),
    };
    final tiposOrigem = opcoes.entries
        .where((entry) => _resolverOpcaoNatural(origem, entry.value) != null)
        .map((entry) => entry.key)
        .toList();
    final tiposDestino = opcoes.entries
        .where((entry) => _resolverOpcaoNatural(destino, entry.value) != null)
        .map((entry) => entry.key)
        .toList();
    if (tiposOrigem.length != 1 ||
        tiposDestino.length != 1 ||
        tiposOrigem.single == tiposDestino.single) {
      return null;
    }
    final origemResolvida = _resolverOpcaoNatural(
      origem,
      opcoes[tiposOrigem.single]!,
    )!;
    final destinoResolvido = _resolverOpcaoNatural(
      destino,
      opcoes[tiposDestino.single]!,
    )!;
    return '“${origemResolvida['nome']}” é ${tiposOrigem.single == 'mistura' ? 'mistura' : 'acompanhamento'} e '
        '“${destinoResolvido['nome']}” é ${tiposDestino.single == 'mistura' ? 'mistura' : 'acompanhamento'}. '
        'Não alterei o pedido porque são categorias diferentes. Diga uma opção da mesma categoria para fazer a troca.';
  }

  Map<String, dynamic>? _capturarQuantidadePendente(
    String entrada,
    Map<String, dynamic>? sessao,
  ) {
    if (_ehPerguntaExplicita(entrada)) return null;
    final cardapio = banco.obterCardapio();
    final arrozAtivo = cardapio['fluxoArrozAtivo'] == true;
    final feijaoAtivo = cardapio['fluxoFeijaoAtivo'] == true;
    final dados = Map<String, dynamic>.from(sessao?['dados'] as Map? ?? {});
    final rascunho = Map<String, dynamic>.from(
      dados['rascunhoPedidoIA'] as Map? ?? const {},
    );
    final itens = (rascunho['itens'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    if (itens.length != 1) return null;
    final item = itens.single;
    if (item['tamanho'] == null ||
        item['mistura'] == null ||
        item['acompanhamento'] == null ||
        (arrozAtivo && item['arroz'] == null) ||
        (feijaoAtivo && item['feijao'] == null) ||
        item['quantidade'] != null) {
      return null;
    }
    final match = RegExp(
      r'^(?:(?:quero|queria|gostaria de|vou querer|sao|serao|seriam|ser|vai ser|fica|ficam)\s+)?'
      r'(um|uma|dois|duas|tres|quatro|cinco|seis|sete|oito|nove|dez|\d{1,2})'
      r'(\s+marmitas?)?'
      r'(\s+iguals?\s+a\s+essa)?'
      r'(\s+por favor)?$',
    ).firstMatch(_normalizarIntencao(entrada));
    if (match == null) return null;
    final quantidade = _parseQuantidade(match.group(1)!);
    if (quantidade == null || quantidade < 1 || quantidade > 50) return null;
    return {'indice': 1, 'quantidade': quantidade};
  }

  List<Map<String, dynamic>>? _capturarOpcoesPedidoCompostas(
    String entrada,
    Map<String, dynamic>? sessao,
  ) {
    final cardapio = banco.obterCardapio();
    final porCampo = _extrairOpcoesCompostas(entrada, cardapio);
    if (porCampo == null || porCampo.length < 2) return null;

    final dados = Map<String, dynamic>.from(sessao?['dados'] as Map? ?? {});
    final rascunho = Map<String, dynamic>.from(
      dados['rascunhoPedidoIA'] as Map? ?? const {},
    );
    final itens = (rascunho['itens'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final incompleto = itens.indexWhere((item) => !_rascunhoItemCompleto(
          item,
          arrozAtivo: cardapio['fluxoArrozAtivo'] == true,
          feijaoAtivo: cardapio['fluxoFeijaoAtivo'] == true,
        ));
    final indice = incompleto >= 0 ? incompleto : itens.length;
    final atual = indice < itens.length ? itens[indice] : <String, dynamic>{};
    for (final campo in porCampo.keys) {
      final valorAtual = atual[campo]?.toString();
      final novoValor = porCampo[campo]!['nome']?.toString();
      if (valorAtual != null &&
          _normalizar(valorAtual) != _normalizar(novoValor ?? '')) {
        return null;
      }
    }
    return [
      {
        'indice': indice + 1,
        for (final entry in porCampo.entries)
          entry.key: entry.value['nome']?.toString(),
      }
    ];
  }

  Map<String, Map<String, dynamic>>? _extrairOpcoesCompostas(
    String entrada,
    Map<String, dynamic> cardapio,
  ) {
    if (_ehPerguntaExplicita(entrada)) return null;
    final partes = _normalizarIntencao(entrada)
        .split(RegExp(r'\s+(?:e|com|mais)\s+|[,;]'))
        .map((parte) => parte
            .replaceFirst(
              RegExp(
                r'^(?:uma?|duas?|dois|tres|quatro|cinco|seis|sete|oito|nove|dez)\s+',
              ),
              '',
            )
            .trim())
        .where((parte) => parte.isNotEmpty)
        .toList();
    if (partes.length < 2) return null;

    final porCampo = <String, Map<String, dynamic>>{};
    for (final parte in partes) {
      final encontrados = <String, Map<String, dynamic>>{};
      for (final campo in const ['mistura', 'acompanhamento']) {
        final chave = campo == 'mistura' ? 'misturas' : 'acompanhamentos';
        final opcao =
            _resolverOpcaoNatural(parte, _itensAtivos(cardapio, chave));
        if (opcao != null) encontrados[campo] = opcao;
      }
      if (encontrados.length != 1) return null;
      final entry = encontrados.entries.single;
      final existente = porCampo[entry.key];
      if (existente != null && existente['id'] != entry.value['id']) {
        return null;
      }
      porCampo[entry.key] = entry.value;
    }
    return porCampo;
  }

  String? _perguntarSobreTrocaDeMistura(
    String entrada,
    Map<String, dynamic>? sessao,
  ) {
    final cardapio = banco.obterCardapio();
    final porCampo = _extrairOpcoesCompostas(entrada, cardapio);
    final novaMistura = porCampo?['mistura'];
    if (novaMistura == null || porCampo?['acompanhamento'] == null) {
      return null;
    }
    final dados = Map<String, dynamic>.from(sessao?['dados'] as Map? ?? {});
    final rascunho = Map<String, dynamic>.from(
      dados['rascunhoPedidoIA'] as Map? ?? const {},
    );
    final itens = (rascunho['itens'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final indice = itens.indexWhere((item) => !_rascunhoItemCompleto(
          item,
          arrozAtivo: cardapio['fluxoArrozAtivo'] == true,
          feijaoAtivo: cardapio['fluxoFeijaoAtivo'] == true,
        ));
    if (indice < 0) return null;
    final item = itens[indice];
    final misturaAnterior = item['mistura']?.toString();
    final misturaNova = novaMistura['nome']?.toString();
    if (misturaAnterior == null ||
        _normalizar(misturaAnterior) == _normalizar(misturaNova ?? '')) {
      return null;
    }
    final quantidade =
        item['quantidade'] is num ? (item['quantidade'] as num).toInt() : 1;
    final tamanho = item['tamanho']?.toString() ?? 'marmita';
    if (quantidade > 1) {
      return 'Você já informou $quantidade ${tamanho.toLowerCase()}s com '
          '$misturaAnterior e agora mencionou $misturaNova. '
          'Quer trocar as $quantidade para $misturaNova ou separar uma de cada?';
    }
    return 'Você já tinha escolhido $misturaAnterior para essa marmita. '
        'Quer trocar por $misturaNova ou manter a mistura anterior?';
  }

  List<Map<String, dynamic>>? _capturarTamanhosPedido(
    String entrada,
    Map<String, dynamic>? sessao,
  ) {
    final texto = _normalizarIntencao(entrada);
    final padrao = RegExp(
      r'\b(?:(\d{1,2}|um|uma|dois|duas|tres|quatro|cinco|seis|sete|oito|nove|dez)\s+(?:marmitas?\s+)?)?(pequena|media|grande|p|m|g)s?\b',
    );
    final ocorrencias = padrao.allMatches(texto).toList();
    if (ocorrencias.isEmpty) return null;

    final dadosSessao = Map<String, dynamic>.from(
      sessao?['dados'] as Map? ?? const {},
    );
    final rascunho = Map<String, dynamic>.from(
      dadosSessao['rascunhoPedidoIA'] as Map? ?? const {},
    );
    final totalAnterior = rascunho['quantidadeTotalSolicitada'] is num
        ? (rascunho['quantidadeTotalSolicitada'] as num).toInt()
        : null;
    if (ocorrencias.length == 1 &&
        ocorrencias.single.group(1) == null &&
        (totalAnterior == null || totalAnterior < 1)) {
      return null;
    }

    final cardapio = banco.obterCardapio();
    final arrozAtivo = cardapio['fluxoArrozAtivo'] == true;
    final feijaoAtivo = cardapio['fluxoFeijaoAtivo'] == true;
    final itensExistentes = (rascunho['itens'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final incompleto =
        itensExistentes.indexWhere((item) => !_rascunhoItemCompleto(
              item,
              arrozAtivo: arrozAtivo,
              feijaoAtivo: feijaoAtivo,
            ));
    final deslocamento = incompleto >= 0 ? incompleto : itensExistentes.length;

    Map<String, dynamic>? detalhes;
    if (ocorrencias.length == 1) {
      final resto = texto
          .replaceRange(ocorrencias.single.start, ocorrencias.single.end, ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final avaliacao = _detalhesParaTamanhoUnico(resto, cardapio);
      if (!avaliacao.$1) return null;
      detalhes = avaliacao.$2;
    }

    final opcoes = _itensAtivos(cardapio, 'tamanhos');
    final resultado = <Map<String, dynamic>>[];
    final quantidadeJaRepresentada =
        itensExistentes.take(deslocamento).fold<int>(0, (total, item) {
      final quantidade = item['quantidade'];
      return total +
          (quantidade is num && quantidade >= 1 ? quantidade.toInt() : 1);
    });
    final quantidadeRestante =
        totalAnterior == null ? null : totalAnterior - quantidadeJaRepresentada;
    var quantidadeAcumulada = 0;
    for (final ocorrencia in ocorrencias) {
      final tamanho = _resolverTamanhoOpcaoNatural(
        ocorrencia.group(2)!,
        opcoes,
      );
      if (tamanho == null) return null;
      final textoQuantidade = ocorrencia.group(1);
      final quantidade =
          textoQuantidade == null ? 1 : _parseQuantidade(textoQuantidade);
      if (quantidade != null && (quantidade < 1 || quantidade > 50)) {
        return null;
      }
      quantidadeAcumulada += quantidade ?? 0;
      for (var unidade = 0; unidade < (quantidade ?? 0); unidade++) {
        resultado.add({
          'indice': deslocamento + resultado.length + 1,
          'tamanho': tamanho['nome'],
          'quantidade': 1,
          if (detalhes != null) ...detalhes,
        });
      }
    }
    if (quantidadeRestante != null &&
        (quantidadeRestante < 0 || quantidadeAcumulada > quantidadeRestante)) {
      // Explicit size counts that disagree with the stated total need a
      // clarification; don't add extra units or replace the earlier plan.
      return null;
    }
    return resultado;
  }

  String _limparParteDetalheMarmita(String parte) {
    var texto = _normalizarIntencao(parte)
        .replaceFirst(RegExp(r'^(?:por favor|pfv|por gentileza)\s+'), '')
        .replaceFirst(RegExp(r'\s+(?:por favor|pfv|por gentileza)$'), '');
    final leadIn = RegExp(
      r'^(?:eu\s+)?(?:quero|queria|gostaria\s+de|vou\s+querer|vou\s+levar|'
      r'serao|sera|seriam|sao|fica|ficam|deixa|coloca|colocar|adicionar|'
      r'adiciona|incluir|inclui|mais|outras|outra|marmitas|marmita|'
      r'pequenas|pequena|medias|media|grandes|grande|'
      r'uns|umas|um|uma|dois|duas|as|os|de|do|da|dos|das|com|e|a|o)\s+',
    );
    for (var tentativa = 0; tentativa < 6; tentativa++) {
      final limpo = texto.replaceFirst(leadIn, '');
      if (limpo == texto) break;
      texto = limpo;
    }
    return texto.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  (bool, Map<String, dynamic>?) _detalhesParaTamanhoUnico(
    String resto,
    Map<String, dynamic> cardapio,
  ) {
    if (_ehPerguntaExplicita(resto)) return (false, null);
    final partes = resto
        .split(RegExp(r'\s+(?:e|com|mais)\s+|[,;]'))
        .map(_limparParteDetalheMarmita)
        .where((parte) => parte.isNotEmpty)
        .toList();
    if (partes.isEmpty) return (true, null);
    final porCampo = <String, Map<String, dynamic>>{};
    var naoReconhecidas = 0;
    for (final parte in partes) {
      final candidatos = <String, Map<String, dynamic>>{};
      for (final campo in const ['mistura', 'acompanhamento']) {
        final chave = campo == 'mistura' ? 'misturas' : 'acompanhamentos';
        final opcao =
            _resolverOpcaoNatural(parte, _itensAtivos(cardapio, chave));
        if (opcao != null) candidatos[campo] = opcao;
      }
      if (candidatos.isEmpty) {
        naoReconhecidas++;
        continue;
      }
      if (candidatos.length > 1) return (false, null);
      final campo = candidatos.keys.single;
      final opcao = candidatos[campo]!;
      final anterior = porCampo[campo];
      if (anterior != null &&
          _normalizar(anterior['nome']?.toString() ?? '') !=
              _normalizar(opcao['nome']?.toString() ?? '')) {
        return (false, null);
      }
      porCampo[campo] = opcao;
    }
    if (porCampo.isEmpty) return (naoReconhecidas > 0 ? false : true, null);
    if (naoReconhecidas > 0) return (false, null);
    return (
      true,
      porCampo.map((campo, opcao) => MapEntry(campo, opcao['nome'])),
    );
  }

  int? _extrairTotalMarmitas(String entrada) {
    final texto = _normalizarIntencao(entrada);
    final match = RegExp(
      r'\b(\d{1,2}|um|uma|dois|duas|tres|quatro|cinco|seis|sete|oito|nove|dez)\s+marmitas?\b',
    ).firstMatch(texto);
    if (match == null) return null;
    final quantidade = _parseQuantidade(match.group(1)!);
    return quantidade != null && quantidade >= 1 && quantidade <= 50
        ? quantidade
        : null;
  }

  String _limparRespostaOpcao(String entrada) {
    var texto = _normalizarIntencao(entrada);
    for (var tentativa = 0; tentativa < 3; tentativa++) {
      texto = texto
          .replaceFirst(
            RegExp(
              r'^(?:(?:eu )?(?:vou querer|gostaria de adicionar|quero adicionar|queria adicionar|vou querer adicionar|gostaria de|quero|queria)|(?:pode ser|pode se|poderia|vai ser|pode)|(?:adiciona|adicionar|inclui|incluir|coloca|colocar|acrescenta|acrescentar)|(?:sim|claro|isso))\s+',
            ),
            '',
          )
          .replaceFirst(
            RegExp(r'^(?:uma?|uns?|as?|os?|outra|outro|mais uma|mais um)\s+'),
            '',
          );
    }
    texto = texto
        .replaceAll(
            RegExp(r'\b(?:tambem|tbm|por favor|pfv|por gentileza)\b'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return texto;
  }

  bool _ehPerguntaExplicita(String entrada) {
    final texto = _normalizar(entrada);
    if (RegExp(r'\?').hasMatch(entrada)) return true;
    return RegExp(
      r'^(?:mas )?(?:(?:voce|voces|vc|vcs) (?:nao )?(?:tem|tem mesmo|vende|vendem)|tem mesmo|nao tem|sera que tem|qual|quais|como|porque|pq|por que|me diz se)\b',
    ).hasMatch(texto);
  }

  bool _ehIntencaoOutraMarmita(String entrada) {
    final texto = _normalizarIntencao(entrada);
    if (_ehNegacaoOpcional(texto)) return false;
    return _corresponde(texto, [
          'sim',
          's',
          'claro',
          'com certeza',
          'quero',
          'queria',
          'vou querer',
          'pode',
          'pode ser',
          'pode sim',
          'mais',
          'mais uma',
          'mais uma marmita',
          'mais um prato',
          'adiciona mais uma',
          'adicionar mais uma',
          'inclui mais uma',
          'incluir mais uma',
          'coloca mais uma',
          'quero outra marmita',
          'queria outra marmita',
          'vou querer outra marmita',
          'pode adicionar outra',
          'pode incluir outra',
          'outra',
          'adicionar outra',
          'sim por favor',
        ]) ||
        RegExp(
          r'^(?:(?:quero|queria|vou querer|gostaria de|pode adicionar|pode incluir|coloca|inclui|incluir|adiciona|adicionar)\s+(?:(?:mais\s+)?uma|outra|mais uma|outra marmita|mais uma marmita|outra refeicao|outro prato)(?:\s+por favor)?)$',
        ).hasMatch(texto);
  }

  bool _indicaUmaMarmita(String entrada) {
    final texto = _normalizarIntencao(entrada);
    return RegExp(
      r'\b(?:uma|1)\s+(?:marmita|pequena|media|grande)\b',
    ).hasMatch(texto);
  }

  bool _ehPedidoDeUmaMarmitaSemDetalhes(String entrada) {
    final texto = _normalizarIntencao(entrada);
    return RegExp(
      r'^(?:(?:eu\s+)?(?:vou querer|quero|queria|gostaria de)\s+)(?:um|uma|1)(?:\s+marmitas?)?(?:\s+por favor)?$',
    ).hasMatch(texto);
  }

  bool _ehFinalizacaoItens(String entrada) => _corresponde(
        entrada,
        [
          'finalizar',
          'finaliza',
          'finalizar pedido',
          'so isso',
          'somente isso',
          'por enquanto e isso',
          'nao quero mais',
          'pode fechar',
        ],
      );

  bool _textoIaRepeteCliente(String resposta, String entrada) =>
      _normalizar(resposta) == _normalizar(entrada);

  int _distanciaEdicao(String a, String b) {
    final linha = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      var diagonal = linha[0];
      linha[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final acima = linha[j];
        final custo = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        linha[j] = [linha[j] + 1, linha[j - 1] + 1, diagonal + custo]
            .reduce((x, y) => x < y ? x : y);
        diagonal = acima;
      }
    }
    return linha[b.length];
  }

  Map<String, String>? _resolverOpcaoTexto(
    String entrada,
    List<Map<String, String>> opcoes,
  ) {
    final nome = _resolverOpcaoNatural(
      entrada,
      opcoes.map((item) => <String, dynamic>{'nome': item['nome']}).toList(),
    );
    if (nome == null) return null;
    final nomeNormalizado = _normalizar(nome['nome']?.toString() ?? '');
    final correspondentes = opcoes
        .where((item) => _normalizar(item['nome'] ?? '') == nomeNormalizado)
        .toList();
    return correspondentes.length == 1 ? correspondentes.single : null;
  }

  String _perguntaOpcaoIA(
    String pergunta,
    List<Map<String, dynamic>> opcoes,
    String rotulo,
  ) {
    if (opcoes.isEmpty)
      return 'No momento não há $rotulo disponível. Fale com um atendente.';
    return pergunta;
  }

  List<Map<String, String>> _opcoesEtapaIA(
    String etapa,
    Map<String, dynamic>? sessao,
    Map<String, dynamic> config,
  ) {
    if (etapa == 'inicio') {
      if (_modoIaAtivo) return const [];
      return _botoesInicio()
          .map((item) => {'valor': item['id']!, 'nome': item['titulo']!})
          .toList();
    }
    if (etapa == 'confirmacao') {
      return const [
        {'valor': 'conf_confirmar', 'nome': 'Confirmar pedido'},
        {'valor': 'conf_refazer', 'nome': 'Refazer pedido'},
        {'valor': 'conf_cancelar', 'nome': 'Cancelar pedido'},
      ];
    }
    if (etapa == 'confirmar_cancelamento') {
      return const [
        {'valor': 'cancelar_sim', 'nome': 'Sim, cancelar'},
        {'valor': 'cancelar_nao', 'nome': 'Continuar pedido'},
      ];
    }
    if (etapa == 'adicionar_outro') {
      return const [
        {'valor': 'outro_sim', 'nome': 'Adicionar outra marmita'},
        {'valor': 'outro_nao', 'nome': 'Finalizar pedido'},
      ];
    }
    if (etapa == 'adicionar_outra_bebida') {
      return <Map<String, String>>[
        {'valor': 'beb_outra', 'nome': 'Adicionar outra bebida'},
        {'valor': 'beb_finalizar', 'nome': 'Finalizar bebidas'},
        ..._bebidasAtivas().map<Map<String, String>>((bebida) => {
              'valor': 'beb:${bebida['id']}',
              'nome': bebida['nome'].toString(),
            }),
      ];
    }

    final dados = Map<String, dynamic>.from(sessao?['dados'] as Map? ?? {});
    final List<dynamic> exibidas = switch (etapa) {
      'recebimento' => dados['recebimentosExibidos'] as List? ?? const [],
      'pagamento' => dados['pagamentosExibidos'] as List? ?? const [],
      'cidade_entrega' => dados['cidadesExibidas'] as List? ?? const [],
      'tamanho' ||
      'arroz' ||
      'feijao' ||
      'mistura' ||
      'acompanhamento' ||
      'bebida' =>
        dados['opcoesExibidas'] as List? ?? const [],
      _ => const [],
    };
    final prefixo = switch (etapa) {
      'tamanho' => 'tam:',
      'arroz' => 'arr:',
      'feijao' => 'fei:',
      'mistura' => 'mis:',
      'acompanhamento' => 'aco:',
      'bebida' => 'beb:',
      'cidade_entrega' => 'cid:',
      _ => '',
    };
    final opcoes = exibidas
        .whereType<Map>()
        .map((item) {
          final id = item['id']?.toString() ?? '';
          final nome = (item['titulo'] ?? item['nome'] ?? '').toString();
          return {
            'valor':
                prefixo.isEmpty || id.startsWith(prefixo) ? id : '$prefixo$id',
            'nome': nome,
          };
        })
        .where((item) => item['valor']!.isNotEmpty && item['nome']!.isNotEmpty)
        .toList();
    if (etapa == 'bebida') {
      opcoes.add({'valor': 'beb_sem', 'nome': 'Sem bebida'});
    } else if (etapa == 'troco') {
      opcoes.add({'valor': 'não', 'nome': 'Sem troco'});
      opcoes
          .add({'valor': 'valor numérico', 'nome': 'Informar valor do troco'});
    }
    if (etapa == 'pagamento' && opcoes.isEmpty) {
      return _opcoesPagamento(config)
          .map((item) => {'valor': item['id']!, 'nome': item['titulo']!})
          .toList();
    }
    return opcoes;
  }

  Future<void> _processarInterno(
    MensagemWhatsApp msg, {
    String? respostaIA,
    Map<String, dynamic>? pedidoIA,
  }) async {
    if (!banco.iniciarProcessamentoMensagem(msg.id)) return;
    try {
      final configWrapper = banco.obterConfiguracao();
      final config = Map<String, dynamic>.from(configWrapper['dados'] as Map);
      if (config['botAtivo'] == false) {
        banco.finalizarMensagem(msg.id);
        return;
      }
      // Mantém a mensagem como não lida para permitir a notificação no celular
      // durante o teste. Reative marcarComoLida se quiser voltar ao comportamento anterior.

      var sessao = banco.obterSessao(msg.telefone);
      if (sessao?['modoHumano'] == true) {
        banco.finalizarMensagem(msg.id);
        return;
      }
      if (msg.temLocalizacao) {
        final dadosLocalizacao =
            Map<String, dynamic>.from(sessao?['dados'] as Map? ?? {});
        dadosLocalizacao['ultimaLocalizacao'] = {
          'latitude': msg.latitude,
          'longitude': msg.longitude,
          'recebidaEm': agoraIso(),
        };
        banco.salvarSessao(
          telefone: msg.telefone,
          nome: msg.nome,
          etapa: sessao?['etapa']?.toString() ?? 'inicio',
          dados: dadosLocalizacao,
        );
        if (sessao?['etapa'] == 'endereco') {
          await whatsapp.enviarTexto(
            msg.telefone,
            'Recebi sua localização. Para confirmar a entrega, envie também o endereço com rua, número e bairro.',
          );
        } else {
          await whatsapp.enviarTexto(
            msg.telefone,
            'Recebi sua localização. Quando formos confirmar a entrega, vou precisar também do endereço escrito.',
          );
        }
        banco.finalizarMensagem(msg.id);
        return;
      }
      // Legenda não é o conteúdo da mídia. Sem transcrição/OCR configurado,
      // nunca trate uma legenda de áudio ou imagem como se fosse o pedido
      // completo do cliente; encaminhe a mídia para avaliação humana.
      if (msg.ehMidia) {
        banco.definirModoHumano(
          msg.telefone,
          true,
          preservarDados: true,
          origem: 'ia',
          motivo: 'midia_nao_processada',
        );
        await whatsapp.enviarTexto(
          msg.telefone,
          'Recebi sua mídia, mas não consegui interpretá-la automaticamente. Encaminhei a conversa para um atendente.',
        );
        banco.finalizarMensagem(msg.id);
        return;
      }
      final resposta = msg.entrada;
      if (resposta.contains('|')) {
        final partes = resposta.split('|');
        final esperado = (sessao?['dados'] as Map?)?['promptId'];
        if (partes.length != 2 || partes.first != esperado) {
          await whatsapp.enviarTexto(
            msg.telefone,
            _modoIaAtivo
                ? 'Acho que essa resposta veio de uma etapa anterior. Pode me contar com suas palavras o que gostaria de fazer agora?'
                : 'Esta opção é de uma etapa anterior. Use a última mensagem ou digite voltar. Para começar novamente, digite 0.',
          );
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
          msg.telefone,
          _modoIaAtivo
              ? 'Pode me dizer com suas palavras como gostaria de continuar?'
              : 'Use os botões da última mensagem ou digite voltar.',
        );
        banco.finalizarMensagem(msg.id);
        return;
      }

      if (msg.entrada.isEmpty) {
        // Mensagens sem texto extraível (por exemplo, mídia sem legenda) não
        // devem gerar uma resposta automática a cada evento recebido.
        banco.finalizarMensagem(msg.id);
        return;
      }

      if (msg.enviadaEm != null &&
          DateTime.now().toUtc().difference(msg.enviadaEm!).inMinutes >
              (config['sessaoExpiraMinutos'] as num? ?? 60)) {
        banco.finalizarMensagem(msg.id);
        return;
      }

      final expirou = _sessaoExpirou(sessao, config);
      final pedidoEmAndamentoExpirou =
          expirou && sessao != null && sessao['etapa']?.toString() != 'inicio';
      if (expirou) {
        banco.excluirSessao(msg.telefone);
        sessao = null;
      }
      final entrada = _normalizar(msg.entrada);
      if (_modoIaAtivo && RegExp(r'^[\s?!.…]+$').hasMatch(msg.entrada)) {
        if (sessao != null &&
            sessao['etapa'] != 'inicio' &&
            _estadoEfetivo(config) == 'atendendo') {
          await _responderAjuda(msg, sessao);
        }
        banco.finalizarMensagem(msg.id);
        return;
      }
      // Na etapa de confirmação, "ok" e "não quero pedir" seguem a lógica de
      // confirmação, não a de agradecimento/desistência genérica.
      final etapaAtual = sessao?['etapa']?.toString() ?? 'inicio';
      final ehConfirmacao = etapaAtual == 'confirmacao';

      if (_modoIaAtivo && _ehDesistenciaExplicita(entrada)) {
        // Na confirmação, desistência explícita remove os itens do pedido
        if (ehConfirmacao) {
          _salvarInicioLimpo(
            msg.telefone,
            msg.nome,
            boasVindasEnviada: true,
          );
          await whatsapp.enviarTexto(
            msg.telefone,
            'removi todas as marmitas e bebidas. A Ao Ponto agradece! Estamos à disposição quando precisar.',
          );
        } else {
          _salvarInicioLimpo(
            msg.telefone,
            msg.nome,
            boasVindasEnviada: true,
          );
          await whatsapp.enviarTexto(
            msg.telefone,
            'A Ao Ponto agradece! Estamos à disposição quando precisar.',
          );
        }
        banco.finalizarMensagem(msg.id);
        return;
      }
      if (_modoIaAtivo && _ehAgradecimentoSimples(entrada) && !ehConfirmacao) {
        if (sessao != null &&
            sessao['etapa'] != 'inicio' &&
            _estadoEfetivo(config) == 'atendendo') {
          await whatsapp.enviarTexto(
            msg.telefone,
            'Por nada! 😊 ${_textoAjudaEtapa(sessao)}',
          );
        } else {
          _salvarInicioLimpo(
            msg.telefone,
            msg.nome,
            boasVindasEnviada: true,
          );
        }
        banco.finalizarMensagem(msg.id);
        return;
      }
      if (_modoIaAtivo &&
          _ehElogioOuComentarioPositivo(entrada) &&
          !_mensagemPedeAcaoNoPedido(entrada) &&
          !ehConfirmacao) {
        // Elogios não alteram o estado do pedido. Responde cordialmente e,
        // se houver pedido em andamento, continua de onde parou.
        if (sessao != null &&
            sessao['etapa'] != 'inicio' &&
            _estadoEfetivo(config) == 'atendendo') {
          await whatsapp.enviarTexto(
            msg.telefone,
            'Que bom que você gostou! A Ao Ponto agradece o carinho 😊 ${_textoAjudaEtapa(sessao)}',
          );
        } else {
          await whatsapp.enviarTexto(
            msg.telefone,
            'Que legal! Agradecemos pelo carinho 😊 Estamos à disposição se quiser pedir.',
          );
        }
        banco.finalizarMensagem(msg.id);
        return;
      }
      if (_modoIaAtivo && _ehReclamacao(entrada) && !ehConfirmacao) {
        // Reclamações passam para um atendente, preservando o pedido em andamento.
        banco.definirModoHumano(
          msg.telefone,
          true,
          preservarDados: true,
          origem: 'ia',
          motivo:
              _ehReclamacaoGrave(entrada) ? 'reclamacao_grave' : 'reclamacao',
        );
        if (sessao != null &&
            sessao['etapa'] != 'inicio' &&
            _estadoEfetivo(config) == 'atendendo') {
          await whatsapp.enviarTexto(
            msg.telefone,
            'Lamento muito pela experiência! 😔 Encaminhei sua conversa para um atendente, que vai verificar isso com você.',
          );
        } else {
          await whatsapp.enviarTexto(
            msg.telefone,
            'Lamento muito pela experiência! 😔 Encaminhei sua conversa para um atendente, que vai verificar isso com você.',
          );
        }
        banco.finalizarMensagem(msg.id);
        return;
      }
      if (_modoIaAtivo &&
          _ehIndecisao(entrada) &&
          !_mensagemPedeAcaoNoPedido(entrada) &&
          !ehConfirmacao &&
          etapaAtual != 'cidade_entrega') {
        // Indecisão não altera o estado do pedido. Ajuda o cliente a escolher.
        // Não interfere na etapa de cidade_entrega, onde "nao sei ainda" é uma resposta válida.
        if (sessao != null &&
            sessao['etapa'] != 'inicio' &&
            _estadoEfetivo(config) == 'atendendo') {
          await whatsapp.enviarTexto(
            msg.telefone,
            'Sem problemas! Posso ajudar você a escolher. ${_textoAjudaEtapa(sessao)}',
          );
        } else {
          final cardapio = banco.obterCardapio();
          final misturas = (cardapio['misturas'] as List? ?? const [])
              .where((e) => (e as Map)['ativo'] == true)
              .toList();
          if (misturas.isNotEmpty) {
            final sugestoes = misturas
                .take(3)
                .map((e) => '• ${(e as Map)['nome']}')
                .join('\n');
            await whatsapp.enviarTexto(
              msg.telefone,
              'Claro! Aqui estão algumas opções do cardápio:\n$sugestoes\n\nAlguma delas te agrada?',
            );
          } else {
            await whatsapp.enviarTexto(
              msg.telefone,
              'Claro! Posso ajudar você a escolher. O que você gostaria de pedir?',
            );
          }
        }
        banco.finalizarMensagem(msg.id);
        return;
      }
      if (_modoIaAtivo &&
          _ehNegacaoPedido(entrada) &&
          (sessao == null ||
              sessao['etapa'] == 'inicio' ||
              sessao['etapa'] == 'ia_pedido')) {
        final dadosSessao =
            Map<String, dynamic>.from(sessao?['dados'] as Map? ?? {});
        final precisaSaudar = sessao == null ||
            dadosSessao['aguardaBoasVindas'] == true ||
            (sessao['etapa'] == 'inicio' &&
                dadosSessao['boasVindasEnviada'] != true);
        _salvarInicioLimpo(
          msg.telefone,
          msg.nome,
          boasVindasEnviada: true,
        );
        if (precisaSaudar) {
          await whatsapp.enviarTexto(msg.telefone, _saudacaoIa());
        }
        await whatsapp.enviarTexto(
          msg.telefone,
          'Tudo bem 😊 Ainda não iniciei nenhum pedido.',
        );
        banco.finalizarMensagem(msg.id);
        return;
      }
      if (respostaIA == 'CARDAPIO_CONFIGURADO') {
        final dadosSessao =
            Map<String, dynamic>.from(sessao?['dados'] as Map? ?? {});
        final precisaSaudar = sessao == null ||
            (sessao['etapa'] == 'inicio' &&
                dadosSessao['boasVindasEnviada'] != true);
        if (precisaSaudar) {
          await whatsapp.enviarTexto(msg.telefone, _saudacaoIa());
          _salvarInicioLimpo(
            msg.telefone,
            msg.nome,
            boasVindasEnviada: true,
          );
        }
        await _mostrarCardapio(msg, config, incluirBotoes: false);
        banco.finalizarMensagem(msg.id);
        return;
      }
      if (_ehComandoAjuda(entrada)) {
        if (sessao == null && config['modoAtendimento'] == 'ia') {
          await whatsapp.enviarTexto(msg.telefone, _saudacaoIa());
        }
        await _responderAjuda(msg, sessao);
        banco.finalizarMensagem(msg.id);
        return;
      }

      if (respostaIA != null) {
        final dados = Map<String, dynamic>.from(sessao?['dados'] as Map? ?? {});
        dados.putIfAbsent('clienteNome', () => msg.nome);
        dados.putIfAbsent('itens', () => <dynamic>[]);
        final novaConversaIa = config['modoAtendimento'] == 'ia' &&
            (sessao == null ||
                (sessao['etapa'] == 'inicio' &&
                    dados['boasVindasEnviada'] != true &&
                    dados['aguardaBoasVindas'] != true));
        if (novaConversaIa) dados['boasVindasEnviada'] = true;
        banco.salvarSessao(
          telefone: msg.telefone,
          nome: msg.nome,
          etapa: sessao?['etapa']?.toString() ?? 'inicio',
          dados: dados,
        );
        if (novaConversaIa) {
          await whatsapp.enviarTexto(msg.telefone, _saudacaoIa());
        }
        await whatsapp.enviarTexto(msg.telefone, respostaIA);
        banco.finalizarMensagem(msg.id);
        return;
      }
      if (_ehComandoHumano(entrada)) {
        if (sessao == null && config['modoAtendimento'] == 'ia') {
          await whatsapp.enviarTexto(msg.telefone, _saudacaoIa());
        }
        banco.definirModoHumano(msg.telefone, true,
            origem: 'cliente', motivo: 'solicitacao_explicita');
        await whatsapp.enviarTexto(
          msg.telefone,
          _textoFluxo('sistema', 'humanoAtivado',
              'Certo! 👤 O atendimento automático foi pausado para esta conversa. Um atendente continuará por aqui.'),
        );
        banco.finalizarMensagem(msg.id);
        return;
      }
      if (sessao?['etapa'] == 'confirmar_cancelamento') {
        await _tratarConfirmarCancelamento(msg, sessao!, entrada);
        banco.finalizarMensagem(msg.id);
        return;
      }
      if (_ehComandoCancelar(entrada)) {
        if (sessao != null && sessao['etapa'] != 'inicio') {
          await _pedirConfirmacaoCancelamento(msg, sessao);
        } else {
          await _enviarBotoes(
            msg.telefone,
            _modoIaAtivo
                ? 'Como posso ajudar?'
                : 'Você ainda não iniciou um pedido. Escolha uma opção:',
            _botoesInicio(),
          );
        }
        banco.finalizarMensagem(msg.id);
        return;
      }

      if (_modoIaAtivo &&
          sessao != null &&
          (sessao['etapa'] == 'adicionar_outro' ||
              sessao['etapa'] == 'ia_pedido') &&
          _ehPararDeAdicionarMarmitas(entrada) &&
          _descartarRascunhoProximaMarmita(sessao)) {
        final dados = Map<String, dynamic>.from(sessao['dados'] as Map? ?? {});
        dados.remove('itemAtual');
        dados.remove('rascunhoPedidoIA');
        dados['itens'] = (dados['itens'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        banco.salvarSessao(
          telefone: msg.telefone,
          nome: msg.nome,
          etapa: 'recebimento',
          dados: dados,
        );
        await whatsapp.enviarTexto(
          msg.telefone,
          'Tudo bem, vou deixar só as marmitas que já escolhemos.',
        );
        await _mostrarRecebimento(msg, config, dados);
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
          aviso: pedidoEmAndamentoExpirou
              ? '⏱️ Seu pedido anterior expirou por inatividade.'
              : null,
          forcarBoasVindas: true,
        );
        banco.finalizarMensagem(msg.id);
        return;
      }

      if (_modoIaAtivo && _ehSolicitacaoCardapio(entrada)) {
        final dadosSessao =
            Map<String, dynamic>.from(sessao?['dados'] as Map? ?? {});
        final precisaSaudar = sessao == null ||
            (sessao['etapa'] == 'inicio' &&
                dadosSessao['boasVindasEnviada'] != true);
        if (precisaSaudar) {
          await whatsapp.enviarTexto(msg.telefone, _saudacaoIa());
          dadosSessao['boasVindasEnviada'] = true;
          dadosSessao.remove('aguardaBoasVindas');
          dadosSessao.putIfAbsent('clienteNome', () => msg.nome);
          dadosSessao.putIfAbsent('itens', () => <dynamic>[]);
          banco.salvarSessao(
            telefone: msg.telefone,
            nome: msg.nome,
            etapa: sessao?['etapa']?.toString() ?? 'inicio',
            dados: dadosSessao,
          );
        }
        await _mostrarCardapio(msg, config, incluirBotoes: false);
        banco.finalizarMensagem(msg.id);
        return;
      }

      if (_modoIaAtivo &&
          sessao != null &&
          sessao['etapa'] != 'inicio' &&
          _ehSaudacaoSimples(entrada)) {
        // Em uma sessão já ativa, uma saudação não inicia uma nova conversa.
        // Responde apenas com a pergunta útil da etapa atual.
        await _responderAjuda(msg, sessao);
        banco.finalizarMensagem(msg.id);
        return;
      }

      if (sessao != null && _ehSolicitacaoCardapio(entrada)) {
        if (!_modoIaAtivo && sessao['etapa'] == 'inicio') {
          final dadosMenu =
              Map<String, dynamic>.from(sessao['dados'] as Map? ?? {});
          dadosMenu['opcoesInicioAposCardapio'] = true;
          banco.salvarSessao(
            telefone: msg.telefone,
            nome: msg.nome,
            etapa: 'inicio',
            dados: dadosMenu,
          );
        }
        // O caminho de IA retorna acima e envia apenas texto. Aqui preservamos
        // os botões do modo Bot após uma solicitação textual do cardápio.
        await _mostrarCardapio(msg, config);
        banco.finalizarMensagem(msg.id);
        return;
      }

      if (sessao != null &&
          sessao['etapa'] != 'ia_pedido' &&
          (_ehComandoVoltar(entrada) || _ehComandoCorrigir(entrada))) {
        await _voltar(msg, config, sessao);
        banco.finalizarMensagem(msg.id);
        return;
      }

      if (pedidoIA != null) {
        final bebida = pedidoIA['_adicionarBebidaResumo'];
        if (bebida is Map) {
          await _adicionarBebidaAoResumo(msg, config, sessao, bebida);
          banco.finalizarMensagem(msg.id);
          return;
        }
        await _processarPedidoIA(msg, config, sessao, pedidoIA);
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
    final minutos = (config['sessaoExpiraMinutos'] as num?)?.toInt() ?? 60;
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
    bool forcarBoasVindas = false,
  }) async {
    final dados = <String, dynamic>{
      'clienteNome': msg.nome,
      'itens': <dynamic>[],
      if (config['modoAtendimento'] == 'ia') 'boasVindasEnviada': true,
    };
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'inicio',
      dados: dados,
    );

    final entrada = _normalizar(msg.entrada);
    final opcaoInicio = _resolverOpcaoInicio(entrada);
    if (aviso == null && !forcarBoasVindas && opcaoInicio != null) {
      if (config['modoAtendimento'] == 'ia') {
        await whatsapp.enviarTexto(msg.telefone, _saudacaoIa());
      }
      await _tratarInicio(msg, config, dados, opcaoInicio);
      return;
    }

    final mensagens =
        Map<String, dynamic>.from(config['mensagens'] as Map? ?? {});
    final boasVindas = (mensagens['boasVindas'] ??
            'Olá! 👋 Bem-vindo à ${config['nomeEstabelecimento']}.')
        .toString()
        .trim();
    final pergunta =
        _textoFluxo('inicio', 'mensagem', 'Como podemos ajudar?').trim();
    if (_modoIaAtivo) {
      await whatsapp.enviarTexto(msg.telefone, _saudacaoIa());
      if (aviso?.trim().isNotEmpty ?? false) {
        await whatsapp.enviarTexto(msg.telefone, aviso!.trim());
      }
      await whatsapp.enviarTexto(msg.telefone, 'O que você gostaria?');
      return;
    }
    final linhas = <String>[
      if (aviso?.trim().isNotEmpty ?? false) aviso!.trim(),
      boasVindas,
      pergunta,
      '💡 Durante o pedido, você pode usar *VOLTAR*, *CANCELAR* ou *ATENDENTE* quando precisar.',
    ];
    await _enviarBotoes(
      msg.telefone,
      linhas.join('\n\n'),
      _botoesInicio(),
    );
  }

  void _salvarInicioLimpo(
    String telefone,
    String nome, {
    bool boasVindasNaProximaMensagem = false,
    bool boasVindasEnviada = false,
  }) {
    banco.salvarSessao(
      telefone: telefone,
      nome: nome,
      etapa: 'inicio',
      dados: {
        'clienteNome': nome,
        'itens': <dynamic>[],
        if (boasVindasEnviada) 'boasVindasEnviada': true,
        if (boasVindasNaProximaMensagem) 'aguardaBoasVindas': true,
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

  String? _resolverOpcaoInicio(String entrada) {
    final texto = _normalizar(entrada);
    if (_corresponde(texto, [
      'inicio_pedido',
      if (!_modoIaAtivo) '1',
      'fazer pedido',
      'pedido',
      _textoFluxo('inicio', 'botaoPedido', 'Fazer pedido'),
    ])) {
      return 'inicio_pedido';
    }
    if (_corresponde(texto, [
      'inicio_cardapio',
      if (!_modoIaAtivo) '2',
      'ver cardapio',
      'cardapio',
      _textoFluxo('inicio', 'botaoCardapio', 'Ver cardápio'),
    ])) {
      return 'inicio_cardapio';
    }
    if (_corresponde(texto, [
      'inicio_humano',
      if (!_modoIaAtivo) '3',
      'falar atendente',
      'atendente',
      _textoFluxo('inicio', 'botaoHumano', 'Falar atendente'),
    ])) {
      return 'inicio_humano';
    }

    if (_contemTermo(texto, ['nao', 'nunca', 'sem'])) return null;

    if (_ehSolicitacaoCardapio(texto)) {
      return 'inicio_cardapio';
    }

    final falaDePedido = _contemTermo(texto, [
      'pedido',
      'pedir',
      'marmita',
      'marmitas',
      'almoco',
      'almocar',
      'refeicao',
      'refeicoes',
      'comida',
      'comprar',
      'encomendar',
    ]);
    final expressaIntencaoDeComprar = _contemTermo(texto, [
      'quero',
      'queria',
      'gostaria',
      'vou',
      'fazer',
      'pedir',
      'comprar',
      'encomendar',
      'montar',
      'preciso',
    ]);
    if (falaDePedido && expressaIntencaoDeComprar) return 'inicio_pedido';
    return null;
  }

  bool _ehSolicitacaoCardapio(String entrada) {
    var texto = _normalizarIntencao(entrada);
    texto = texto.replaceFirst(
      RegExp(
        r'^(?:(?:acho que|creio que|estava pensando|tava pensando|estou pensando|to pensando|eu queria saber|queria saber|me diz|me fala|fala pra mim|diz pra mim)\s+)+',
      ),
      '',
    );
    texto = texto
        .replaceAll(RegExp(r'[,;.!]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    texto = texto.replaceFirst(
      RegExp(
        r'^(?:(?:oi|ola|bom dia|boa tarde|boa noite|e ai|eae|opa)\s+)+',
      ),
      '',
    );
    texto = texto.replaceFirst(
      RegExp(
          r'^(?:(?:vou pedir|quero pedir|queria pedir|acho que vou pedir)\s+)+'),
      '',
    );
    if (_corresponde(texto, [
      'o que tem hoje',
      'oq tem hoje',
      'o que tem hj',
      'oq tem hj',
      'que tem hoje',
      'q tem hj',
      'que tem hj',
      'o que tem de bom hoje',
      'oq tem de bom hoje',
      'o que tem de bom hj',
      'oq tem de bom hj',
      'que tem de bom hoje',
      'o que temos hoje',
      'o que tem de bom pra hoje',
      'o que tem de bom para hoje',
      'oq tem pra hoje',
      'o que tem pra hoje',
      'o que tem para hoje',
      'tem o que hoje',
      'qual cardapio tem',
      'qual o cardapio tem',
      'qual cardapio tem hoje',
      'qual o cardapio de hoje',
      'o que tem no cardapio',
      'oq tem no cardapio',
      'que tem no cardapio',
      'o que tem no menu',
      'oq tem no menu',
      'quais opcoes tem no cardapio',
      'quais opcoes tem hoje',
      'quais opcoes de hoje',
      'cardapio de hoje',
      'quero ver',
      'quero olhar',
      'o que tem',
      'que tem',
      'o que voce tem',
      'o que voces tem',
      'que voce tem',
      'que voces tem',
      'quais opcoes tem',
      'quais sao as opcoes',
      'quais as opcoes',
      'o que tem para comer',
      'que tem para comer',
      'o que voces fazem',
      'o que voces oferecem',
    ])) {
      return true;
    }
    // Perguntas naturais sobre o que há para comer hoje pedem o cardápio,
    // mesmo sem a palavra "cardápio" e mesmo com abreviações comuns.
    if (RegExp(
      r'^(?:(?:o que|que) (?:(?:voces|voce) )?tem(?: de bom)?(?: para comer)?(?: para hoje| hoje)?|(?:o que|que) vai ter hoje|tem (?:o que|que) hoje|quais (?:sao )?(?:as )?opcoes(?: (?:de )?hoje| voces tem)?|o que tem para almoco hoje)$',
    ).hasMatch(texto)) {
      return true;
    }
    if (!_contemTermo(texto, ['cardapio', 'menu'])) return false;
    if (_corresponde(texto, [
      'cardapio',
      'menu',
      'ver cardapio',
      'ver menu',
      'ver o cardapio',
      'ver o menu',
      'cardapio por favor',
      'menu por favor',
      'quero o cardapio',
      'quero cardapio',
      'quero o menu',
      'quero menu',
      'queria o cardapio',
      'gostaria do cardapio',
    ])) {
      return true;
    }
    if (_contemTermo(texto, ['cardapio', 'menu']) &&
        _contemTermo(texto, [
          'quero',
          'queria',
          'gostaria',
          'manda',
          'mandar',
          'envia',
          'enviar',
          'mostra',
          'mostrar',
          'passa',
          'passar',
          'ver',
        ])) {
      return true;
    }
    return RegExp(
      r'^(?:por favor )?(?:(?:me )?(?:manda|envia|mostra|passa|compartilha)|(?:pode|poderia) (?:me )?(?:mandar|enviar|mostrar|passar|compartilhar)|(?:voces|vcs|voce|vc) (?:podem|pode) (?:me )?(?:mandar|enviar|mostrar|passar)|(?:quero|queria|gostaria de) (?:ver|receber)|(?:ver|consultar) (?:o )?(?:cardapio|menu)|(?:gostaria|queria) (?:do|de receber) (?:o )?(?:cardapio|menu))\b',
    ).hasMatch(texto);
  }

  String _normalizarIntencao(String entrada) {
    var texto = _normalizar(entrada)
        .replaceAll(RegExp(r'\b(?:oq|o q)\b'), 'o que')
        .replaceAll(RegExp(r'\boque\b'), 'o que')
        .replaceAll(RegExp(r'\boe(?=\s+tem\b)'), 'o que')
        .replaceAll(RegExp(r'\bq\b'), 'que')
        .replaceAll(RegExp(r'\bhj\b'), 'hoje')
        .replaceAll(RegExp(r'\bpra\b'), 'para')
        .replaceAll(RegExp(r'\bvou quere\b'), 'vou querer')
        .replaceAll(RegExp(r'\bpfv\b'), 'por favor')
        .replaceAll(RegExp(r'\bvc\b'), 'voce')
        .replaceAll(RegExp(r'\bvcs\b'), 'voces')
        .replaceAll(RegExp(r'\bcardapioo?\b'), 'cardapio');
    return texto.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  bool _ehAgradecimentoSimples(String entrada) {
    final norm =
        _normalizar(entrada).replaceAll(RegExp(r'[^a-z\s]'), '').trim();
    if (norm.isEmpty) return false;
    final words = norm.split(RegExp(r'\s+'));
    final validWords = {
      'ok',
      'ta',
      'bom',
      'tabom',
      'beleza',
      'blz',
      'joia',
      'maravilha',
      'show',
      'valeu',
      'vlw',
      'obrigado',
      'obrigada',
      'obg',
      'obgd',
      'agradeco',
      'agradecido',
      'agradecida',
      'obrigadinho',
      'obrigadinha',
      'valeuzinho',
      'valeuzinha',
      'agradecimento',
      'agradecimentos',
      'obrigacoes',
      'obrigacao',
      'valeumesmo',
      'obrigadomesmo',
      'obrigadamesmo',
      'muitobrigado',
      'muitobrigada',
      'muitissimoobrigado',
      'muitissimoobrigada',
      'obrigadopelaajuda',
      'obrigadapelaajuda',
      'obrigadopelaatencao',
      'obrigadapelaatencao',
      'valeupelaajuda',
      'valeupelaatencao',
      'agradecopelaajuda',
      'agradecopelaatencao',
      'obrigadopeloatendimento',
      'obrigadapeloatendimento',
      'valeupeloatendimento',
      'agradecopeloatendimento',
      'obrigadopelacomida',
      'obrigadapelacomida',
      'valeupelacomida',
      'agradecopelacomida',
      'obrigadopelaentrega',
      'obrigadapelaentrega',
      'valeupelaentrega',
      'agradecopelaentrega',
      'obrigadopeloservico',
      'obrigadapeloservico',
      'valeupeloservico',
      'agradecopeloservico',
      'obrigadopelacarinho',
      'obrigadapelacarinho',
      'valeupelacarinho',
      'agradecopelacarinho',
      'obrigadopelapreferencia',
      'obrigadapelapreferencia',
      'valeupelapreferencia',
      'agradecopelapreferencia',
      'obrigadopelaconfianca',
      'obrigadapelaconfianca',
      'valeupelaconfianca',
      'agradecopelaconfianca',
      'obrigadopelaoportunidade',
      'obrigadapelaoportunidade',
      'valeupelaoportunidade',
      'agradecopelaoportunidade',
      'obrigadopelaparceria',
      'obrigadapelaparceria',
      'valeupelaparceria',
      'agradecopelaparceria',
      'obrigadopelaamizade',
      'obrigadapelaamizade',
      'valeupelaamizade',
      'agradecopelaamizade',
      'obrigadopelacompanhia',
      'obrigadapelacompanhia',
      'valeupelacompanhia',
      'agradecopelacompanhia',
      'obrigadopelapresenca',
      'obrigadapelapresenca',
      'valeupelapresenca',
      'agradecopelapresenca',
      'obrigadopelavisita',
      'obrigadapelavisita',
      'valeupelavisita',
      'agradecopelavisita',
      'obrigadopelocontato',
      'obrigadapelocontato',
      'valeupelocontato',
      'agradecopelocontato',
      'obrigadopeloretorno',
      'obrigadapeloretorno',
      'valeupeloretorno',
      'agradecopeloretorno',
      'obrigadopeladedicacao',
      'obrigadapeladedicacao',
      'valeupeladedicacao',
      'agradecopeladedicacao',
      'obrigadopeloempenho',
      'obrigadapeloempenho',
      'valeupeloempenho',
      'agradecopeloempenho',
      'obrigadopeloprofissionalismo',
      'obrigadapeloprofissionalismo',
      'valeupeloprofissionalismo',
      'agradecopeloprofissionalismo',
      'obrigadopelqualidade',
      'obrigadapelqualidade',
      'valeupelqualidade',
      'agradecopelqualidade',
      'obrigadopelosabor',
      'obrigadapelosabor',
      'valeupelosabor',
      'agradecopelosabor',
      'obrigadopelotempero',
      'obrigadapelotempero',
      'valeupelotempero',
      'agradecopelotempero',
      'obrigadopelocapricho',
      'obrigadapelocapricho',
      'valeupelocapricho',
      'agradecopelocapricho',
      'obrigadopelocuidado',
      'obrigadapelocuidado',
      'valeupelocuidado',
      'agradecopelocuidado',
      'obrigadopelozelo',
      'obrigadapelozelo',
      'valeupelozelo',
      'agradecopelozelo',
      'obrigadopelocomprometimento',
      'obrigadapelocomprometimento',
      'valeupelocomprometimento',
      'agradecopelocomprometimento',
      'obrigadopelaseriedade',
      'obrigadapelaseriedade',
      'valeupelaseriedade',
      'agradecopelaseriedade',
      'obrigadopelahonestidade',
      'obrigadapelahonestidade',
      'valeupelahonestidade',
      'agradecopelahonestidade',
      'obrigadopelatransparencia',
      'obrigadapelatransparencia',
      'valeupelatransparencia',
      'agradecopelatransparencia',
      'obrigadopelaclareza',
      'obrigadapelaclareza',
      'valeupelaclareza',
      'agradecopelaclareza',
      'obrigadopelaobjetividade',
      'obrigadapelaobjetividade',
      'valeupelaobjetividade',
      'agradecopelaobjetividade',
      'obrigadopelaeficiencia',
      'obrigadapelaeficiencia',
      'valeupelaeficiencia',
      'agradecopelaeficiencia',
      'obrigadopelaagilidade',
      'obrigadapelaagilidade',
      'valeupelaagilidade',
      'agradecopelaagilidade',
      'obrigadopelapontualidade',
      'obrigadapelapontualidade',
      'valeupelapontualidade',
      'agradecopelapontualidade',
      'obrigadopelarapidez',
      'obrigadapelarapidez',
      'valeupelarapidez',
      'agradecopelarapidez',
      'obrigadopelapresteza',
      'obrigadapelapresteza',
      'valeupelapresteza',
      'agradecopelapresteza',
      'obrigadopelasolicitude',
      'obrigadapelasolicitude',
      'valeupelasolicitude',
      'agradecopelasolicitude',
      'obrigadopelagentileza',
      'obrigadapelagentileza',
      'valeupelagentileza',
      'agradecopelagentileza',
      'obrigadopelasimpatia',
      'obrigadapelasimpatia',
      'valeupelasimpatia',
      'agradecopelasimpatia',
      'obrigadopelaeducacao',
      'obrigadapelaeducacao',
      'valeupelaeducacao',
      'agradecopelaeducacao',
      'obrigadopelacordialidade',
      'obrigadapelacordialidade',
      'valeupelacordialidade',
      'agradecopelacordialidade',
      'obrigadopelahospitalidade',
      'obrigadapelahospitalidade',
      'valeupelahospitalidade',
      'agradecopelahospitalidade',
      'obrigadopelareceptividade',
      'obrigadapelareceptividade',
      'valeupelareceptividade',
      'agradecopelareceptividade',
    };
    // Agradecimento simples só deve ser correspondido se TODAS as palavras da mensagem fizerem parte deste dicionário restrito de "agradecimentos/confirmações vazias".
    // Isso evita que "ok confirmar pedido" ou "ok obg quero pedir" seja tratado como um agradecimento isolado.
    return words.every((w) => validWords.contains(w));
  }

  bool _ehElogioOuComentarioPositivo(String entrada) {
    final texto = _normalizarIntencao(entrada);

    // Padrões de elogio sobre comida/qualidade
    final padroesElogio = [
      r'\b(?:tava|estava|ta|esta|foi|era|sera)\s+(?:uma\s+)?(?:delicia|delicioso|maravilha|maravilhoso|otimo|otima|excelente|perfeito|perfeita|top|show|bom|boa|gostoso|gostosa|saboroso|saborosa|apetitoso|apetitosa)\b',
      r'\b(?:gostei|amei|adorei|adoro|amo)\s+(?:muito|demais|bastante)?\b',
      r'\b(?:muito|super|bem|tao)\s+(?:bom|boa|gostoso|gostosa|delicioso|delicia|maravilha|otimo|otima)\b',
      r'\b(?:que\s+)?(?:delicia|maravilha|otimo|otima|perfeito|perfeita|top|show)\b',
      r'\b(?:comida|prato|marmita|almoco|refeicao)\s+(?:otima|otimo|boa|bom|deliciosa|delicioso|maravilhosa|maravilhoso|saborosa|saboroso)\b',
      r'\b(?:chegou|entrega)\s+(?:rapido|rapida|veloz)\b',
      r'\b(?:rapido|rapida|veloz)\s+(?:entrega|chegou|demora)\b',
      r'\b(?:entrega|chegou|demora)\s+(?:rapido|rapida|veloz)\b',
      r'\b(?:meu|minha|amigo|amiga|irmao|irma|marido|esposa|pai|mae|filho|filha)\s+(?:indicou|recomendou|falou|disse|gostou|adorou|amo)\b',
      r'\b(?:indicacao|recomendacao)\s+(?:de|do|da)\s+(?:meu|minha|amigo|amiga|irmao|irma|marido|esposa|pai|mae|filho|filha)\b',
      r'\b(?:falou|disse)\s+(?:que\s+)?(?:era|foi|tava|ta|esta)\s+(?:bom|boa|otimo|otima|delicioso|delicia|maravilha|gostoso|gostosa)\b',
      r'\b(?:pedi|comprei|comi|experimentei|provei)\s+(?:ontem|hoje|anteontem|semana\s+passada|mes\s+passado|outro\s+dia)\b.*\b(?:tava|estava|foi|era|ta|esta)\s+(?:bom|boa|otimo|otima|delicioso|delicia|maravilha|gostoso|gostosa)\b',
      r'\b(?:vou|quero|queria|gostaria)\s+(?:pedir|comprar|encomendar)\s+(?:de\s+novo|novamente|outra\s+vez|mais\s+uma)\b',
      r'\b(?:sempre|todas\s+as\s+vezes)\s+(?:peço|pedido|compro|encomendo)\b',
      r'\b(?:parabens|pela\s+comida|pelo\s+atendimento|pela\s+entrega)\b',
      r'\b(?:nota\s+10|nota\s+100|nota\s+1000|5\s+estrelas|5\s+stars)\b',
      r'\b(?:show|top|perfeito|perfeita|excelente|otimo|otima|maravilha|maravilhoso|maravilhosa)\b',
      r'\b(?:valeu|obrigado|obrigada|agradeço|agradecido|agradecida)\s+(?:mesm[oa]|demais|bastante)\b',
      r'\b(?:adorei|amei|gostei)\s+(?:muito|demais|bastante)\b',
      r'\b(?:muito|super|bem|tao)\s+(?:bom|boa|gostoso|gostosa|delicioso|delicia|maravilha|otimo|otima)\b',
      r'\b(?:que\s+)?(?:delicia|maravilha|otimo|otima|perfeito|perfeita|top|show)\b',
      r'\b(?:comida|prato|marmita|almoco|refeicao)\s+(?:otima|otimo|boa|bom|deliciosa|delicioso|maravilhosa|maravilhoso|saborosa|saboroso)\b',
      r'\b(?:chegou|entrega)\s+(?:rapido|rapida|veloz)\b',
      r'\b(?:rapido|rapida|veloz)\s+(?:entrega|chegou|demora)\b',
      r'\b(?:entrega|chegou|demora)\s+(?:rapido|rapida|veloz)\b',
      r'\b(?:meu|minha|amigo|amiga|irmao|irma|marido|esposa|pai|mae|filho|filha)\s+(?:indicou|recomendou|falou|disse|gostou|adorou|amo)\b',
      r'\b(?:indicacao|recomendacao)\s+(?:de|do|da)\s+(?:meu|minha|amigo|amiga|irmao|irma|marido|esposa|pai|mae|filho|filha)\b',
      r'\b(?:falou|disse)\s+(?:que\s+)?(?:era|foi|tava|ta|esta)\s+(?:bom|boa|otimo|otima|delicioso|delicia|maravilha|gostoso|gostosa)\b',
      r'\b(?:pedi|comprei|comi|experimentei|provei)\s+(?:ontem|hoje|anteontem|semana\s+passada|mes\s+passado|outro\s+dia)\b.*\b(?:tava|estava|foi|era|ta|esta)\s+(?:bom|boa|otimo|otima|delicioso|delicia|maravilha|gostoso|gostosa)\b',
      r'\b(?:vou|quero|queria|gostaria)\s+(?:pedir|comprar|encomendar)\s+(?:de\s+novo|novamente|outra\s+vez|mais\s+uma)\b',
      r'\b(?:sempre|todas\s+as\s+vezes)\s+(?:peço|pedido|compro|encomendo)\b',
      r'\b(?:parabens|pela\s+comida|pelo\s+atendimento|pela\s+entrega)\b',
      r'\b(?:nota\s+10|nota\s+100|nota\s+1000|5\s+estrelas|5\s+stars)\b',
      r'\b(?:show|top|perfeito|perfeita|excelente|otimo|otima|maravilha|maravilhoso|maravilhosa)\b',
      r'\b(?:valeu|obrigado|obrigada|agradeço|agradecido|agradecida)\s+(?:mesm[oa]|demais|bastante)\b',
      r'\b(?:adorei|amei|gostei)\s+(?:muito|demais|bastante)\b',
    ];

    for (final padrao in padroesElogio) {
      if (RegExp(padrao, caseSensitive: false).hasMatch(texto)) {
        return true;
      }
    }

    // Verifica palavras-chave de elogio
    final palavrasElogio = {
      'delicia',
      'delicioso',
      'deliciosa',
      'maravilha',
      'maravilhoso',
      'maravilhosa',
      'otimo',
      'otima',
      'excelente',
      'perfeito',
      'perfeita',
      'top',
      'show',
      'gostoso',
      'gostosa',
      'saboroso',
      'saborosa',
      'apetitoso',
      'apetitosa',
      'rapido',
      'rapida',
      'veloz',
      'indico',
      'indicao',
      'recomendo',
      'recomendacao',
      'parabens',
      'nota10',
      'nota100',
      'nota1000',
      '5estrelas',
      '5stars',
      'gostei',
      'amei',
      'adorei',
      'adoro',
      'amo',
      'adorado',
      'adorada',
      'feliz',
      'satisfeito',
      'satisfeita',
      'contente',
      'encantado',
      'encantada',
      'surpreendido',
      'surpreendida',
      'impressionado',
      'impressionada',
    };

    final palavras = texto.split(RegExp(r'\s+'));
    for (final palavra in palavras) {
      final limpa = palavra.replaceAll(RegExp(r'[^a-z]'), '');
      if (palavrasElogio.contains(limpa)) {
        return true;
      }
    }

    return false;
  }

  bool _ehDesistenciaExplicita(String entrada) {
    final norm = _normalizar(entrada);
    return RegExp(
          r'^(?:(?:eu\s+|por favor\s+)?(?:deixa\s+qu[ei]eto|deixa\s+pra\s*l[aã]|n[aã]o\s+vou\s+(?:pedir|querer)(?:\s+mais)?|desist[io](?:mos)?|cancela\s+tudo|esquece(?:r)?|nao\s+quero\s+(?:pedir|querer)|nao\s+vou\s+(?:pedir|querer)|desist[io]\s+do\s+pedido|cancela\s+(?:meu\s+)?pedido|para\s+(?:tudo|com\s+isso)|encerra\s+(?:meu\s+)?pedido|quero\s+encerrar|quero\s+parar|nao\s+quero\s+mais\s+nada|nao\s+quero\s+continuar|quero\s+cancelar\s+(?:meu\s+)?pedido|cancela\s+tudo|esquece(?:r)?)(?:\s+(?:obg|obrigado|obrigada|valeu|pfv|por\s+favor))?)$',
        ).hasMatch(norm) ||
        _correspondeIntencao(entrada, [
          'deixa quieto',
          'deixa queto',
          'deixa pra la',
          'nao vou pedir',
          'nao vou querer',
          'nao vou querer mais',
          'desisti',
          'desistimos',
          'desisto',
          'cancela tudo',
          'esquece',
          'nao quero pedir',
          'nao quero querer',
          'desisto do pedido',
          'cancela meu pedido',
          'para tudo',
          'para com isso',
          'encerra meu pedido',
          'quero encerrar',
          'quero parar',
          'nao quero mais nada',
          'nao quero continuar',
          'quero cancelar meu pedido',
          'cancela tudo',
          'esquece',
          'deixa quieto obg',
          'deixa quieto obrigado',
          'deixa quieto obrigada',
          'deixa quieto valeu',
          'deixa queto obg',
          'deixa queto obrigado',
          'deixa queto obrigada',
          'deixa queto valeu',
          'deixa pra la obg',
          'deixa pra la obrigado',
          'deixa pra la obrigada',
          'deixa pra la valeu',
          'nao vou pedir obg',
          'nao vou pedir obrigado',
          'nao vou pedir obrigada',
          'nao vou pedir valeu',
          'nao vou querer obg',
          'nao vou querer obrigado',
          'nao vou querer obrigada',
          'nao vou querer valeu',
          'desisti obg',
          'desisti obrigado',
          'desisti obrigada',
          'desisti valeu',
          'desisto obg',
          'desisto obrigado',
          'desisto obrigada',
          'desisto valeu',
          'cancela tudo obg',
          'cancela tudo obrigado',
          'cancela tudo obrigada',
          'cancela tudo valeu',
          'esquece obg',
          'esquece obrigado',
          'esquece obrigada',
          'esquece valeu',
        ]);
  }

  bool _ehNegacaoPedido(String entrada) => _corresponde(entrada, [
        'nem pedi nada',
        'nao pedi nada',
        'nao pedi',
        'nem pedi',
        'nao quero pedir',
        'nao vou pedir',
        'esquece o pedido',
        'esquece pedido',
      ]);

  bool _ehReclamacao(String entrada) {
    final texto = _normalizarIntencao(entrada);
    if (_ehReclamacaoGrave(entrada)) return true;
    final padroes = [
      r'\b(?:nao\s+gostei|pessim[oa]|horrivel|horroros[oa]|nojent[oa]|estragad[oa]|vencid[oa]|sem\s+sabor|gosto\s+ruim|nao\s+recomendo|nao\s+voltarei|nunca\s+mais|decepcionad[oa]|decepcao|frustrad[oa]|irritad[oa]|chatead[oa]|insatisfeit[oa]|indignad[oa]|revoltad[oa]|furios[oa]|estou\s+brav[oa]|to\s+put[oa]|falta\s+de\s+respeito|que\s+absurdo|sacanagem|ridicul[oa])\b',
      r'\b(?:pedido|item|comida|marmita|entrega)\b.{0,35}\b(?:ruim|errad[oa]|trocad[oa]|faltando|em\s+falta|diferente)\b',
      r'\b(?:ruim|errad[oa]|trocad[oa]|faltando|em\s+falta|diferente)\b.{0,35}\b(?:pedido|item|comida|marmita|entrega)\b',
      r'\b(?:comida|marmita|pedido|bebida|chegou|veio)\b.{0,25}\b(?:fri[oa]|morn[oa]|gelad[oa]|derramad[oa]|vazand[oa])\b',
      r'\b(?:fri[oa]|morn[oa]|gelad[oa]|derramad[oa]|vazand[oa])\b.{0,25}\b(?:comida|marmita|pedido|bebida|entrega)\b',
      r'\b(?:faltou|nao\s+veio|nao\s+chegou)\b.{0,40}\b(?:pedido|item|comida|marmita|bebida|entrega)\b',
      r'\b(?:entrega|entregador|motoboy|pedido)\b.{0,30}\b(?:demorad[oa]|atrasad[oa]|atraso|atrasou|demorou\s+(?:muito|demais))\b',
      r'\b(?:pedido|item|marmita|bebida)\b.{0,30}\b(?:incompleto|faltando|veio\s+faltando)\b',
      r'\b(?:preco|valor|custo)\b.{0,25}\b(?:alto|car[oa]|absurdo|exorbitante|abusivo)\b',
      r'\b(?:car[oa]|carissimo|abusivo)\b.{0,25}\b(?:preco|valor|custo|marmita|pedido)\b',
      r'\b(?:atendimento|atendente|servico)\b.{0,25}\b(?:ruim|pessim[oa]|horrivel|lento|demorad[oa])\b',
    ];
    return padroes
        .any((padrao) => RegExp(padrao, caseSensitive: false).hasMatch(texto));
  }

  bool _ehReclamacaoGrave(String entrada) {
    final texto = _normalizarIntencao(entrada);
    return RegExp(
      r'\b(?:alergia|alergico|alergica|intoxicacao|passei mal|passei muito mal|vomitei|vomito|diarreia|hospital|hospitalar|medico|ameaça|ameaca|policia|procon|processo|denuncia|fraude|golpe|racismo|agressao|perigo|contaminad[oa])\b',
      caseSensitive: false,
    ).hasMatch(texto);
  }

  bool _mensagemPedeAcaoNoPedido(String entrada) {
    final texto = _normalizarIntencao(entrada);
    final acao = RegExp(
      r'\b(?:quero|queria|gostaria|pedir|peco|vou\s+pedir|vou\s+querer|adiciona(?:r)?|inclui(?:r)?|coloca(?:r)?|troca(?:r)?|muda(?:r)?|substitui(?:r)?|prefiro|escolho|monta(?:r)?)\b',
    ).hasMatch(texto);
    if (!acao) return false;
    return RegExp(
          r'\b(?:marmita|marmitas|pequena|pequeno|media|medio|grande|mistura|misturas|acompanhamento|acompanhamentos|bebida|bebidas|frango|carne|calabresa|bife|pernil|linguica|batata|macarrao|arroz|feijao|pedido|outra|mais\s+uma)\b',
        ).hasMatch(texto) ||
        RegExp(r'\b(?:adiciona|adicionar|inclui|incluir|troca|trocar|muda|mudar|substitui|substituir)\b')
            .hasMatch(texto);
  }

  bool _ehIndecisao(String entrada) {
    final texto = _normalizarIntencao(entrada);
    return RegExp(
          r'\b(?:nao\s+sei(?:\s+(?:qual|o\s+que|oq|o\s+que\s+pedir|oq\s+pedir|oq\s+escolher))?|n\s+sei|sei\s+la|nao\s+tenho\s+certeza|estou\s+em\s+duvida|nao\s+decidi|tanto\s+faz|qualquer\s+uma)\b',
        ).hasMatch(texto) ||
        RegExp(
          r'\b(?:pode|poderia|consegue|conseguiria)\s+(?:me\s+)?ajudar\b|\bme\s+ajuda\b|\bajuda\s+(?:a|pra|para)\s+(?:escolher|decidir|pedir)\b|\b(?:me\s+)?(?:da|de)\s+uma?\s+(?:sugestao|dica)\b|\b(?:alguma|uma)\s+(?:sugestao|dica)\b|\b(?:qual|o\s+que|oq)\s+(?:(?:voce|voces|vc|vcs)\s+)?(?:recomenda|sugere|acha\s+melhor)\b|\bqual\s+(?:e\s+)?(?:a\s+)?(?:melhor|mais\s+popular|mais\s+pedido|mais\s+vendida|mais\s+barata)\b',
        ).hasMatch(texto);
  }

  bool _ehSaudacaoSimples(String entrada) => RegExp(
        r'^(?:(?:oi+|ola|oie|opa|salve|e ai|eae|opa|opa|bom dia|boa tarde|boa noite|tudo bem|tudo bom|tudo certo|tudo joia|tudo otimo|como vai|como ta|como\s+esta|como\s+estan|blz|beleza|joinha|joia|show|top|valeu|obrigado|obrigada|obg|obgd|agradeco|agradecido|agradecida)(?:\s+(?:oi+|ola|oie|opa|salve|e ai|eae|opa|opa|bom dia|boa tarde|boa noite|tudo bem|tudo bom|tudo certo|tudo joia|tudo otimo|como vai|como ta|como\s+esta|como\s+estan|blz|beleza|joinha|joia|show|top|valeu|obrigado|obrigada|obg|obgd|agradeco|agradecido|agradecida))*)$',
      ).hasMatch(_normalizar(entrada));

  Future<void> _continuar(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> sessao,
  ) async {
    final etapa = sessao['etapa']?.toString() ?? 'inicio';
    final dados = Map<String, dynamic>.from(sessao['dados'] as Map? ?? {});
    final entrada = _normalizar(msg.entrada);

    if (etapa == 'inicio' && dados.remove('aguardaBoasVindas') == true) {
      // Não reinicie nem descarte a mensagem que motivou a retomada.
      dados['boasVindasEnviada'] = true;
      banco.salvarSessao(
        telefone: msg.telefone,
        nome: msg.nome,
        etapa: 'inicio',
        dados: dados,
      );
    }

    switch (etapa) {
      case 'inicio':
        await _tratarInicio(msg, config, dados, entrada);
        break;
      case 'ia_pedido':
        banco.salvarSessao(
          telefone: msg.telefone,
          nome: msg.nome,
          etapa: 'ia_pedido',
          dados: dados,
        );
        await whatsapp.enviarTexto(
          msg.telefone,
          'Desculpe, não entendi. ${_perguntaProximoDetalhePedido(sessao)}',
        );
        break;
      case 'tamanho':
        await _tratarTamanho(msg, config, dados, entrada);
        break;
      case 'arroz':
        await _tratarBase(msg, config, dados, entrada, 'arroz');
        break;
      case 'feijao':
        await _tratarBase(msg, config, dados, entrada, 'feijao');
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
      case 'bebida':
        await _tratarBebida(msg, config, dados, entrada);
        break;
      case 'quantidade_bebida':
        await _tratarQuantidadeBebida(msg, config, dados, entrada);
        break;
      case 'adicionar_outra_bebida':
        await _tratarAdicionarOutraBebida(msg, config, dados, entrada);
        break;
      case 'confirmacao':
        await _tratarConfirmacao(msg, config, dados, entrada);
        break;
      case 'confirmar_cancelamento':
        await _tratarConfirmarCancelamento(msg, sessao, entrada);
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
    if (config['modoAtendimento'] == 'ia' &&
        dados['boasVindasEnviada'] != true) {
      await whatsapp.enviarTexto(msg.telefone, _saudacaoIa());
      dados['boasVindasEnviada'] = true;
      banco.salvarSessao(
        telefone: msg.telefone,
        nome: msg.nome,
        etapa: 'inicio',
        dados: dados,
      );
    }
    final opcoesAposCardapio = dados['opcoesInicioAposCardapio'] == true;
    final entradaNormalizada = _normalizar(entrada);
    if (opcoesAposCardapio && entradaNormalizada == '2') {
      // Após o cardápio, a segunda opção exibida é falar com atendente.
      // O atalho global "2 = cardápio" não deve prevalecer sobre essa lista.
      entrada = 'inicio_humano';
    } else {
      entrada = _resolverOpcaoInicio(entrada) ?? entradaNormalizada;
    }

    if (entrada == 'inicio_cardapio' && !_modoIaAtivo) {
      dados['opcoesInicioAposCardapio'] = true;
    } else {
      dados.remove('opcoesInicioAposCardapio');
    }
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'inicio',
      dados: dados,
    );

    if (_corresponde(entrada, [
      'inicio_pedido',
      if (!_modoIaAtivo) '1',
      'fazer pedido',
      'pedido',
      _textoFluxo('inicio', 'botaoPedido', 'Fazer pedido')
    ])) {
      dados
        ..clear()
        ..addAll({
          'clienteNome': msg.nome,
          'itens': <dynamic>[],
          if (_modoIaAtivo) 'boasVindasEnviada': true,
        });
      if (_modoIaAtivo) {
        await _processarPedidoIA(
          msg,
          config,
          {'etapa': 'inicio', 'dados': dados},
          const {'itens': <dynamic>[]},
        );
        return;
      }
      await _mostrarTamanhos(msg, dados);
      return;
    }
    if (_corresponde(entrada, [
      'inicio_cardapio',
      if (!_modoIaAtivo) '2',
      'ver cardapio',
      'cardapio',
      _textoFluxo('inicio', 'botaoCardapio', 'Ver cardápio')
    ])) {
      await _mostrarCardapio(msg, config);
      return;
    }
    if (_corresponde(entrada, [
      'inicio_humano',
      if (!_modoIaAtivo) '3',
      'falar atendente',
      'atendente',
      _textoFluxo('inicio', 'botaoHumano', 'Falar atendente')
    ])) {
      banco.definirModoHumano(msg.telefone, true,
          origem: 'cliente', motivo: 'solicitacao_explicita');
      await whatsapp.enviarTexto(
        msg.telefone,
        _textoFluxo('sistema', 'humanoAtivado',
            '👤 Atendimento automático pausado. Um atendente continuará por aqui.'),
      );
      return;
    }
    if (_modoIaAtivo) {
      await whatsapp.enviarTexto(msg.telefone, 'O que você gostaria?');
      return;
    }
    await _enviarBotoes(
      msg.telefone,
      _textoFluxo('inicio', 'mensagem', 'Escolha uma opção abaixo:'),
      _botoesInicio(),
    );
  }

  Future<void> _mostrarCardapio(
      MensagemWhatsApp msg, Map<String, dynamic> config,
      {bool incluirBotoes = true}) async {
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
    final bebidas = (c['bebidas'] as List? ?? const [])
        .where((e) => (e as Map)['ativo'] == true)
        .toList();
    final arrozes = (c['arrozes'] as List? ?? const [])
        .where((e) => (e as Map)['ativo'] == true)
        .toList();
    final feijoes = (c['feijoes'] as List? ?? const [])
        .where((e) => (e as Map)['ativo'] == true)
        .toList();
    final fluxoArroz = c['fluxoArrozAtivo'] == true;
    final fluxoFeijao = c['fluxoFeijaoAtivo'] == true;

    if (tamanhos.isEmpty || misturas.isEmpty || acompanhamentos.isEmpty) {
      await _semOpcao(
        msg,
        'O cardápio está temporariamente indisponível. Fale com um atendente.',
      );
      return;
    }

    if (c['modoExibicao'] == 'imagem') {
      final imagem = banco.obterImagemCardapio();
      if (imagem != null) {
        await whatsapp.enviarImagemCardapio(
          msg.telefone,
          imagem['dados'] as List<int>,
          imagem['mimeType'] as String,
        );
        if (incluirBotoes && !_modoIaAtivo) {
          await _enviarBotoes(msg.telefone, 'O que deseja fazer?', [
            {
              'id': 'inicio_pedido',
              'titulo': _textoFluxo('inicio', 'botaoPedido', 'Fazer pedido')
            },
            {
              'id': 'inicio_humano',
              'titulo': _textoFluxo('inicio', 'botaoHumano', 'Falar atendente')
            },
          ]);
        }
        return;
      }
    }

    final linhas = <String>[
      _textoFluxo('cardapio', 'titulo', '🍱 *CARDÁPIO DO DIA*'),
      '',
      '🍚 Todas as marmitas acompanham *${_descricaoBase(c)}*.',
      '',
    ];
    for (final t in tamanhos) {
      final m = Map<String, dynamic>.from(t as Map);
      linhas.add('• ${m['nome']} — ${moeda((m['preco'] as num).toDouble())}');
    }
    if (fluxoArroz) {
      linhas.addAll([
        '',
        '*Arroz:*',
        ...arrozes.map((e) => '• ${(e as Map)['nome']}'),
      ]);
    }
    if (fluxoFeijao) {
      linhas.addAll([
        '',
        '*Feijão:*',
        ...feijoes.map((e) => '• ${(e as Map)['nome']}'),
      ]);
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
    if (bebidas.isNotEmpty) {
      linhas.addAll([
        '',
        '*Bebidas:*',
        ...bebidas.map((e) {
          final b = Map<String, dynamic>.from(e as Map);
          return '• ${b['nome']} — ${moeda((b['preco'] as num).toDouble())}';
        }),
      ]);
    }
    if (config['saladaIncluida'] == true) {
      linhas
          .add('\n🥗 ${config['descricaoSalada'] ?? 'Salada do dia'} inclusa.');
    }
    linhas.add(
        '\n${_textoFluxo('cardapio', 'rodape', 'O mesmo padrão em todos os tamanhos; muda a quantidade.')}');
    final texto = linhas.join('\n');
    if (!incluirBotoes || _modoIaAtivo) {
      await whatsapp.enviarTexto(msg.telefone, texto);
      return;
    }
    await _enviarBotoes(msg.telefone, texto, [
      {
        'id': 'inicio_pedido',
        'titulo': _textoFluxo('inicio', 'botaoPedido', 'Fazer pedido')
      },
      {
        'id': 'inicio_humano',
        'titulo': _textoFluxo('inicio', 'botaoHumano', 'Falar atendente')
      },
    ]);
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
      await _enviarBotoes(
        msg.telefone,
        _textoFluxo(
            'tamanho',
            'mensagem',
            _modoIaAtivo
                ? 'Qual tamanho você prefere?'
                : 'Escolha o tamanho da marmita:'),
        opcoes,
      );
    } else {
      await _enviarLista(
        msg.telefone,
        texto: _textoFluxo(
            'tamanho',
            'mensagem',
            _modoIaAtivo
                ? 'Qual tamanho você prefere?'
                : 'Escolha o tamanho da marmita:'),
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
    final escolhido = _resolverTamanhoOpcaoNatural(entrada, tamanhos) ??
        _acharOpcao(entrada, tamanhos, prefixo: 'tam:');
    if (escolhido == null) {
      await _mostrarTamanhos(msg, dados);
      return;
    }
    dados['itemAtual'] = {
      'tamanhoId': escolhido['id'],
      'tamanhoNome': escolhido['nome'],
      'precoUnitario': (escolhido['preco'] as num).toDouble(),
      'quantidadeMisturas': escolhido['quantidadeMisturas'] ?? 1,
      'quantidadeAcompanhamentos': escolhido['quantidadeAcompanhamentos'] ?? 1,
      'saladaIncluida': config['saladaIncluida'] == true,
      'descricaoSalada': config['descricaoSalada']?.toString() ?? 'Salada',
    };
    await _mostrarPrimeiraBaseOuMistura(msg, config, dados);
  }

  Future<void> _mostrarPrimeiraBaseOuMistura(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
  ) async {
    final cardapio = banco.obterCardapio();
    if (cardapio['fluxoArrozAtivo'] == true) {
      await _mostrarBase(msg, dados, 'arroz');
    } else if (cardapio['fluxoFeijaoAtivo'] == true) {
      await _mostrarBase(msg, dados, 'feijao');
    } else {
      await _mostrarMisturas(msg, dados);
    }
  }

  Future<void> _mostrarBase(
    MensagemWhatsApp msg,
    Map<String, dynamic> dados,
    String tipo,
  ) async {
    final cardapio = banco.obterCardapio();
    final chave = tipo == 'arroz' ? 'arrozes' : 'feijoes';
    final nome = tipo == 'arroz' ? 'arroz' : 'feijão';
    final lista = (cardapio[chave] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((e) => e['ativo'] == true)
        .toList();
    if (lista.isEmpty) {
      await _semOpcao(msg, 'Nenhuma opção de $nome está disponível agora.');
      return;
    }
    dados['opcoesExibidas'] = lista;
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: tipo,
      dados: dados,
    );
    final prefixo = tipo == 'arroz' ? 'arr:' : 'fei:';
    final opcoes = lista
        .map((e) => <String, String>{
              'id': '$prefixo${e['id']}',
              'titulo': e['nome'].toString(),
              'descricao': 'Escolher $nome',
            })
        .toList();
    final texto = tipo == 'arroz'
        ? (_modoIaAtivo
            ? 'Você gostaria de arroz na marmita?'
            : '🍚 Escolha o arroz da marmita:')
        : (_modoIaAtivo
            ? 'Você gostaria de feijão na marmita?'
            : '🫘 Escolha o feijão da marmita:');
    if (opcoes.length <= 3) {
      await _enviarBotoes(msg.telefone, texto, opcoes);
    } else {
      await _enviarLista(
        msg.telefone,
        texto: texto,
        tituloBotao: tipo == 'arroz' ? 'Ver arrozes' : 'Ver feijões',
        opcoes: opcoes,
      );
    }
  }

  Future<void> _tratarBase(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
    String tipo,
  ) async {
    final cardapio = banco.obterCardapio();
    final chave = tipo == 'arroz' ? 'arrozes' : 'feijoes';
    final lista = (dados['opcoesExibidas'] as List? ??
            cardapio[chave] as List? ??
            const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((e) => e['ativo'] == true)
        .toList();
    final prefixo = tipo == 'arroz' ? 'arr:' : 'fei:';
    final escolhido = _acharOpcao(entrada, lista, prefixo: prefixo);
    if (escolhido == null) {
      await _mostrarBase(msg, dados, tipo);
      return;
    }
    final atual = Map<String, dynamic>.from(dados['itemAtual'] as Map);
    atual['${tipo}Id'] = escolhido['id'];
    atual['${tipo}Nome'] = escolhido['nome'];
    dados['itemAtual'] = atual;
    if (tipo == 'arroz' && cardapio['fluxoFeijaoAtivo'] == true) {
      await _mostrarBase(msg, dados, 'feijao');
    } else {
      await _mostrarMisturas(msg, dados);
    }
  }

  Future<void> _mostrarMisturas(
    MensagemWhatsApp msg,
    Map<String, dynamic> dados,
  ) async {
    final cardapio = banco.obterCardapio();
    final atual = Map<String, dynamic>.from(dados['itemAtual'] as Map? ?? {});
    final escolhidas = (atual['misturaIds'] as List? ?? const [])
        .map((id) => id.toString())
        .toSet();
    final quantidade = (atual['quantidadeMisturas'] as num?)?.toInt() ?? 1;
    final lista = (cardapio['misturas'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((e) => e['ativo'] == true && !escolhidas.contains(e['id']))
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
    final pergunta = _textoFluxo(
      'mistura',
      'mensagem',
      _modoIaAtivo ? 'Qual mistura você gostaria?' : 'Escolha a mistura:',
    );
    final texto = quantidade == 1
        ? pergunta
        : '$pergunta (${escolhidas.length + 1} de $quantidade)';
    if (opcoes.length <= 3) {
      await _enviarBotoes(
        msg.telefone,
        texto,
        opcoes,
      );
    } else {
      await _enviarLista(
        msg.telefone,
        texto: texto,
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
    final ids = (atual['misturaIds'] as List? ?? const [])
        .map((id) => id.toString())
        .toList();
    if (ids.contains(escolhido['id'].toString())) {
      await _mostrarMisturas(msg, dados);
      return;
    }
    final nomes = (atual['misturaNomes'] as List? ?? const [])
        .map((nome) => nome.toString())
        .toList();
    ids.add(escolhido['id'].toString());
    nomes.add(escolhido['nome'].toString());
    atual['misturaIds'] = ids;
    atual['misturaNomes'] = nomes;
    atual['misturaId'] = ids.first;
    atual['misturaNome'] = nomes.join(' + ');
    dados['itemAtual'] = atual;
    if (ids.length < ((atual['quantidadeMisturas'] as num?)?.toInt() ?? 1)) {
      await _mostrarMisturas(msg, dados);
    } else {
      await _mostrarAcompanhamentos(msg, dados);
    }
  }

  Future<void> _mostrarAcompanhamentos(
    MensagemWhatsApp msg,
    Map<String, dynamic> dados,
  ) async {
    final cardapio = banco.obterCardapio();
    final atual = Map<String, dynamic>.from(dados['itemAtual'] as Map? ?? {});
    final escolhidos = (atual['acompanhamentoIds'] as List? ?? const [])
        .map((id) => id.toString())
        .toSet();
    final quantidade =
        (atual['quantidadeAcompanhamentos'] as num?)?.toInt() ?? 1;
    final lista = (cardapio['acompanhamentos'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((e) => e['ativo'] == true && !escolhidos.contains(e['id']))
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
    final pergunta = _textoFluxo(
      'acompanhamento',
      'mensagem',
      _modoIaAtivo
          ? 'Qual acompanhamento você gostaria?'
          : 'Escolha 1 acompanhamento:',
    );
    final texto = quantidade == 1
        ? pergunta
        : '$pergunta (${escolhidos.length + 1} de $quantidade)';
    if (opcoes.length <= 3) {
      await _enviarBotoes(
        msg.telefone,
        texto,
        opcoes,
      );
    } else {
      await _enviarLista(
        msg.telefone,
        texto: texto,
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
    final ids = (atual['acompanhamentoIds'] as List? ?? const [])
        .map((id) => id.toString())
        .toList();
    if (ids.contains(escolhido['id'].toString())) {
      await _mostrarAcompanhamentos(msg, dados);
      return;
    }
    final nomes = (atual['acompanhamentoNomes'] as List? ?? const [])
        .map((nome) => nome.toString())
        .toList();
    ids.add(escolhido['id'].toString());
    nomes.add(escolhido['nome'].toString());
    atual['acompanhamentoIds'] = ids;
    atual['acompanhamentoNomes'] = nomes;
    atual['acompanhamentoId'] = ids.first;
    atual['acompanhamentoNome'] = nomes.join(' + ');
    dados['itemAtual'] = atual;
    if (ids.length <
        ((atual['quantidadeAcompanhamentos'] as num?)?.toInt() ?? 1)) {
      await _mostrarAcompanhamentos(msg, dados);
      return;
    }
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
      _modoIaAtivo
          ? titulo
          : '$titulo\n$ajuda\n\n*0* cancela • digite *voltar* para retornar.',
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
        _modoIaAtivo
            ? 'Quantas marmitas você gostaria?'
            : 'Digite somente um número de 1 a $maximo. Ex.: *2*.',
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
    if (_modoIaAtivo) {
      await whatsapp.enviarTexto(
        msg.telefone,
        'Anotei essa marmita. Quer incluir outra ou podemos finalizar?',
      );
      return;
    }
    await _enviarBotoes(
      msg.telefone,
      _textoFluxo(
          'adicionarOutro',
          'mensagem',
          _modoIaAtivo
              ? 'Quer mais alguma marmita?'
              : '✅ Item adicionado. Quer adicionar outra marmita?'),
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
    if (_ehConfirmacaoOpcional(entrada) ||
        _corresponde(entrada, [
          'outro_sim',
          if (!_modoIaAtivo) '1',
          'sim',
          's',
          'claro',
          'mais uma',
          'quero outra',
          'quero mais uma',
          'adicionar mais uma',
          'adicionar outra',
          'adicionar outra marmita',
          _textoFluxo('adicionarOutro', 'botaoSim', 'Adicionar outra')
        ])) {
      if (_modoIaAtivo) {
        banco.salvarSessao(
          telefone: msg.telefone,
          nome: msg.nome,
          etapa: 'ia_pedido',
          dados: dados,
        );
        await whatsapp.enviarTexto(
          msg.telefone,
          'Qual tamanho você prefere para a próxima marmita?',
        );
        return;
      }
      await _mostrarTamanhos(msg, dados);
      return;
    }
    if (_ehNegacaoOpcional(entrada) ||
        _corresponde(
          entrada,
          [
            'outro_nao',
            if (!_modoIaAtivo) '2',
            'nao',
            'não',
            'n',
            'finalizar pedido',
            _textoFluxo('adicionarOutro', 'botaoNao', 'Finalizar pedido')
          ],
        )) {
      if (_modoIaAtivo) {
        dados['recebimento'] = 'entrega';
        await _pedirEndereco(msg, dados);
        return;
      }
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
    await _enviarBotoes(
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
    final entradaNatural = _resolverFormaRecebimento(entrada) ??
        (_correspondeIntencao(entrada, [
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
                : entrada);
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
    dados.remove('bebidas');
    dados.remove('taxaEntregaCongelada');
    dados.remove('cidadeConfirmadaCliente');
    dados.remove('ultimaLocalizacao');
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

    final pergunta = _modoIaAtivo
        ? 'Qual será o endereço para entrega e a cidade?'
        : _textoFluxo(
            'endereco',
            'mensagem',
            '📍 Envie seu endereço para entrega:\nRua, número, bairro e complemento/referência.',
          );
    await whatsapp.enviarTexto(
      msg.telefone,
      _modoIaAtivo ? pergunta : '$pergunta\n\nDigite *voltar* para retornar.',
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
    // Uma nova tentativa de endereço invalida qualquer localização recebida
    // antes, evitando que coordenadas antigas fiquem associadas ao pedido.
    dados.remove('ultimaLocalizacao');

    if (_ehIntencaoRetirada(endereco)) {
      final enderecoRetirada =
          config['enderecoRetirada']?.toString().trim() ?? '';
      if (enderecoRetirada.isEmpty) {
        await _semOpcao(
          msg,
          'O endereço de retirada ainda não está configurado. Fale com um atendente.',
        );
        return;
      }
      _limparDepoisDoRecebimento(dados);
      dados['recebimento'] = 'retirada';
      dados['taxaEntregaCongelada'] = 0.0;
      dados['endereco'] = enderecoRetirada;
      await whatsapp.enviarTexto(
        msg.telefone,
        '🏠 *Retirada em:*\n$enderecoRetirada',
      );
      await _mostrarPagamentos(msg, config, dados);
      return;
    }

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
        _modoIaAtivo
            ? 'Pode me passar o endereço completo, por favor?'
            : 'Envie um endereço um pouco mais completo.\nEx.: Rua das Flores, 120, Centro.',
      );
      return;
    }

    if (_ehPerguntaQueNaoEhEndereco(endereco)) {
      await whatsapp.enviarTexto(
        msg.telefone,
        'Entendi a sua dúvida. Para continuar, pode me passar o endereço da '
        'entrega (rua, número e bairro), por favor?',
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
    dados.remove('bebidas');

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

    final mensagem = _modoIaAtivo && cidades.length == 2
        ? 'Barra ou Igaraçu?'
        : _textoFluxo(
            'cidadeEntrega',
            'mensagem',
            '🏙️ Em qual cidade será a entrega?',
          );

    if (opcoes.length <= 3) {
      await _enviarBotoes(
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
        _modoIaAtivo
            ? mensagem
            : '$mensagem\n\n$numeradas\n\nDigite o número da cidade.',
      );
    }
  }

  Future<void> _tratarCidadeEntrega(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    if (_modoIaAtivo && _ehIntencaoRetirada(entrada)) {
      final enderecoRetirada =
          config['enderecoRetirada']?.toString().trim() ?? '';
      if (enderecoRetirada.isEmpty) {
        await _semOpcao(
          msg,
          'O endereço de retirada ainda não está configurado. Fale com um atendente.',
        );
        return;
      }
      _limparDepoisDoRecebimento(dados);
      dados['recebimento'] = 'retirada';
      dados['taxaEntregaCongelada'] = 0.0;
      dados['endereco'] = enderecoRetirada;
      await whatsapp.enviarTexto(
        msg.telefone,
        '🏠 *Retirada em:*\n$enderecoRetirada',
      );
      await _mostrarPagamentos(msg, config, dados);
      return;
    }

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
    dados.remove('bebidas');

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
    final cartaoLegado = pagamentos['cartao'] == true;
    if (pagamentos['credito'] == true ||
        (pagamentos['credito'] == null && cartaoLegado)) {
      opcoes.add({'id': 'pag_credito', 'titulo': 'Cartão de crédito'});
    }
    if (pagamentos['debito'] == true ||
        (pagamentos['debito'] == null && cartaoLegado)) {
      opcoes.add({'id': 'pag_debito', 'titulo': 'Cartão de débito'});
    }
    return opcoes;
  }

  Future<void> _mostrarPagamentos(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados, {
    bool permitirPulo = true,
  }) async {
    if (_modoIaAtivo) {
      await _pedirTroco(msg, dados);
      return;
    }
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
    await _enviarBotoes(
      msg.telefone,
      _modoIaAtivo
          ? 'Qual será a forma de pagamento?'
          : _textoFluxo('pagamento', 'mensagem', 'Como deseja pagar?'),
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
    final entradaNatural = _resolverFormaPagamento(entrada) ??
        (_correspondeIntencao(entrada, [
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
                    'credito',
                    'cartao de credito',
                    'pagar no credito',
                    'pag_cartao',
                  ])
                    ? 'pag_credito'
                    : _correspondeIntencao(entrada, [
                        'debito',
                        'cartao de debito',
                        'pagar no debito',
                      ])
                        ? 'pag_debito'
                        : entrada);
    final opcao = _acharOpcaoSimples(entradaNatural, opcoes);
    if (opcao == null || !atuais.any((e) => e['id'] == opcao['id'])) {
      if (_modoIaAtivo && _ehPedidoCartaoGenerico(entrada, config)) {
        await whatsapp.enviarTexto(msg.telefone, 'Crédito ou débito?');
        return;
      }
      await _mostrarPagamentos(msg, config, dados);
      return;
    }

    final pagamento = switch (opcao['id']) {
      'pag_pix' => 'pix',
      'pag_dinheiro' => 'dinheiro',
      'pag_credito' => 'credito',
      'pag_debito' => 'debito',
      _ => '',
    };
    if (pagamento.isEmpty) {
      await _mostrarPagamentos(msg, config, dados);
      return;
    }

    dados['pagamento'] = pagamento;
    dados.remove('trocoPara');
    if (pagamento == 'dinheiro') {
      await _pedirTroco(msg, dados);
      return;
    }
    if (_modoIaAtivo && (pagamento == 'credito' || pagamento == 'debito')) {
      final calculo = _calcular(dados, config);
      final rotulo = pagamento == 'credito' ? 'crédito' : 'débito';
      if (calculo.taxaMaquininha > 0) {
        await whatsapp.enviarTexto(
          msg.telefone,
          'Temos a taxa da maquininha para pagamento no $rotulo: '
          '${moeda(calculo.taxaMaquininha)}.',
        );
      }
      await _mostrarResumo(msg, config, dados);
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
    var mensagem = _textoFluxo(
      'troco',
      'mensagem',
      _modoIaAtivo
          ? 'Vai precisar de troco?'
          : 'Precisa de troco?\nDigite *não* ou informe para quanto, por exemplo: *50*.',
    );
    if (_modoIaAtivo) {
      final itens = dados['itens'] as List? ?? const [];
      if (itens.isNotEmpty) {
        try {
          final config = Map<String, dynamic>.from(
            banco.obterConfiguracao()['dados'] as Map,
          );
          final total = _calcular(dados, config).total;
          mensagem = 'Seu pedido ficou ${moeda(total)}. Vai precisar de troco?';
        } catch (_) {
          // Mantém a pergunta padrão se não for possível calcular o total.
        }
      }
    }
    await whatsapp.enviarTexto(msg.telefone, mensagem);
  }

  Future<void> _tratarTroco(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    final formaInformada = _resolverFormaPagamento(entrada);
    if (formaInformada != null ||
        (_modoIaAtivo && _ehPedidoCartaoGenerico(entrada, config))) {
      if (_modoIaAtivo && _ehPedidoCartaoGenerico(entrada, config)) {
        await whatsapp.enviarTexto(msg.telefone, 'Crédito ou débito?');
        return;
      }
      await _tratarPagamento(msg, config, dados, formaInformada!);
      return;
    }
    if (_ehNegacaoDeTroco(entrada)) {
      dados['trocoPara'] = null;
      if (_modoIaAtivo && dados['pagamento'] == null) {
        banco.salvarSessao(
          telefone: msg.telefone,
          nome: msg.nome,
          etapa: 'troco',
          dados: dados,
        );
        await whatsapp.enviarTexto(
          msg.telefone,
          'Certo 😊 Você prefere pagar por Pix, dinheiro ou cartão?',
        );
        return;
      }
      await _irParaObservacaoOuResumo(msg, config, dados);
      return;
    }

    final valor = _valorTrocoNatural(entrada);
    if (valor == null || valor <= 0) {
      await whatsapp.enviarTexto(
        msg.telefone,
        _modoIaAtivo
            ? 'Qual valor você vai usar para pagar?'
            : 'Informe um valor válido para o troco, por exemplo *50*, ou digite *${_textoFluxo('troco', 'textoSemTroco', 'não')}*.',
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
      await _mostrarBebidasOuResumo(msg, config, dados);
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
        : _textoFluxo(
            'observacao',
            'mensagem',
            _modoIaAtivo
                ? 'Gostaria de acrescentar alguma observação?'
                : 'Deseja alguma observação?\nEx.: sem feijão.');
    await whatsapp.enviarTexto(
      msg.telefone,
      _modoIaAtivo ? base : '$base\nDigite *$nenhuma* para nenhuma.',
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
        'n tenho',
        'n quero',
        'nao quero',
        'nao preciso',
        'n preciso',
        'nao obrigado',
        'nao obrigada',
        'nao valeu',
        'dispenso',
        'deixa',
        'pode deixar',
        'sem',
        'sem observacao',
        'sem observação',
        _textoFluxo('observacao', 'textoNenhuma', 'não')
      ],
    )) {
      dados['observacao'] = null;
      await _mostrarBebidasOuResumo(msg, config, dados);
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
    await _mostrarBebidasOuResumo(msg, config, dados);
  }

  List<Map<String, dynamic>> _bebidasAtivas() =>
      (banco.obterCardapio()['bebidas'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((e) => e['ativo'] == true)
          .toList();

  String _semArtigo(String texto) =>
      texto.replaceFirst(RegExp(r'^(?:a|o|as|os|um|uma)\s+'), '').trim();

  Map<String, dynamic>? _tamanhoMencionadoNaFrase(
    String entrada,
    Map<String, dynamic> cardapio,
  ) {
    final texto = _normalizarIntencao(entrada);
    if (texto.isEmpty) return null;
    final encontrados = <Map<String, dynamic>>[];
    for (final tamanho in _itensAtivos(cardapio, 'tamanhos')) {
      final nome = _normalizar(tamanho['nome']?.toString() ?? '');
      if (nome.isEmpty) continue;
      if (_contemTermo(texto, [nome, '${nome}s'])) {
        encontrados.add(tamanho);
      }
    }
    return encontrados.length == 1 ? encontrados.single : null;
  }

  bool _mencionaBebidaNoTexto(String texto) {
    if (_contemTermo(texto, [
      'bebida',
      'bebidas',
      'refri',
      'refrigerante',
      'refrigerantes',
      'suco',
      'sucos',
      'agua',
      'aguas',
      'água',
      'águas',
    ])) return true;
    for (final bebida in _bebidasAtivas()) {
      final nome = _normalizar(bebida['nome']?.toString() ?? '');
      if (nome.isEmpty) continue;
      if (_contemTermo(texto, [nome])) return true;
      final primeira = nome.split(' ').first;
      if (primeira.length >= 4 && _contemTermo(texto, [primeira])) return true;
    }
    return false;
  }

  Map<String, dynamic>? _capturarBebidaAdicional(String entrada) {
    if (_ehPerguntaExplicita(entrada)) return null;
    final bebidas = _bebidasAtivas();
    if (bebidas.isEmpty) return null;
    final texto = _normalizarIntencao(entrada);
    final bebida = _resolverOpcaoNatural(entrada, bebidas);
    if (bebida == null) return null;

    final nome = _normalizar(bebida['nome']?.toString() ?? '');
    final posicao = texto.indexOf(nome);
    if (posicao < 0) return null;
    final antes = texto.substring(0, posicao).trim();
    final quantidadeTexto = antes
        .replaceAll(
          RegExp(
              r'\b(?:quero|queria|gostaria de|adiciona|adicionar|inclui|incluir|coloca|colocar|acrescenta|acrescentar|mais|por favor|uma|um|lata|latas|garrafa|garrafas|unidade|unidades|de)\b'),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    var quantidade = 1;
    if (quantidadeTexto.isNotEmpty) {
      final parsed = _parseQuantidade(quantidadeTexto);
      if (parsed == null || parsed < 1 || parsed > 50) return null;
      quantidade = parsed;
    }
    return {
      'bebidaId': bebida['id'],
      'nome': bebida['nome'],
      'precoUnitario': (bebida['preco'] as num?)?.toDouble() ?? 0.0,
      'quantidade': quantidade,
    };
  }

  Future<void> _adicionarBebidaAoResumo(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic>? sessao,
    Map bebidaEntrada,
  ) async {
    final dados = Map<String, dynamic>.from(sessao?['dados'] as Map? ?? {});
    final bebida = Map<String, dynamic>.from(bebidaEntrada);
    final bebidas = (dados['bebidas'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final indice = bebidas.indexWhere((item) =>
        item['bebidaId'] == bebida['bebidaId'] ||
        _normalizar(item['nome']?.toString() ?? '') ==
            _normalizar(bebida['nome']?.toString() ?? ''));
    if (indice >= 0) {
      final anterior = (bebidas[indice]['quantidade'] as num?)?.toInt() ?? 0;
      final nova = (bebida['quantidade'] as num?)?.toInt() ?? 1;
      if (anterior + nova > 50) {
        await whatsapp.enviarTexto(msg.telefone,
            'Posso adicionar até 50 unidades de cada bebida. Quantas você gostaria?');
        return;
      }
      bebidas[indice]['quantidade'] = anterior + nova;
    } else {
      bebidas.add(bebida);
    }
    dados['bebidas'] = bebidas;
    dados.remove('bebidaAtual');
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'confirmacao',
      dados: dados,
    );
    final quantidade = (bebida['quantidade'] as num?)?.toInt() ?? 1;
    await whatsapp.enviarTexto(msg.telefone,
        'Claro, adicionei ${quantidade > 1 ? '$quantidade ' : ''}${bebida['nome']} ao pedido.');
    await _mostrarResumo(msg, config, dados);
  }

  bool _ehPararDeAdicionarMarmitas(String entrada) {
    final texto = _normalizarIntencao(entrada);
    return _corresponde(texto, [
          'nao quero outra',
          'nao quero mais uma',
          'so essa',
          'so essas',
          'deixa so essa',
          'deixa so essas',
          'fica so essa',
          'cancela a outra',
          'cancelar a outra',
          'cancela a proxima',
          'cancelar a proxima',
          'nao adiciona outra',
          'nao adicionar outra',
          'nao vou querer outra',
        ]) ||
        RegExp(r'^(?:so|apenas) (?:essa|essas|a que ja escolhi|as que ja escolhi)$')
            .hasMatch(texto);
  }

  int? _contarMarmitasAvulsas(String texto) {
    final match = RegExp(
      r'\b(dois|duas|tres|quatro|cinco|seis|sete|oito|nove|dez|um|uma|\d{1,2})\b',
    ).firstMatch(texto);
    if (match == null) return null;
    return _parseQuantidade(match.group(1)!);
  }

  Map<String, dynamic>? _capturarAdicaoMarmitasConfirmacao(
    String entrada,
    Map<String, dynamic> dados,
  ) {
    if (_ehPerguntaExplicita(entrada)) return null;
    final texto = _normalizarIntencao(entrada);
    if (texto.isEmpty || _ehNegacaoOpcional(texto)) return null;
    if (_resolverOpcaoNatural(entrada, _bebidasAtivas()) != null) return null;

    final cardapio = banco.obterCardapio();
    final tamanho =
        _resolverOpcaoNatural(entrada, _itensAtivos(cardapio, 'tamanhos')) ??
            _tamanhoMencionadoNaFrase(entrada, cardapio);
    final indicaMarmita = _contemTermo(texto, ['marmita', 'marmitas']);
    final indicaMais = RegExp(
      r'\b(?:mais|outra|outro|adiciona|adicionar|acrescenta|acrescentar|inclui|incluir)\b',
    ).hasMatch(texto);
    final igual =
        RegExp(r'\b(?:igual|iguais|mesma|mesmo|anterior)\b').hasMatch(texto);

    Map<String, dynamic>? encontraOpcaoNaFrase(String chave) {
      final normalizada = _normalizarIntencao(entrada);
      final encontradas = _itensAtivos(cardapio, chave).where((opcao) {
        final nome = _normalizarIntencao(opcao['nome']?.toString() ?? '');
        if (nome.isEmpty) return false;
        if (RegExp(r'(?:^| )' + RegExp.escape(nome) + r'(?: |$)')
            .hasMatch(normalizada)) return true;
        return nome.split(' ').any((palavra) =>
            palavra.length >= 4 && _contemTermo(normalizada, [palavra]));
      }).toList();
      return encontradas.length == 1 ? encontradas.single : null;
    }

    final mistura = encontraOpcaoNaFrase('misturas');
    final acompanhamento = encontraOpcaoNaFrase('acompanhamentos');
    final arroz = cardapio['fluxoArrozAtivo'] == true
        ? encontraOpcaoNaFrase('arrozes')
        : null;
    final feijao = cardapio['fluxoFeijaoAtivo'] == true
        ? encontraOpcaoNaFrase('feijoes')
        : null;

    if (!indicaMarmita && tamanho == null && !indicaMais) return null;
    if (!indicaMarmita && tamanho == null && !igual) {
      if (_extrairTotalMarmitas(entrada) == null &&
          _contarMarmitasAvulsas(texto) == null) {
        return null;
      }
    }

    var quantidade = _extrairTotalMarmitas(entrada);
    quantidade ??= _contarMarmitasAvulsas(texto);
    quantidade ??= 1;
    if (quantidade < 1 || quantidade > 50) return null;

    final itens =
        (dados['itens'] as List? ?? const []).whereType<Map>().toList();
    final indice = itens.length + 1;

    if (igual && itens.isNotEmpty) {
      final ultimo = Map<String, dynamic>.from(itens.last);
      return {
        'itens': [
          {
            'indice': indice,
            'tamanho': ultimo['tamanhoNome'],
            if (ultimo['arrozNome'] != null) 'arroz': ultimo['arrozNome'],
            if (ultimo['feijaoNome'] != null) 'feijao': ultimo['feijaoNome'],
            'misturas': ultimo['misturaNomes'] is List
                ? List<String>.from(ultimo['misturaNomes'] as List)
                : [if (ultimo['misturaNome'] != null) ultimo['misturaNome']],
            'acompanhamentos': ultimo['acompanhamentoNomes'] is List
                ? List<String>.from(ultimo['acompanhamentoNomes'] as List)
                : [
                    if (ultimo['acompanhamentoNome'] != null)
                      ultimo['acompanhamentoNome']
                  ],
            'quantidade': quantidade,
          }
        ],
        'finalizarItens': false,
      };
    }

    return {
      'itens': [
        {
          'indice': indice,
          if (tamanho != null) 'tamanho': tamanho['nome'],
          if (mistura != null) 'mistura': mistura['nome'],
          if (acompanhamento != null) 'acompanhamento': acompanhamento['nome'],
          if (arroz != null) 'arroz': arroz['nome'],
          if (feijao != null) 'feijao': feijao['nome'],
          'quantidade': quantidade,
        }
      ],
      'finalizarItens': false,
    };
  }

  String _chaveCombinacao(Map<String, dynamic> item) => [
        item['tamanhoId'],
        item['arrozId'],
        item['feijaoId'],
        item['arrozDesativado'],
        item['feijaoDesativado'],
        _chaveIdsEscolhas(item['misturaIds'], item['misturaId']),
        _chaveIdsEscolhas(item['acompanhamentoIds'], item['acompanhamentoId']),
      ].join('|');

  /// Adiciona marmitas pedidas depois que o resumo já foi mostrado, sem
  /// perder endereço, cidade, pagamento, troco, observação ou bebidas.
  Future<void> _adicionarMarmitasPosResumo(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    Map<String, dynamic> captura,
  ) async {
    final cardapio = banco.obterCardapio();
    final arrozAtivo = cardapio['fluxoArrozAtivo'] == true;
    final feijaoAtivo = cardapio['fluxoFeijaoAtivo'] == true;
    final linhas =
        (captura['itens'] as List? ?? const []).whereType<Map>().toList();
    final itensAtuais = (dados['itens'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();

    // Sem marmita anterior para servir de base, deixa o fluxo padrão montar
    // o pedido normalmente (mantém o comportamento antigo).
    if (itensAtuais.isEmpty || linhas.isEmpty) {
      final sessao = banco.obterSessao(msg.telefone);
      await _processarPedidoIA(msg, config, sessao, captura);
      return;
    }

    final base = itensAtuais.last;
    final novos = <Map<String, dynamic>>[];
    for (final raw in linhas) {
      final linha = Map<String, dynamic>.from(raw);
      final item = Map<String, dynamic>.from(base);

      final tamanho = _resolverOpcaoNatural(
        linha['tamanho'],
        _itensAtivos(cardapio, 'tamanhos'),
      );
      if (tamanho != null) {
        final tamanhoAnterior = item['tamanhoId']?.toString();
        item['tamanhoId'] = tamanho['id'];
        item['tamanhoNome'] = tamanho['nome'];
        item['precoUnitario'] = (tamanho['preco'] as num).toDouble();
        final quantidadeMisturas =
            (tamanho['quantidadeMisturas'] as num?)?.toInt() ?? 1;
        final quantidadeAcompanhamentos =
            (tamanho['quantidadeAcompanhamentos'] as num?)?.toInt() ?? 1;
        item['quantidadeMisturas'] = quantidadeMisturas;
        item['quantidadeAcompanhamentos'] = quantidadeAcompanhamentos;
        final escolhasMistura =
            (item['misturaIds'] as List? ?? [item['misturaId']])
                .where((id) => id != null)
                .length;
        if (tamanhoAnterior != tamanho['id'] &&
            escolhasMistura != quantidadeMisturas) {
          item
            ..remove('misturaIds')
            ..remove('misturaNomes')
            ..remove('misturaId')
            ..remove('misturaNome');
        }
        final escolhasAcompanhamento =
            (item['acompanhamentoIds'] as List? ?? [item['acompanhamentoId']])
                .where((id) => id != null)
                .length;
        if (tamanhoAnterior != tamanho['id'] &&
            escolhasAcompanhamento != quantidadeAcompanhamentos) {
          item
            ..remove('acompanhamentoIds')
            ..remove('acompanhamentoNomes')
            ..remove('acompanhamentoId')
            ..remove('acompanhamentoNome');
        }
      }
      final misturas = _resolverListaOpcoesNaturais(
        linha['misturas'] ?? linha['mistura'],
        _itensAtivos(cardapio, 'misturas'),
      );
      if (misturas.isNotEmpty) {
        item['misturaIds'] = misturas.map((opcao) => opcao['id']).toList();
        item['misturaNomes'] = misturas.map((opcao) => opcao['nome']).toList();
        item['misturaId'] = misturas.first['id'];
        item['misturaNome'] = misturas.first['nome'];
      }
      final acompanhamentos = _resolverListaOpcoesNaturais(
        linha['acompanhamentos'] ?? linha['acompanhamento'],
        _itensAtivos(cardapio, 'acompanhamentos'),
      );
      if (acompanhamentos.isNotEmpty) {
        item['acompanhamentoIds'] =
            acompanhamentos.map((opcao) => opcao['id']).toList();
        item['acompanhamentoNomes'] =
            acompanhamentos.map((opcao) => opcao['nome']).toList();
        item['acompanhamentoId'] = acompanhamentos.first['id'];
        item['acompanhamentoNome'] = acompanhamentos.first['nome'];
      }
      if (arrozAtivo) {
        final arroz = _resolverOpcaoNatural(
          linha['arroz'],
          _itensAtivos(cardapio, 'arrozes'),
        );
        if (arroz != null) {
          item['arrozId'] = arroz['id'];
          item['arrozNome'] = arroz['nome'];
        }
      }
      if (feijaoAtivo) {
        final feijao = _resolverOpcaoNatural(
          linha['feijao'],
          _itensAtivos(cardapio, 'feijoes'),
        );
        if (feijao != null) {
          item['feijaoId'] = feijao['id'];
          item['feijaoNome'] = feijao['nome'];
        }
      }

      final bruto = linha['quantidade'];
      final quantidade =
          bruto is num ? bruto.toInt() : int.tryParse('$bruto') ?? 1;
      item['quantidade'] = quantidade.clamp(1, 50);
      final quantidadeMisturas =
          (item['quantidadeMisturas'] as num?)?.toInt() ?? 1;
      final quantidadeAcompanhamentos =
          (item['quantidadeAcompanhamentos'] as num?)?.toInt() ?? 1;
      final idsMisturas = (item['misturaIds'] as List? ?? [item['misturaId']])
          .where((id) => id != null)
          .map((id) => id.toString())
          .toList();
      final idsAcompanhamentos =
          (item['acompanhamentoIds'] as List? ?? [item['acompanhamentoId']])
              .where((id) => id != null)
              .map((id) => id.toString())
              .toList();
      if (idsMisturas.length > quantidadeMisturas ||
          idsAcompanhamentos.length > quantidadeAcompanhamentos) {
        await whatsapp.enviarTexto(
          msg.telefone,
          'Essa combinação excede a quantidade de escolhas permitida para o tamanho. Confira as quantidades do cardápio e me envie uma combinação válida.',
        );
        return;
      }
      final precisaMisturas = idsMisturas.length < quantidadeMisturas;
      final precisaAcompanhamentos =
          idsAcompanhamentos.length < quantidadeAcompanhamentos;
      if (precisaMisturas || precisaAcompanhamentos) {
        if (linhas.length != 1 || novos.isNotEmpty) {
          await whatsapp.enviarTexto(
            msg.telefone,
            'Para adicionar marmitas que precisam de novas escolhas, envie uma combinação por vez, informando todas as misturas e acompanhamentos.',
          );
          return;
        }
        final campoPendente = precisaMisturas ? 'misturas' : 'acompanhamentos';
        await _iniciarEscolhasEdicaoMarmita(
          msg,
          dados,
          indice: itensAtuais.length,
          item: item,
          campo: campoPendente,
          quantidade:
              precisaMisturas ? quantidadeMisturas : quantidadeAcompanhamentos,
          proximoCampo: precisaMisturas && precisaAcompanhamentos
              ? 'acompanhamentos'
              : null,
          quantidadeProxima: precisaMisturas && precisaAcompanhamentos
              ? quantidadeAcompanhamentos
              : 0,
          selecionadas: precisaMisturas ? idsMisturas : idsAcompanhamentos,
          nova: true,
        );
        return;
      }
      novos.add(item);
    }

    final mesclados = <String, Map<String, dynamic>>{};
    var excedeuLimite = false;
    void incluir(Map<String, dynamic> item) {
      final chave = _chaveCombinacao(item);
      final existente = mesclados[chave];
      if (existente == null) {
        mesclados[chave] = item;
        return;
      }
      final total = ((existente['quantidade'] as num?)?.toInt() ?? 0) +
          ((item['quantidade'] as num?)?.toInt() ?? 0);
      if (total > 50) {
        excedeuLimite = true;
        return;
      }
      existente['quantidade'] = total;
    }

    for (final item in itensAtuais) {
      incluir(item);
      if (excedeuLimite) break;
    }
    if (!excedeuLimite) {
      for (final item in novos) {
        incluir(item);
        if (excedeuLimite) break;
      }
    }
    if (excedeuLimite) {
      await whatsapp.enviarTexto(
        msg.telefone,
        'O limite por combinação é 50 marmitas. Ajuste as quantidades, por favor.',
      );
      return;
    }

    dados['itens'] = mesclados.values.toList();
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'confirmacao',
      dados: dados,
    );
    await _mostrarResumo(msg, config, dados);
  }

  List<Map<String, dynamic>> _resolverListaOpcoesNaturais(
    dynamic valores,
    List<Map<String, dynamic>> opcoes,
  ) {
    final entradas = valores is List ? valores : [valores];
    final resolvidas = <Map<String, dynamic>>[];
    for (final entrada in entradas) {
      if (entrada == null) continue;
      final opcao = _resolverOpcaoNatural(entrada.toString(), opcoes);
      if (opcao != null &&
          !resolvidas.any((existente) => existente['id'] == opcao['id'])) {
        resolvidas.add(opcao);
      }
    }
    return resolvidas;
  }

  Map<String, dynamic> _corrigirCamposEscolhasIA(
    Map<String, dynamic> item,
    Map<String, dynamic> cardapio,
  ) {
    final misturas = _itensAtivos(cardapio, 'misturas');
    final acompanhamentos = _itensAtivos(cardapio, 'acompanhamentos');

    List<String> valores(dynamic valor) {
      final lista = valor is List ? valor : [valor];
      return lista
          .where((valor) => valor != null)
          .expand(
              (valor) => valor.toString().split(RegExp(r'\s*(?:,|;|\be\b)\s*')))
          .map((valor) => valor.trim())
          .where((valor) => valor.isNotEmpty)
          .toList();
    }

    final declaradasMistura = valores(item['misturas'] ?? item['mistura']);
    final declaradasAcompanhamento =
        valores(item['acompanhamentos'] ?? item['acompanhamento']);
    final resolvidasMistura = <Map<String, dynamic>>[];
    final resolvidasAcompanhamento = <Map<String, dynamic>>[];

    void adicionarUnica(
      String valor,
      List<Map<String, dynamic>> opcoes,
      List<Map<String, dynamic>> destino,
    ) {
      final resolvida = _resolverOpcaoNatural(valor, opcoes);
      if (resolvida != null &&
          !destino.any((existente) => existente['id'] == resolvida['id'])) {
        destino.add(resolvida);
      }
    }

    for (final valor in declaradasMistura) {
      final mistura = _resolverOpcaoNatural(valor, misturas);
      if (mistura != null) {
        adicionarUnica(valor, misturas, resolvidasMistura);
      } else {
        adicionarUnica(valor, acompanhamentos, resolvidasAcompanhamento);
      }
    }
    for (final valor in declaradasAcompanhamento) {
      final acompanhamento = _resolverOpcaoNatural(valor, acompanhamentos);
      if (acompanhamento != null) {
        adicionarUnica(valor, acompanhamentos, resolvidasAcompanhamento);
      } else {
        adicionarUnica(valor, misturas, resolvidasMistura);
      }
    }

    if (resolvidasMistura.isNotEmpty) {
      item['misturas'] =
          resolvidasMistura.map((opcao) => opcao['nome']).toList();
      item['mistura'] = resolvidasMistura.first['nome'];
    }
    if (resolvidasAcompanhamento.isNotEmpty) {
      item['acompanhamentos'] =
          resolvidasAcompanhamento.map((opcao) => opcao['nome']).toList();
      item['acompanhamento'] = resolvidasAcompanhamento.first['nome'];
    }
    return item;
  }

  bool _ehRemocaoTotalMarmitas(String texto) {
    final normalizado = _normalizarIntencao(texto);
    if (RegExp(
      r'^(?:nao quero (?:mais )?(?:pedir|o pedido|nenhuma marmita|nenhuma das marmitas|mais nada)|nao vou pedir|nao vou querer (?:pedir|mais nada|nenhuma marmita|o pedido)|nao quer(?:er)? pedir|nao quiser pedir|nao queira pedir|nao vai querer (?:pedir|nenhuma marmita)|desisto do pedido|nao quero mais o pedido|nao vou querer mais o pedido|remover todas as marmitas|tirar todas as marmitas|excluir todas as marmitas)$',
    ).hasMatch(normalizado)) {
      return true;
    }
    return false;
  }

  bool _ehRecusaDeAdicionarMarmita(String texto) {
    final normalizado = _normalizarIntencao(texto);
    return RegExp(
          r'^(?:nao quero|nao vou querer|nao vai querer|nao precisa|nao quero adicionar|nao vou adicionar)\s+(?:mais\s+uma|outra|outra marmita|mais marmita|mais uma marmita)$',
        ).hasMatch(normalizado) ||
        _ehPararDeAdicionarMarmitas(normalizado);
  }

  bool _ehPedidoRemocaoUnitariaMarmita(String entrada) {
    final texto = _normalizarIntencao(entrada);
    if (_ehRecusaDeAdicionarMarmita(texto)) return false;
    final acao = RegExp(
      r'\b(?:tira|tirar|retira|retirar|remove|remover|exclui|excluir|nao quero|nao quer|nao vou querer|nao vai querer|nao vou levar)\b',
    ).hasMatch(texto);
    final umaUnidade = RegExp(r'\b(?:uma|um|1)\b').hasMatch(texto);
    final singular = RegExp(r'\b(?:a|uma|um|1)\s+marmita\b').hasMatch(texto);
    return acao && (umaUnidade || singular);
  }

  List<String> _opcoesMencionadasNaFrase(
    String entrada,
    List<Map<String, dynamic>> opcoes,
  ) {
    final texto = _normalizarIntencao(entrada);
    return opcoes
        .where((opcao) {
          final nome = _normalizarIntencao(opcao['nome']?.toString() ?? '');
          if (nome.isEmpty) return false;
          if (RegExp(r'(?:^| )' + RegExp.escape(nome) + r'(?: |$)')
              .hasMatch(texto)) return true;
          return nome.split(' ').any((palavra) =>
              palavra.length >= 4 &&
              RegExp(r'(?:^| )' + RegExp.escape(palavra) + r'(?: |$)')
                  .hasMatch(texto));
        })
        .map((opcao) => opcao['id'].toString())
        .toList();
  }

  Future<void> _salvarLinhaEditadaNoResumo(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    int indice,
    Map<String, dynamic> item,
  ) async {
    final itens = (dados['itens'] as List? ?? const [])
        .whereType<Map>()
        .map((raw) => Map<String, dynamic>.from(raw))
        .toList();
    final pendencia = dados['edicaoMarmitaResumo'];
    final novaMarmita = pendencia is Map && pendencia['nova'] == true;
    if (indice < 0 ||
        indice > itens.length ||
        (indice == itens.length && !novaMarmita)) return;
    if (indice == itens.length) {
      final indiceExistente = itens.indexWhere(
          (existente) => _chaveCombinacao(existente) == _chaveCombinacao(item));
      if (indiceExistente < 0) {
        itens.add(item);
      } else {
        final quantidadeAtual =
            (itens[indiceExistente]['quantidade'] as num?)?.toInt() ?? 0;
        final quantidadeNova = (item['quantidade'] as num?)?.toInt() ?? 0;
        if (quantidadeAtual + quantidadeNova > 50) {
          dados.remove('edicaoMarmitaResumo');
          banco.salvarSessao(
            telefone: msg.telefone,
            nome: msg.nome,
            etapa: 'confirmacao',
            dados: dados,
          );
          await whatsapp.enviarTexto(
            msg.telefone,
            'O limite por combinação é 50 marmitas. A nova quantidade não foi adicionada.',
          );
          return;
        }
        itens[indiceExistente]['quantidade'] = quantidadeAtual + quantidadeNova;
      }
    } else {
      itens[indice] = item;
    }
    dados
      ..remove('edicaoMarmitaResumo')
      ..['itens'] = itens;
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'confirmacao',
      dados: dados,
    );
    await whatsapp.enviarTexto(msg.telefone, 'Atualizei a marmita no pedido.');
    await _mostrarResumo(msg, config, dados);
  }

  Future<bool> _continuarEdicaoMarmitaNoResumo(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    final raw = dados['edicaoMarmitaResumo'];
    if (raw is! Map) return false;
    final pendente = Map<String, dynamic>.from(raw);
    final campo = pendente['campo']?.toString() ?? '';
    final plural = campo == 'misturas' ? 'misturas' : 'acompanhamentos';
    final singular = campo == 'misturas' ? 'mistura' : 'acompanhamento';
    final colecao = plural;
    final opcoes = _itensAtivos(banco.obterCardapio(), colecao);
    final idsMencionados = _opcoesMencionadasNaFrase(entrada, opcoes);
    final idsNovos = idsMencionados.isNotEmpty
        ? idsMencionados
        : <String>[
            if (_resolverOpcaoNatural(entrada, opcoes) case final opcao?)
              opcao['id'].toString(),
          ];
    if (idsNovos.isEmpty) {
      await whatsapp.enviarTexto(
        msg.telefone,
        'Não identifiquei a $singular. ${_opcoesEmTexto(opcoes)}',
      );
      return true;
    }
    final selecionadas = (pendente['selecionadas'] as List? ?? const [])
        .map((id) => id.toString())
        .toList();
    for (final id in idsNovos) {
      if (!selecionadas.contains(id)) selecionadas.add(id);
    }
    final quantidade = (pendente['quantidade'] as num?)?.toInt() ?? 1;
    if (selecionadas.length > quantidade) {
      await whatsapp.enviarTexto(
        msg.telefone,
        'Essa marmita leva $quantidade $singular(is). Escolha exatamente $quantidade opção(ões): ${_opcoesEmTexto(opcoes)}',
      );
      return true;
    }
    final indice = (pendente['indice'] as num?)?.toInt() ?? -1;
    final item = Map<String, dynamic>.from(pendente['item'] as Map);
    void aplicarEscolhas(String nomeCampo, List<String> ids) {
      final nomePlural =
          nomeCampo == 'misturas' ? 'misturaNomes' : 'acompanhamentoNomes';
      final idPlural =
          nomeCampo == 'misturas' ? 'misturaIds' : 'acompanhamentoIds';
      final legadoNome =
          nomeCampo == 'misturas' ? 'misturaNome' : 'acompanhamentoNome';
      final legadoId =
          nomeCampo == 'misturas' ? 'misturaId' : 'acompanhamentoId';
      final nomes = ids
          .map((id) => opcoes
              .firstWhere((opcao) => opcao['id'].toString() == id)['nome']
              .toString())
          .toList();
      item[idPlural] = ids;
      item[nomePlural] = nomes;
      item[legadoId] = ids.first;
      item[legadoNome] = nomes.first;
    }

    if (selecionadas.length < quantidade) {
      pendente['selecionadas'] = selecionadas;
      dados['edicaoMarmitaResumo'] = pendente;
      banco.salvarSessao(
        telefone: msg.telefone,
        nome: msg.nome,
        etapa: 'confirmacao',
        dados: dados,
      );
      await whatsapp.enviarTexto(
        msg.telefone,
        'Qual outra $singular você prefere? ${_opcoesEmTexto(opcoes)}',
      );
      return true;
    }

    aplicarEscolhas(campo, selecionadas);
    final proximoCampo = pendente['proximoCampo']?.toString();
    final quantidadeProxima =
        (pendente['quantidadeProxima'] as num?)?.toInt() ?? 0;
    if (proximoCampo != null && quantidadeProxima > 0) {
      dados['edicaoMarmitaResumo'] = {
        'indice': indice,
        'item': item,
        'campo': proximoCampo,
        'quantidade': quantidadeProxima,
        'selecionadas': <String>[],
        if (pendente['nova'] == true) 'nova': true,
      };
      final proxima = proximoCampo == 'misturas' ? 'mistura' : 'acompanhamento';
      final opcoesProximas = _itensAtivos(
        banco.obterCardapio(),
        proximoCampo,
      );
      await whatsapp.enviarTexto(
        msg.telefone,
        'Agora escolha ${quantidadeProxima == 1 ? 'o' : 'os'} $proxima${quantidadeProxima == 1 ? '' : 's'}: ${_opcoesEmTexto(opcoesProximas)}',
      );
      banco.salvarSessao(
        telefone: msg.telefone,
        nome: msg.nome,
        etapa: 'confirmacao',
        dados: dados,
      );
      return true;
    }
    await _salvarLinhaEditadaNoResumo(msg, config, dados, indice, item);
    return true;
  }

  Future<void> _iniciarEscolhasEdicaoMarmita(
    MensagemWhatsApp msg,
    Map<String, dynamic> dados, {
    required int indice,
    required Map<String, dynamic> item,
    required String campo,
    required int quantidade,
    String? proximoCampo,
    int quantidadeProxima = 0,
    List<String> selecionadas = const [],
    bool nova = false,
  }) async {
    final opcoes = _itensAtivos(banco.obterCardapio(), campo);
    dados['edicaoMarmitaResumo'] = {
      'indice': indice,
      'item': item,
      'campo': campo,
      'quantidade': quantidade,
      'selecionadas': selecionadas,
      if (nova) 'nova': true,
      if (proximoCampo != null) 'proximoCampo': proximoCampo,
      if (quantidadeProxima > 0) 'quantidadeProxima': quantidadeProxima,
    };
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'confirmacao',
      dados: dados,
    );
    final rotulo = campo == 'misturas' ? 'mistura' : 'acompanhamento';
    await whatsapp.enviarTexto(
      msg.telefone,
      'Essa marmita precisa de $quantidade $rotulo${quantidade == 1 ? '' : 's'}. Quais você prefere? ${_opcoesEmTexto(opcoes)}',
    );
  }

  String _opcoesEmTexto(List<Map<String, dynamic>> opcoes) =>
      opcoes.map((opcao) => opcao['nome'].toString()).join(', ');

  List<int> _marmitasMencionadas(
    String entrada,
    List<Map<String, dynamic>> itens,
  ) {
    final texto = _normalizarIntencao(entrada);
    const ordinais = {
      'primeira': 1,
      'segunda': 2,
      'terceira': 3,
      'quarta': 4,
      'quinta': 5,
      'sexta': 6,
      'setima': 7,
      'oitava': 8,
      'nona': 9,
      'decima': 10,
    };
    final ordinal = RegExp(
            r'^(?:a\s+)?(primeira|segunda|terceira|quarta|quinta|sexta|setima|oitava|nona|decima)$')
        .firstMatch(texto);
    if (ordinal != null) {
      final indice = (ordinais[ordinal.group(1)] ?? 0) - 1;
      return indice >= 0 && indice < itens.length ? [indice] : [];
    }
    final numeroLinha = RegExp(r'^\s*(?:a\s+)?(\d+)\s*$').firstMatch(texto);
    if (numeroLinha != null) {
      final indice = (int.tryParse(numeroLinha.group(1)!) ?? 0) - 1;
      return indice >= 0 && indice < itens.length ? [indice] : [];
    }
    final indiceExplicito =
        RegExp(r'\b(?:marmita|item|linha)\s*(\d+)\b').firstMatch(texto);
    if (indiceExplicito != null) {
      final indice = int.tryParse(indiceExplicito.group(1)!) ?? 0;
      return indice >= 1 && indice <= itens.length ? [indice - 1] : [];
    }
    final cardapio = banco.obterCardapio();
    final tamanho = _resolverTamanhoOpcaoNatural(
      entrada,
      _itensAtivos(cardapio, 'tamanhos'),
    );
    final misturas = _opcoesMencionadasNaFrase(
      entrada,
      _itensAtivos(cardapio, 'misturas'),
    ).toSet();
    final acompanhamentos = _opcoesMencionadasNaFrase(
      entrada,
      _itensAtivos(cardapio, 'acompanhamentos'),
    ).toSet();
    final arroz = cardapio['fluxoArrozAtivo'] == true
        ? _opcoesMencionadasNaFrase(
            entrada,
            _itensAtivos(cardapio, 'arrozes'),
          ).toSet()
        : <String>{};
    final feijao = cardapio['fluxoFeijaoAtivo'] == true
        ? _opcoesMencionadasNaFrase(
            entrada,
            _itensAtivos(cardapio, 'feijoes'),
          ).toSet()
        : <String>{};
    final temIdentificador = tamanho != null ||
        misturas.isNotEmpty ||
        acompanhamentos.isNotEmpty ||
        arroz.isNotEmpty ||
        feijao.isNotEmpty;
    if (!temIdentificador) {
      return List<int>.generate(itens.length, (indice) => indice);
    }
    return List<int>.generate(itens.length, (indice) => indice).where((indice) {
      final item = itens[indice];
      if (tamanho != null && item['tamanhoId']?.toString() != tamanho['id']) {
        return false;
      }
      bool contemTodos(Set<String> pedidos, String plural, String singular) {
        if (pedidos.isEmpty) return true;
        final ids = (item[plural] as List? ?? [item[singular]])
            .where((id) => id != null)
            .map((id) => id.toString())
            .toSet();
        return pedidos.every(ids.contains);
      }

      return contemTodos(misturas, 'misturaIds', 'misturaId') &&
          contemTodos(
              acompanhamentos, 'acompanhamentoIds', 'acompanhamentoId') &&
          contemTodos(arroz, 'arrozIds', 'arrozId') &&
          contemTodos(feijao, 'feijaoIds', 'feijaoId');
    }).toList();
  }

  int? _indiceMarmitaExplicito(String entrada, int quantidadeItens) {
    final texto = _normalizarIntencao(entrada);
    const ordinais = {
      'primeira': 1,
      'segunda': 2,
      'terceira': 3,
      'quarta': 4,
      'quinta': 5,
      'sexta': 6,
      'setima': 7,
      'oitava': 8,
      'nona': 9,
      'decima': 10,
    };
    final ordinal = RegExp(
      r'^(?:a\s+)?(primeira|segunda|terceira|quarta|quinta|sexta|setima|oitava|nona|decima)$',
    ).firstMatch(texto);
    if (ordinal != null) return (ordinais[ordinal.group(1)] ?? 0) - 1;
    final numeroDireto = RegExp(r'^\s*(?:a\s+)?(\d+)\s*$').firstMatch(texto);
    if (numeroDireto != null) {
      return (int.tryParse(numeroDireto.group(1)!) ?? 0) - 1;
    }
    final indiceExplicito =
        RegExp(r'\b(?:marmita|item|linha)\s*(\d+)\b').firstMatch(texto);
    if (indiceExplicito == null) return null;
    final indice = int.tryParse(indiceExplicito.group(1)!) ?? 0;
    return indice >= 1 && indice <= quantidadeItens ? indice - 1 : -1;
  }

  String _descricaoMarmitaParaEscolha(
    Map<String, dynamic> item,
    int indice,
  ) {
    final quantidade = (item['quantidade'] as num?)?.toInt() ?? 1;
    final misturas = _nomeEscolhasItem(item, 'misturaNomes', 'misturaNome');
    final acompanhamentos =
        _nomeEscolhasItem(item, 'acompanhamentoNomes', 'acompanhamentoNome');
    return '• ${quantidade}x ${item['tamanhoNome']} — '
        '$misturas com $acompanhamentos';
  }

  Future<bool> _tratarRemocaoMarmitaNoResumo(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    final itens = (dados['itens'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final texto = _normalizarIntencao(entrada);

    if (_ehRemocaoTotalMarmitas(texto)) {
      _salvarInicioLimpo(msg.telefone, msg.nome);
      await whatsapp.enviarTexto(
        msg.telefone,
        'Certo, removi todas as marmitas e bebidas. O pedido não foi enviado.',
      );
      return true;
    }

    if (_normalizar(entrada) == 'confirmacao_sem_adicionar_marmita' ||
        _ehRecusaDeAdicionarMarmita(texto)) {
      await whatsapp.enviarTexto(
        msg.telefone,
        'Certo, mantive o pedido atual sem adicionar outra marmita.',
      );
      await _mostrarResumo(msg, config, dados);
      return true;
    }

    final pendencia = dados['acaoPendenteResumo'];
    final ehRemocao =
        pendencia is Map && pendencia['tipo'] == 'remover_marmita';
    final contemAcao = RegExp(
      r'\b(?:tira|tirar|retira|retirar|remove|remover|exclui|excluir|nao quero|nao quer|nao vou querer|nao vai querer|nao vou levar)\b',
    ).hasMatch(texto);
    final querUma = RegExp(r'\b(?:uma|um|1)\b').hasMatch(texto) ||
        RegExp(r'\b(?:a|uma|um|1)\s+marmita\b').hasMatch(texto);
    if (!ehRemocao && (!contemAcao || !querUma)) return false;
    if (!ehRemocao &&
        RegExp(r'\b(?:outra|mais uma|adicionar|adiciona)\b').hasMatch(texto)) {
      return false;
    }
    if (itens.isEmpty) {
      dados.remove('acaoPendenteResumo');
      await whatsapp.enviarTexto(msg.telefone, 'Não há marmitas para remover.');
      return true;
    }

    final candidatos = _marmitasMencionadas(entrada, itens);
    final indice = candidatos.length == 1
        ? candidatos.single
        : ehRemocao &&
                RegExp(r'^\s*(?:a\s+)?\d+\s*$').hasMatch(texto) &&
                int.parse(texto.replaceAll(RegExp(r'\D'), '')) <= itens.length
            ? int.parse(texto.replaceAll(RegExp(r'\D'), '')) - 1
            : null;
    if (indice == null || indice < 0 || indice >= itens.length) {
      dados['acaoPendenteResumo'] = {'tipo': 'remover_marmita'};
      banco.salvarSessao(
        telefone: msg.telefone,
        nome: msg.nome,
        etapa: 'confirmacao',
        dados: dados,
      );
      await whatsapp.enviarTexto(
        msg.telefone,
        'Qual combinação você quer remover?\n${List.generate(itens.length, (i) => _descricaoMarmitaParaEscolha(itens[i], i)).join('\n')}',
      );
      return true;
    }

    final quantidade = (itens[indice]['quantidade'] as num?)?.toInt() ?? 1;
    if (quantidade > 1) {
      itens[indice]['quantidade'] = quantidade - 1;
    } else {
      itens.removeAt(indice);
    }
    dados
      ..remove('acaoPendenteResumo')
      ..['itens'] = itens;
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'confirmacao',
      dados: dados,
    );
    if (itens.isEmpty && (dados['bebidas'] as List? ?? const []).isEmpty) {
      _salvarInicioLimpo(msg.telefone, msg.nome);
      await whatsapp.enviarTexto(
        msg.telefone,
        'Removi a última marmita. Seu pedido ficou vazio e não foi enviado.',
      );
      return true;
    }
    await whatsapp.enviarTexto(msg.telefone, 'Removi uma marmita do pedido.');
    await _mostrarResumo(msg, config, dados);
    return true;
  }

  Future<bool> _tratarAlteracaoMarmitaNaConfirmacao(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    final texto = _normalizarIntencao(entrada);
    final itens = (dados['itens'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    if (itens.isEmpty) return false;
    final pendente = dados['acaoPendenteResumo'];
    if (pendente is Map &&
        pendente['tipo'] == 'identificar_alteracao_marmita') {
      final candidatos = _marmitasMencionadas(entrada, itens);
      if (candidatos.length != 1) {
        await whatsapp.enviarTexto(
          msg.telefone,
          'Ainda não identifiquei qual combinação você quer alterar.\n${List.generate(itens.length, (i) => _descricaoMarmitaParaEscolha(itens[i], i)).join('\n')}',
        );
        return true;
      }
      final operacao = pendente['entrada']?.toString() ?? '';
      dados.remove('acaoPendenteResumo');
      return _tratarAlteracaoMarmitaNaConfirmacao(
        msg,
        config,
        dados,
        'marmita ${candidatos.single + 1} $operacao',
      );
    }
    final querTrocar = RegExp(
      r'\b(?:troca(?:r)?|muda(?:r)?|altera(?:r)?|substitui(?:r)?)\b',
    ).hasMatch(texto);
    final querQuantidade = RegExp(
      r'\b(?:quantidade|qtd|unidades|marmitas)\b',
    ).hasMatch(texto);
    if (!querTrocar && !querQuantidade) return false;
    if (querQuantidade) {
      final valor =
          RegExp(r'\b(?:para|por)\s+(\d{1,2})\b').firstMatch(texto)?.group(1);
      final qtd = valor == null ? null : int.tryParse(valor);
      if (qtd == null || qtd < 1 || qtd > 50) {
        await whatsapp.enviarTexto(
          msg.telefone,
          'Quantas marmitas você quer nessa combinação?',
        );
        return true;
      }
      final textoAlvo = texto
          .replaceFirst(RegExp(r'\b(?:para|por|no lugar de)\b.*$'), '')
          .trim();
      final indiceExplicito = _indiceMarmitaExplicito(entrada, itens.length);
      final candidatos = indiceExplicito == null
          ? _marmitasMencionadas(textoAlvo, itens)
          : indiceExplicito >= 0 && indiceExplicito < itens.length
              ? [indiceExplicito]
              : <int>[];
      if (candidatos.length != 1) {
        dados['acaoPendenteResumo'] = {
          'tipo': 'identificar_alteracao_marmita',
          'entrada': entrada,
        };
        banco.salvarSessao(
          telefone: msg.telefone,
          nome: msg.nome,
          etapa: 'confirmacao',
          dados: dados,
        );
        await whatsapp.enviarTexto(
          msg.telefone,
          'Qual combinação você quer alterar?\n${List.generate(itens.length, (i) => _descricaoMarmitaParaEscolha(itens[i], i)).join('\n')}',
        );
        return true;
      }
      final indice = candidatos.single;
      itens[indice]['quantidade'] = qtd;
      dados['itens'] = itens;
      banco.salvarSessao(
        telefone: msg.telefone,
        nome: msg.nome,
        etapa: 'confirmacao',
        dados: dados,
      );
      await whatsapp.enviarTexto(msg.telefone, 'Atualizei a quantidade.');
      await _mostrarResumo(msg, config, dados);
      return true;
    }

    final cardapio = banco.obterCardapio();
    final grupos = <String, List<Map<String, dynamic>>>{
      'tamanho': _itensAtivos(cardapio, 'tamanhos'),
      'mistura': _itensAtivos(cardapio, 'misturas'),
      'acompanhamento': _itensAtivos(cardapio, 'acompanhamentos'),
      if (cardapio['fluxoArrozAtivo'] == true)
        'arroz': _itensAtivos(cardapio, 'arrozes'),
      if (cardapio['fluxoFeijaoAtivo'] == true)
        'feijao': _itensAtivos(cardapio, 'feijoes'),
    };
    final trocaEntreCategorias =
        _respostaTrocaEntreCategorias(entrada, cardapio);
    if (trocaEntreCategorias != null) {
      await whatsapp.enviarTexto(msg.telefone, trocaEntreCategorias);
      return true;
    }
    final campoExplicito = <String, List<String>>{
      'tamanho': ['tamanho', 'pequena', 'media', 'grande'],
      'mistura': ['mistura', 'misturado', 'carne', 'frango', 'calabresa'],
      'acompanhamento': ['acompanhamento', 'guarnicao', 'batata', 'macarrao'],
      'arroz': ['arroz'],
      'feijao': ['feijao'],
    };
    var tipo = grupos.keys
        .where((campo) => (campoExplicito[campo] ?? [campo])
            .any((termo) => _contemTermo(texto, [termo])))
        .firstOrNull;
    if (tipo == null) {
      final citados = grupos.entries
          .where((grupo) => grupo.value.any((opcao) {
                final nome =
                    _normalizarIntencao(opcao['nome']?.toString() ?? '');
                return nome.isNotEmpty &&
                    RegExp(r'(?:^| )' + RegExp.escape(nome) + r'(?: |$)')
                        .hasMatch(texto);
              }))
          .map((grupo) => grupo.key)
          .toList();
      if (citados.length == 1) tipo = citados.single;
    }
    if (tipo == null) {
      await whatsapp.enviarTexto(
        msg.telefone,
        'Qual parte da marmita você quer alterar: tamanho, mistura ou acompanhamento?',
      );
      return true;
    }
    final novos = grupos[tipo]!;
    final trechoNovo = RegExp(r'\b(?:por|para|no lugar de)\s+(.+)$')
        .firstMatch(texto)
        ?.group(1)
        ?.trim();
    final opcao = tipo == 'tamanho'
        ? _resolverTamanhoOpcaoNatural(trechoNovo ?? entrada, novos)
        : _resolverOpcaoNatural(trechoNovo ?? entrada, novos);
    final textoAlvo = texto
        .replaceFirst(RegExp(r'\b(?:para|por|no lugar de)\b.*$'), '')
        .trim();
    final indiceExplicito = _indiceMarmitaExplicito(entrada, itens.length);
    final candidatos = indiceExplicito == null
        ? _marmitasMencionadas(textoAlvo, itens)
        : indiceExplicito >= 0 && indiceExplicito < itens.length
            ? [indiceExplicito]
            : <int>[];
    if (candidatos.length != 1) {
      dados['acaoPendenteResumo'] = {
        'tipo': 'identificar_alteracao_marmita',
        'entrada': entrada,
      };
      banco.salvarSessao(
        telefone: msg.telefone,
        nome: msg.nome,
        etapa: 'confirmacao',
        dados: dados,
      );
      await whatsapp.enviarTexto(
        msg.telefone,
        'Qual combinação você quer alterar?\n${List.generate(itens.length, (i) => _descricaoMarmitaParaEscolha(itens[i], i)).join('\n')}',
      );
      return true;
    }
    final indicePedido = candidatos.single;
    final item = itens[indicePedido];
    if (opcao == null) {
      await whatsapp.enviarTexto(
        msg.telefone,
        'Qual opção de $tipo você prefere?',
      );
      return true;
    }
    if (tipo == 'tamanho') {
      final misturaAnterior =
          (item['misturaIds'] as List? ?? [item['misturaId']])
              .where((id) => id != null)
              .map((id) => id.toString())
              .toList();
      final acompanhamentoAnterior =
          (item['acompanhamentoIds'] as List? ?? [item['acompanhamentoId']])
              .where((id) => id != null)
              .map((id) => id.toString())
              .toList();
      final quantidadeMisturas =
          (opcao['quantidadeMisturas'] as num?)?.toInt() ?? 1;
      final quantidadeAcompanhamentos =
          (opcao['quantidadeAcompanhamentos'] as num?)?.toInt() ?? 1;
      item['tamanhoId'] = opcao['id'];
      item['tamanhoNome'] = opcao['nome'];
      item['precoUnitario'] = (opcao['preco'] as num).toDouble();
      item['quantidadeMisturas'] = quantidadeMisturas;
      item['quantidadeAcompanhamentos'] = quantidadeAcompanhamentos;
      final precisaMisturas = misturaAnterior.length != quantidadeMisturas;
      final precisaAcompanhamentos =
          acompanhamentoAnterior.length != quantidadeAcompanhamentos;
      if (precisaMisturas) {
        item
          ..remove('misturaIds')
          ..remove('misturaNomes')
          ..remove('misturaId')
          ..remove('misturaNome');
      }
      if (precisaAcompanhamentos) {
        item
          ..remove('acompanhamentoIds')
          ..remove('acompanhamentoNomes')
          ..remove('acompanhamentoId')
          ..remove('acompanhamentoNome');
      }
      if (precisaMisturas && quantidadeMisturas > 0) {
        await _iniciarEscolhasEdicaoMarmita(
          msg,
          dados,
          indice: indicePedido,
          item: item,
          campo: 'misturas',
          quantidade: quantidadeMisturas,
          proximoCampo: precisaAcompanhamentos ? 'acompanhamentos' : null,
          quantidadeProxima:
              precisaAcompanhamentos ? quantidadeAcompanhamentos : 0,
        );
        return true;
      }
      if (precisaAcompanhamentos && quantidadeAcompanhamentos > 0) {
        await _iniciarEscolhasEdicaoMarmita(
          msg,
          dados,
          indice: indicePedido,
          item: item,
          campo: 'acompanhamentos',
          quantidade: quantidadeAcompanhamentos,
        );
        return true;
      }
    } else {
      final campoPlural =
          tipo == 'mistura' ? 'misturaIds' : 'acompanhamentoIds';
      final campoNomes =
          tipo == 'mistura' ? 'misturaNomes' : 'acompanhamentoNomes';
      final quantidadeNecessaria = tipo == 'mistura'
          ? (item['quantidadeMisturas'] as num?)?.toInt() ?? 1
          : (item['quantidadeAcompanhamentos'] as num?)?.toInt() ?? 1;
      if (quantidadeNecessaria > 1) {
        final origemTexto = RegExp(
          r'\b(?:troca(?:r)?|muda(?:r)?|altera(?:r)?|substitui(?:r)?)\s+(?:a|o|as|os)?\s*(.+?)\s+(?:por|para|no lugar de)\s+',
        ).firstMatch(texto)?.group(1);
        final origem = origemTexto == null
            ? null
            : _resolverOpcaoNatural(origemTexto, novos);
        final ids = (item[campoPlural] as List? ?? [item['${tipo}Id']])
            .where((id) => id != null)
            .map((id) => id.toString())
            .toList();
        final indiceOrigem =
            origem == null ? -1 : ids.indexOf(origem['id'].toString());
        if (indiceOrigem >= 0) {
          ids[indiceOrigem] = opcao['id'].toString();
          final nomes = ids
              .map((id) => novos
                  .firstWhere((opcao) => opcao['id'].toString() == id)['nome']
                  .toString())
              .toList();
          item[campoPlural] = ids;
          item[campoNomes] = nomes;
          item['${tipo}Id'] = ids.first;
          item['${tipo}Nome'] = nomes.first;
          await _salvarLinhaEditadaNoResumo(
            msg,
            config,
            dados,
            indicePedido,
            item,
          );
          return true;
        }
        await _iniciarEscolhasEdicaoMarmita(
          msg,
          dados,
          indice: indicePedido,
          item: item,
          campo: tipo == 'mistura' ? 'misturas' : 'acompanhamentos',
          quantidade: quantidadeNecessaria,
          selecionadas: [opcao['id'].toString()],
        );
        return true;
      }
      item[campoPlural] = [opcao['id']];
      item[campoNomes] = [opcao['nome']];
      item['${tipo}Id'] = opcao['id'];
      item['${tipo}Nome'] = opcao['nome'];
    }
    await _salvarLinhaEditadaNoResumo(
      msg,
      config,
      dados,
      indicePedido,
      item,
    );
    return true;
  }

  Future<bool> _tratarBebidaNaConfirmacao(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    final bebidas = (dados['bebidas'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final texto = _normalizarIntencao(entrada);
    if (!_mencionaBebidaNoTexto(texto)) return false;
    if (bebidas.isEmpty) {
      final bebida = _capturarBebidaAdicional(entrada);
      if (bebida != null) {
        await _adicionarBebidaAoResumo(
          msg,
          config,
          banco.obterSessao(msg.telefone),
          bebida,
        );
      } else {
        banco.salvarSessao(
          telefone: msg.telefone,
          nome: msg.nome,
          etapa: 'confirmacao',
          dados: dados,
        );
        await whatsapp.enviarTexto(
          msg.telefone,
          'Qual bebida você gostaria de incluir?',
        );
      }
      return true;
    }
    final troca = RegExp(
      r'(?:troca|trocar|muda|mudar|substitui(?:r)?)\s+(?:a|o|as|os)?\s*(?:bebida\s+)?(.+?)\s+(?:por|para)\s+(.+)$',
    ).firstMatch(texto);

    if (troca != null) {
      final alvo =
          _resolverOpcaoNatural(_semArtigo(troca.group(1)!.trim()), bebidas);
      final nova = _resolverOpcaoNatural(
          _semArtigo(troca.group(2)!.trim()), _bebidasAtivas());
      if (alvo == null || nova == null) {
        await whatsapp.enviarTexto(
          msg.telefone,
          'Me diga qual bebida você quer tirar e qual prefere colocar no lugar.',
        );
        return true;
      }
      final bebidasNovas = bebidas
          .where((item) =>
              _normalizar(item['nome']?.toString() ?? '') !=
              _normalizar(alvo['nome']?.toString() ?? ''))
          .toList();
      bebidasNovas.add({
        'bebidaId': nova['id'],
        'nome': nova['nome'],
        'precoUnitario': (nova['preco'] as num?)?.toDouble() ?? 0.0,
        'quantidade': (alvo['quantidade'] as num?)?.toInt() ?? 1,
      });
      dados['bebidas'] = bebidasNovas;
      banco.salvarSessao(
        telefone: msg.telefone,
        nome: msg.nome,
        etapa: 'confirmacao',
        dados: dados,
      );
      await whatsapp.enviarTexto(
        msg.telefone,
        'Troquei ${alvo['nome']} por ${nova['nome']}.',
      );
      await _mostrarResumo(msg, config, dados);
      return true;
    }

    if (_contemTermo(texto,
        ['troca', 'trocar', 'muda', 'mudar', 'substitui', 'substituir'])) {
      await whatsapp.enviarTexto(
        msg.telefone,
        'Qual bebida você quer tirar e qual prefere colocar no lugar?',
      );
      return true;
    }

    final remover = RegExp(
      r'^(?:tira|tirar|retira|retirar|remove|remover|sem|nao quero(?: mais)?|nao vou querer|cancela|cancelar)\s+(?:a|o|as|os|minha|meu)?\s*(.+)$',
    ).firstMatch(texto);
    if (remover == null) return false;

    final alvo =
        _resolverOpcaoNatural(_semArtigo(remover.group(1)!.trim()), bebidas);
    if (alvo == null) return false;

    dados['bebidas'] = bebidas
        .where((item) =>
            _normalizar(item['nome']?.toString() ?? '') !=
            _normalizar(alvo['nome']?.toString() ?? ''))
        .toList();
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'confirmacao',
      dados: dados,
    );
    await whatsapp.enviarTexto(
      msg.telefone,
      'Pronto, removi ${alvo['nome']} do pedido.',
    );
    await _mostrarResumo(msg, config, dados);
    return true;
  }

  bool _descartarRascunhoProximaMarmita(Map<String, dynamic> sessao) {
    final dados = Map<String, dynamic>.from(sessao['dados'] as Map? ?? {});
    final itens =
        (dados['itens'] as List? ?? const []).whereType<Map>().toList();
    if (itens.isEmpty) return false;
    final rascunho = Map<String, dynamic>.from(
      dados['rascunhoPedidoIA'] as Map? ?? const {},
    );
    final linhas =
        (rascunho['itens'] as List? ?? const []).whereType<Map>().toList();
    final cardapio = banco.obterCardapio();
    final incompleto = linhas.any((linha) => !_rascunhoItemCompleto(
          Map<String, dynamic>.from(linha),
          arrozAtivo: cardapio['fluxoArrozAtivo'] == true,
          feijaoAtivo: cardapio['fluxoFeijaoAtivo'] == true,
        ));
    return sessao['etapa'] == 'adicionar_outro' ||
        sessao['etapa'] == 'ia_pedido' ||
        incompleto;
  }

  Future<void> _mostrarBebidasOuResumo(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
  ) async {
    dados.putIfAbsent('bebidas', () => <dynamic>[]);
    if (_bebidasAtivas().isEmpty) {
      await _mostrarResumo(msg, config, dados);
      return;
    }
    await _mostrarBebidas(msg, dados);
  }

  Future<void> _mostrarBebidas(
      MensagemWhatsApp msg, Map<String, dynamic> dados) async {
    final lista = _bebidasAtivas();
    if (lista.isEmpty) {
      final config =
          Map<String, dynamic>.from(banco.obterConfiguracao()['dados'] as Map);
      await _mostrarResumo(msg, config, dados);
      return;
    }
    dados['opcoesExibidas'] = lista;
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'bebida',
      dados: dados,
    );
    final opcoes = lista
        .map((b) => <String, String>{
              'id': 'beb:${b['id']}',
              'titulo': '${b['nome']} ${moeda((b['preco'] as num).toDouble())}',
              'descricao': 'Escolher bebida',
            })
        .toList()
      ..add({
        'id': 'beb_sem',
        'titulo': _textoFluxo('bebida', 'botaoSemBebida', 'Sem bebida'),
        'descricao': 'Continuar sem adicionar bebida',
      });
    if (opcoes.length <= 3) {
      await _enviarBotoes(
          msg.telefone,
          _textoFluxo(
              'bebida',
              'mensagem',
              _modoIaAtivo
                  ? 'Quer alguma bebida?'
                  : 'Deseja adicionar uma bebida?'),
          opcoes);
    } else {
      await _enviarLista(
        msg.telefone,
        texto: _textoFluxo(
            'bebida',
            'mensagem',
            _modoIaAtivo
                ? 'Quer alguma bebida?'
                : 'Deseja adicionar uma bebida?'),
        tituloBotao: _textoFluxo('bebida', 'tituloLista', 'Ver bebidas'),
        opcoes: opcoes,
      );
    }
  }

  Future<void> _tratarBebida(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    if (_ehNegacaoOpcional(entrada) ||
        _corresponde(entrada, [
          'beb_sem',
          'sem bebida',
          'nao',
          'não',
          'n',
          _textoFluxo('bebida', 'botaoSemBebida', 'Sem bebida'),
        ])) {
      await _mostrarResumo(msg, config, dados);
      return;
    }
    final lista = (dados['opcoesExibidas'] as List? ?? _bebidasAtivas())
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((e) => e['ativo'] == true)
        .toList();
    if (!_modoIaAtivo && int.tryParse(entrada) == lista.length + 1) {
      await _mostrarResumo(msg, config, dados);
      return;
    }
    final escolhida = _acharOpcao(entrada, lista, prefixo: 'beb:');
    if (escolhida == null) {
      await _mostrarBebidas(msg, dados);
      return;
    }
    dados['bebidaAtual'] = {
      'bebidaId': escolhida['id'],
      'nome': escolhida['nome'],
      'precoUnitario': (escolhida['preco'] as num).toDouble(),
    };
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'quantidade_bebida',
      dados: dados,
    );
    final maximo = _intFluxo('quantidadeBebida', 'maximo', 20).clamp(1, 50);
    final titulo = _textoFluxo(
        'quantidadeBebida', 'mensagem', 'Quantas unidades desta bebida?');
    final ajuda = _textoFluxo('quantidadeBebida', 'ajuda',
            'Digite apenas a quantidade de 1 a {max}.')
        .replaceAll('{max}', '$maximo');
    await whatsapp.enviarTexto(
      msg.telefone,
      _modoIaAtivo ? titulo : '$titulo\n$ajuda',
    );
  }

  Future<void> _tratarQuantidadeBebida(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    final maximo = _intFluxo('quantidadeBebida', 'maximo', 20).clamp(1, 50);
    final quantidade = _parseQuantidade(entrada);
    if (quantidade == null || quantidade < 1 || quantidade > maximo) {
      await whatsapp.enviarTexto(
        msg.telefone,
        _modoIaAtivo
            ? 'Quantas unidades você gostaria?'
            : 'Digite somente um número de 1 a $maximo. Ex.: *2*.',
      );
      return;
    }
    final atual = Map<String, dynamic>.from(dados['bebidaAtual'] as Map);
    final bebidas = (dados['bebidas'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final existente =
        bebidas.indexWhere((e) => e['bebidaId'] == atual['bebidaId']);
    if (existente >= 0) {
      bebidas[existente]['quantidade'] =
          (bebidas[existente]['quantidade'] as num).toInt() + quantidade;
    } else {
      atual['quantidade'] = quantidade;
      bebidas.add(atual);
    }
    dados['bebidas'] = bebidas;
    dados.remove('bebidaAtual');
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'adicionar_outra_bebida',
      dados: dados,
    );
    await _enviarBotoes(
      msg.telefone,
      _textoFluxo(
          'adicionarOutraBebida',
          'mensagem',
          _modoIaAtivo
              ? 'Quer mais alguma bebida?'
              : '🥤 Bebida adicionada. Deseja adicionar outra?'),
      [
        {
          'id': 'beb_outra',
          'titulo':
              _textoFluxo('adicionarOutraBebida', 'botaoSim', 'Adicionar outra')
        },
        {
          'id': 'beb_finalizar',
          'titulo': _textoFluxo(
              'adicionarOutraBebida', 'botaoNao', 'Finalizar bebidas')
        },
      ],
    );
  }

  Future<void> _tratarAdicionarOutraBebida(
    MensagemWhatsApp msg,
    Map<String, dynamic> config,
    Map<String, dynamic> dados,
    String entrada,
  ) async {
    final bebidaInformada =
        _acharOpcao(entrada, _bebidasAtivas(), prefixo: 'beb:');
    if (bebidaInformada != null) {
      dados['bebidaAtual'] = {
        'bebidaId': bebidaInformada['id'],
        'nome': bebidaInformada['nome'],
        'precoUnitario': (bebidaInformada['preco'] as num).toDouble(),
      };
      banco.salvarSessao(
        telefone: msg.telefone,
        nome: msg.nome,
        etapa: 'quantidade_bebida',
        dados: dados,
      );
      await whatsapp.enviarTexto(
        msg.telefone,
        _textoFluxo(
          'quantidadeBebida',
          'mensagem',
          'Quantas unidades desta bebida?',
        ),
      );
      return;
    }
    if (_ehConfirmacaoOpcional(entrada) ||
        _corresponde(entrada, [
          'beb_outra',
          if (!_modoIaAtivo) '1',
          'sim',
          's',
          'claro',
          'mais uma',
          'quero outra',
          'quero mais uma',
          'adicionar mais uma',
          'adicionar outra bebida',
          _textoFluxo('adicionarOutraBebida', 'botaoSim', 'Adicionar outra'),
        ])) {
      await _mostrarBebidas(msg, dados);
      return;
    }
    if (_ehNegacaoOpcional(entrada) ||
        _corresponde(entrada, [
          'beb_finalizar',
          if (!_modoIaAtivo) '2',
          'nao',
          'não',
          'n',
          _textoFluxo('adicionarOutraBebida', 'botaoNao', 'Finalizar bebidas'),
        ])) {
      await _mostrarResumo(msg, config, dados);
      return;
    }
    await _enviarBotoes(
      msg.telefone,
      _textoFluxo('adicionarOutraBebida', 'mensagem',
          '🥤 Bebida adicionada. Deseja adicionar outra?'),
      [
        {
          'id': 'beb_outra',
          'titulo':
              _textoFluxo('adicionarOutraBebida', 'botaoSim', 'Adicionar outra')
        },
        {
          'id': 'beb_finalizar',
          'titulo': _textoFluxo(
              'adicionarOutraBebida', 'botaoNao', 'Finalizar bebidas')
        },
      ],
    );
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
      final cardapio = banco.obterCardapio();
      final bases = <String>[
        if (cardapio['fluxoArrozAtivo'] == true)
          item['arrozNome']?.toString() ?? 'Arroz',
        if (cardapio['fluxoFeijaoAtivo'] == true)
          item['feijaoNome']?.toString() ?? 'Feijão',
        if (cardapio['fluxoArrozAtivo'] != true &&
            item['arrozDesativado'] != true)
          'arroz',
        if (cardapio['fluxoFeijaoAtivo'] != true &&
            item['feijaoDesativado'] != true)
          'feijão',
      ];
      if (bases.isNotEmpty) linhas.add('🍚 ${bases.join(' + ')}');
      linhas.add(
        '🍽️ ${_nomeEscolhasItem(item, 'misturaNomes', 'misturaNome')} • '
        '${_nomeEscolhasItem(item, 'acompanhamentoNomes', 'acompanhamentoNome')}',
      );
      if (item['saladaIncluida'] == true) {
        linhas.add('🥗 ${item['descricaoSalada'] ?? 'Salada'}');
      }
      linhas.add('');
    }
    if (calculo.bebidas.isNotEmpty) {
      linhas.add('*Bebidas:*');
      for (final bebida in calculo.bebidas) {
        final qtd = (bebida['quantidade'] as num).toInt();
        final preco = (bebida['precoUnitario'] as num).toDouble();
        linhas.add('🥤 ${qtd}x ${bebida['nome']} — ${moeda(preco * qtd)}');
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
    if (calculo.taxaMaquininha > 0) {
      linhas.add('Taxa da maquininha: ${moeda(calculo.taxaMaquininha)}');
    }
    linhas.add('*TOTAL: ${moeda(calculo.total)}*');
    if (_modoIaAtivo) linhas.add('\nFicou tudo certo?');

    await _enviarBotoes(
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
      'cancelar pedido',
      if (!_modoIaAtivo) '3',
      _textoFluxo('resumo', 'botaoCancelar', 'Cancelar')
    ])) {
      _salvarInicioLimpo(msg.telefone, msg.nome);
      await _enviarBotoes(
        msg.telefone,
        _textoFluxo(
            'sistema',
            'pedidoCancelado',
            _modoIaAtivo
                ? 'Pedido cancelado. 🙂'
                : 'Pedido cancelado. 🙂\nEscolha uma opção quando quiser:'),
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
        if (!_modoIaAtivo) '2',
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

    if (_modoIaAtivo) {
      if (await _continuarEdicaoMarmitaNoResumo(
        msg,
        config,
        dados,
        entrada,
      )) {
        return;
      }
      if (await _tratarRemocaoMarmitaNoResumo(
        msg,
        config,
        dados,
        entrada,
      )) {
        return;
      }
      if (await _tratarBebidaNaConfirmacao(msg, config, dados, entrada)) {
        return;
      }
      if (await _tratarAlteracaoMarmitaNaConfirmacao(
        msg,
        config,
        dados,
        entrada,
      )) {
        return;
      }
      final captura = _capturarAdicaoMarmitasConfirmacao(entrada, dados);
      if (captura != null) {
        await _adicionarMarmitasPosResumo(msg, config, dados, captura);
        return;
      }
    }

    if (!_corresponde(entrada, [
          'conf_confirmar',
          'confirmar',
          'confirmar pedido',
          if (!_modoIaAtivo) '1',
          _textoFluxo('resumo', 'botaoConfirmar', 'Confirmar')
        ]) &&
        !_ehConfirmacaoDoResumo(entrada)) {
      await whatsapp.enviarTexto(
        msg.telefone,
        'Não confirmei o pedido. Para confirmar, diga “sim, confirmar pedido”; se quiser alterar, me diga o que devo mudar.',
      );
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
        _modoIaAtivo
            ? 'A forma de receber escolhida ficou indisponível. Como você prefere receber o pedido?'
            : 'A forma de receber escolhida ficou indisponível. Escolha uma opção atual:',
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
          _modoIaAtivo
              ? 'Não conseguimos entregar nesse endereço. Pode me informar outro endereço ou prefere retirar?'
              : 'A entrega para a cidade do seu endereço ficou indisponível. Envie outro endereço atendido ou digite *voltar* para escolher retirada.',
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
        _modoIaAtivo
            ? 'Essa forma de pagamento está indisponível. Qual outra você prefere?'
            : 'A forma de pagamento escolhida ficou indisponível. Escolha outra:',
      );
      await _mostrarPagamentos(msg, config, dados);
      return;
    }

    if (pagamento == 'pix' &&
        (config['chavePix']?.toString().trim().isEmpty ?? true)) {
      dados.remove('pagamento');
      await whatsapp.enviarTexto(
        msg.telefone,
        _modoIaAtivo
            ? 'O PIX está temporariamente indisponível. Qual outra forma de pagamento você prefere?'
            : 'O PIX está temporariamente indisponível. Escolha outra forma de pagamento.',
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
      taxaMaquininha: calculo.taxaMaquininha,
      itens: calculo.itens,
      bebidas: calculo.bebidas,
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
    final chavePix = config['chavePix']?.toString().trim() ?? '';
    final nomePixConfigurado = config['nomePix']?.toString().trim() ?? '';
    final nomePix = nomePixConfigurado.isNotEmpty
        ? nomePixConfigurado
        : '65.467.376 ERIKA FRANCISCO DE SOUZA';
    final extraPix = pagamento == 'pix' && chavePix.isNotEmpty
        ? '\n\n💠 *══ PAGAMENTO PIX ══*\n👤 $nomePix\n🔑 *CHAVE:* `$chavePix`'
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

  String _nomeEscolhasItem(
    Map<String, dynamic> item,
    String campoLista,
    String campoLegado,
  ) {
    final lista = item[campoLista];
    if (lista is List && lista.isNotEmpty) {
      return lista.map((valor) => valor.toString()).join(' + ');
    }
    return item[campoLegado]?.toString() ?? '';
  }

  CalculoPedido _calcular(
      Map<String, dynamic> dados, Map<String, dynamic> config) {
    final itens = (dados['itens'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final bebidas = (dados['bebidas'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final taxa = dados['recebimento'] == 'entrega'
        ? (dados['taxaEntregaCongelada'] as num?)?.toDouble() ?? 0
        : 0.0;
    final calculoBase = CalculoPedido(itens, taxa, bebidas: bebidas);
    final pagamento = dados['pagamento']?.toString() ?? '';
    final valorPorFaixa = switch (pagamento) {
      'credito' => 2.0,
      'debito' => 1.0,
      _ => 0.0,
    };
    final taxaMaquininha = valorPorFaixa == 0
        ? 0.0
        : ((calculoBase.subtotal + calculoBase.taxaEntrega) / 50).ceil() *
            valorPorFaixa;
    return CalculoPedido(itens, taxa,
        bebidas: bebidas, taxaMaquininha: taxaMaquininha);
  }

  List<String> _itensIndisponiveis(Map<String, dynamic> dados) {
    final cardapio = banco.obterCardapio();
    Set<String> ativos(String chave) => (cardapio[chave] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((e) => e['ativo'] == true)
        .map((e) => e['id'].toString())
        .toSet();

    final tamanhosAtivos = (cardapio['tamanhos'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((e) => e['ativo'] == true)
        .toList();
    final tamanhos = tamanhosAtivos.map((e) => e['id'].toString()).toSet();
    final misturas = ativos('misturas');
    final acompanhamentos = ativos('acompanhamentos');
    final bebidasAtivas = ativos('bebidas');
    final arrozesAtivos = ativos('arrozes');
    final feijoesAtivos = ativos('feijoes');
    final indisponiveis = <String>[];
    for (final raw in (dados['itens'] as List? ?? const [])) {
      final item = Map<String, dynamic>.from(raw as Map);
      if (!tamanhos.contains(item['tamanhoId']?.toString())) {
        indisponiveis.add(item['tamanhoNome'].toString());
      }
      final tamanho = tamanhosAtivos.cast<Map<String, dynamic>?>().firstWhere(
            (opcao) => opcao?['id'] == item['tamanhoId'],
            orElse: () => null,
          );
      final quantidadeMisturas =
          (item['quantidadeMisturas'] as num?)?.toInt() ??
              (tamanho?['quantidadeMisturas'] as num?)?.toInt() ??
              1;
      final quantidadeAcompanhamentos =
          (item['quantidadeAcompanhamentos'] as num?)?.toInt() ??
              (tamanho?['quantidadeAcompanhamentos'] as num?)?.toInt() ??
              1;
      final misturaIds = (item['misturaIds'] as List? ?? [item['misturaId']])
          .map((id) => id?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      if (misturaIds.length != quantidadeMisturas ||
          misturaIds.isEmpty ||
          !misturaIds.every(misturas.contains)) {
        indisponiveis.add(item['misturaNome'].toString());
      }
      final acompanhamentoIds =
          (item['acompanhamentoIds'] as List? ?? [item['acompanhamentoId']])
              .map((id) => id?.toString() ?? '')
              .where((id) => id.isNotEmpty)
              .toSet();
      if (acompanhamentoIds.length != quantidadeAcompanhamentos ||
          acompanhamentoIds.isEmpty ||
          !acompanhamentoIds.every(acompanhamentos.contains)) {
        indisponiveis.add(item['acompanhamentoNome'].toString());
      }
      if (cardapio['fluxoArrozAtivo'] == true &&
          !arrozesAtivos.contains(item['arrozId']?.toString())) {
        indisponiveis.add(item['arrozNome']?.toString() ?? 'Arroz');
      }
      if (cardapio['fluxoFeijaoAtivo'] == true &&
          !feijoesAtivos.contains(item['feijaoId']?.toString())) {
        indisponiveis.add(item['feijaoNome']?.toString() ?? 'Feijão');
      }
    }
    for (final raw in (dados['bebidas'] as List? ?? const [])) {
      final bebida = Map<String, dynamic>.from(raw as Map);
      if (!bebidasAtivas.contains(bebida['bebidaId']?.toString())) {
        indisponiveis.add(bebida['nome'].toString());
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
    if (!_modoIaAtivo &&
        numero != null &&
        numero >= 1 &&
        numero <= lista.length) {
      return lista[numero - 1];
    }
    for (final item in lista) {
      if (_normalizar(item['nome'].toString()) == entrada) return item;
    }
    return _acharOpcaoPorFrase(
      entrada,
      lista,
      (item) => item['nome']?.toString() ?? '',
    );
  }

  Map<String, dynamic>? _acharOpcaoPorFrase(
    String entrada,
    List<Map<String, dynamic>> opcoes,
    String Function(Map<String, dynamic>) obterNome,
  ) =>
      _resolverOpcaoNatural(
        entrada,
        opcoes
            .map((opcao) => <String, dynamic>{
                  ...opcao,
                  'nome': obterNome(opcao),
                })
            .toList(),
      );

  String _descricaoBase(Map<String, dynamic> cardapio) {
    final bases = <String>[
      'arroz${cardapio['fluxoArrozAtivo'] == true ? ' à escolha' : ''}',
      'feijão${cardapio['fluxoFeijaoAtivo'] == true ? ' à escolha' : ''}',
    ];
    return bases.join(' + ');
  }

  String _chaveIdsEscolhas(dynamic lista, dynamic singular) {
    final ids = (lista as List? ?? [singular])
        .map((id) => id?.toString() ?? '')
        .toList()
      ..sort();
    return ids.join(',');
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
    if (!_modoIaAtivo &&
        numero != null &&
        numero >= 1 &&
        numero <= opcoes.length) {
      return opcoes[numero - 1];
    }
    final encontradas = _acharOpcaoPorFrase(
      entrada,
      opcoes.map((opcao) => Map<String, dynamic>.from(opcao)).toList(),
      (opcao) => opcao['titulo']?.toString() ?? '',
    );
    if (encontradas == null) return null;
    return opcoes.firstWhere(
      (opcao) => opcao['id'] == encontradas['id'],
    );
  }

  bool _pagamentoAtivo(Map<String, dynamic> config, String pagamento) {
    final pagamentos =
        Map<String, dynamic>.from(config['pagamentos'] as Map? ?? {});
    return switch (pagamento) {
      'pix' => pagamentos['pix'] == true,
      'dinheiro' => pagamentos['dinheiro'] == true,
      'credito' => pagamentos['credito'] == true ||
          (pagamentos['credito'] == null && pagamentos['cartao'] == true),
      'debito' => pagamentos['debito'] == true ||
          (pagamentos['debito'] == null && pagamentos['cartao'] == true),
      _ => false,
    };
  }

  bool _ehNegacaoDeTroco(String entrada) {
    if (_ehNegacaoOpcional(entrada)) return true;
    final texto = _normalizarIntencao(entrada);
    if (_corresponde(texto, [
      'nao',
      'n',
      'sem troco',
      'nao precisa',
      'nao preciso',
      'nao vou precisar',
      'nao vou querer troco',
      'nao quero troco',
      'nao tem problema',
      'pode ser sem troco',
      'nao precisa de troco',
      'nao preciso de troco',
    ])) {
      return true;
    }
    if (texto.contains('?')) return false;
    final nega = RegExp(r'\b(?:nao|sem|dispenso|deixa)\b').hasMatch(texto);
    final troco =
        RegExp(r'\b(?:troco|preciso|precisar|precisa|vou precisar|quero)\b')
            .hasMatch(texto);
    return nega && troco;
  }

  double? _valorTrocoNatural(String entrada) {
    final direto = _parseValorMonetario(entrada);
    if (direto != null) return direto;
    final texto = _normalizar(entrada).replaceAll('r\$', ' ');
    final match = RegExp(r'(\d{1,4}(?:[.,]\d{1,2})?)').firstMatch(texto);
    if (match == null) return null;
    return _parseValorMonetario(match.group(1)!);
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
    await _enviarBotoes(
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

  bool _ehNegacaoOpcional(String entrada) {
    final texto = _normalizar(entrada);
    if (_corresponde(texto, [
      'n',
      'nao',
      'nenhum',
      'nenhuma',
      'nada',
      'sem',
      'sem bebida',
      'sem bebidas',
      'sem nenhuma bebida',
      'nenhuma bebida',
      'nenhum bebida',
      'dispenso',
      'dispensar',
      'passo',
      'pode deixar',
      'deixa',
      'deixa pra la',
      'sem necessidade',
      'nada pra mim',
      'nada para mim',
      'nao obrigado',
      'nao obrigada',
      'nao valeu',
      'valeu nao',
      'quero nao',
      'nao tenho interesse',
      'nao quero bebida',
      'nao quero bebidas',
      'nao quero nenhuma bebida',
      'nao quero mais bebida',
      'nao quero outra bebida',
      'nao quero adicionar bebida',
      'n quero bebida',
      'n quero bebidas',
      'n quero nenhuma bebida',
      'n quero mais bebida',
      'n quero outra bebida',
      'n quero mais nada',
      'nao quero mais nada',
      'n preciso de bebida',
      'nao preciso de bebida',
      'n precisa de bebida',
      'nao precisa de bebida',
      'n quero adicionar outra',
      'nao quero adicionar outra',
      'nao quero outra marmita',
      'n quero outra marmita',
      'nao vou querer bebida',
    ])) {
      return true;
    }
    return RegExp(
      r'^(?:nao|n)\s+(?:quero|queria|preciso|precisa|vou querer)(?:\s+(?:mais|outra|outro|nenhuma|nenhum|nada|bebida|bebidas|marmita|marmitas|troco|adicionar(?:\s+(?:mais|outra|outras|bebida))?))?$',
    ).hasMatch(texto);
  }

  bool _ehConfirmacaoOpcional(String entrada) {
    final texto =
        _normalizar(entrada).replaceFirst(RegExp(r'^(?:eu|por favor) '), '');
    if (_ehNegacaoOpcional(texto)) return false;
    if (_contemTermo(texto, ['nao', 'nunca'])) return false;
    if (_corresponde(texto, [
      'sim',
      's',
      'claro',
      'com certeza',
      'quero',
      'quero sim',
      'pode',
      'pode ser',
      'manda',
      'adiciona',
      'adicionar',
      'mais uma',
      'quero outra',
      'quero mais uma',
      'adicionar mais uma',
    ])) {
      return true;
    }
    return RegExp(
      r'^(?:sim|claro|com certeza)(?:\s|$)|^(?:quero|queria|gostaria)\s+(?:sim|mais|outra|outro|adicionar|uma|um)\b|^(?:pode|manda|adiciona|adicionar)\s+(?:ser|sim|mais|outra|outro|uma|um|adicionar)\b',
    ).hasMatch(texto);
  }

  bool _ehConfirmacaoDoResumo(String entrada) {
    final texto =
        _normalizar(entrada).replaceFirst(RegExp(r'^(?:eu|por favor) '), '');
    if (_contemTermo(texto, ['nao', 'nunca'])) return false;
    if (_ehPedidoAlteracaoResumo(texto)) return false;
    return _corresponde(texto, [
      'sim',
      's',
      'confirmar',
      'confirmar pedido',
      'confirmo o pedido',
      'conf_confirmar',
      'pode confirmar',
      'pode confirmar o pedido',
      'sim pode confirmar',
      'sim pode confirmar o pedido',
      'sim pode confirmar',
      'beleza pode confirmar o pedido',
      'perfeito pode confirmar o pedido',
      'ok pode confirmar o pedido',
      'ok confirma o pedido',
      'sim confirmar pedido',
      'ok confirmar',
      'ok pode confirmar',
      'okay pode confirmar',
      'beleza pode confirmar',
      'pode finalizar o pedido',
      'pode fechar o pedido',
      'sim pode finalizar o pedido',
      'sim pode fechar o pedido',
    ]);
  }

  bool _ehPedidoAlteracaoResumo(String entrada) {
    final texto = _normalizar(entrada);
    return RegExp(
      r'\b(?:mas|porem|troca|trocar|muda|mudar|altera|alterar|corrige|corrigir|tira|tirar|remove|remover|adiciona|adicionar|sem|no lugar|em vez|na verdade|faltou|esqueci)\b',
    ).hasMatch(texto);
  }

  bool _ehPerguntaQueNaoEhEndereco(String entrada) {
    if (!RegExp(r'\?').hasMatch(entrada)) return false;
    if (RegExp(r'\d').hasMatch(entrada)) return false;
    return !_contemTermo(_normalizar(entrada), const [
      'rua',
      'avenida',
      'av',
      'travessa',
      'alameda',
      'estrada',
      'rodovia',
      'bairro',
      'quadra',
      'casa',
      'apto',
      'apartamento',
      'lote',
      'km',
      'numero',
    ]);
  }

  bool _contemTermo(String entrada, List<String> termos) {
    final texto = ' ${_normalizar(entrada)} ';
    return termos.any((termo) => texto.contains(' ${_normalizar(termo)} '));
  }

  String? _resolverFormaRecebimento(String entrada) {
    final texto = _normalizar(entrada);
    if (_contemTermo(texto, ['nao', 'nunca', 'sem'])) return null;
    final entrega = _contemTermo(
      texto,
      ['entrega', 'entregar', 'casa', 'em casa', 'domicilio', 'delivery'],
    );
    final retirada = _contemTermo(
      texto,
      [
        'retirada',
        'retirar',
        'retiro',
        'buscar',
        'busco',
        'pegar',
        'pego',
        'loja',
        'balcao',
      ],
    );
    if (entrega == retirada) return null;
    return entrega ? 'rec_entrega' : 'rec_retirada';
  }

  bool _ehIntencaoRetirada(String entrada) =>
      _resolverFormaRecebimento(entrada) == 'rec_retirada';

  String? _resolverFormaPagamento(String entrada) {
    final texto = _normalizar(entrada);
    if (_contemTermo(texto, ['nao', 'nunca', 'sem'])) return null;
    final opcoes = <String, List<String>>{
      'pag_pix': ['pix'],
      'pag_dinheiro': ['dinheiro', 'cash'],
      'pag_credito': ['credito'],
      'pag_debito': ['debito'],
    };
    final encontradas = opcoes.entries
        .where((opcao) => _contemTermo(texto, opcao.value))
        .map((opcao) => opcao.key)
        .toList();
    return encontradas.length == 1 ? encontradas.single : null;
  }

  bool _ehPedidoCartaoGenerico(String entrada, Map<String, dynamic> config) {
    final texto = _normalizar(entrada);
    if (!_contemTermo(texto, ['cartao', 'cartoes'])) return false;
    if (_contemTermo(texto, ['credito', 'debito'])) return false;
    final pagamentos =
        Map<String, dynamic>.from(config['pagamentos'] as Map? ?? {});
    final cartaoLegado = pagamentos['cartao'] == true;
    final credito = pagamentos['credito'] == true ||
        (pagamentos['credito'] == null && cartaoLegado);
    final debito = pagamentos['debito'] == true ||
        (pagamentos['debito'] == null && cartaoLegado);
    return credito && debito;
  }

  bool _ehComandoCancelar(String entrada) => _correspondeIntencao(entrada, [
        if (!_modoIaAtivo) '0',
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

  bool _ehComandoHumano(String entrada) {
    if (_correspondeIntencao(entrada, [
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
    ])) {
      return true;
    }
    final texto = _normalizar(entrada);
    return !_contemTermo(texto, ['nao', 'nunca', 'sem']) &&
        _contemTermo(texto, ['atendente', 'humano', 'pessoa', 'alguem']) &&
        _contemTermo(texto, [
          'falar',
          'conversar',
          'chamar',
          'chama',
          'pode',
          'posso',
          'quero',
          'queria',
          'gostaria',
          'preciso',
          'atendimento',
        ]);
  }

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

  bool _ehConsultaStatusPedido(String entrada) {
    final texto = _normalizarIntencao(entrada);
    return _corresponde(texto, [
          'como esta meu pedido',
          'como ta meu pedido',
          'como esta ficando meu pedido',
          'como ta ficando meu pedido',
          'pedido atual',
          'resumo do meu pedido',
          'o que tem no meu pedido',
          'o que eu pedi ate agora',
        ]) ||
        (texto.contains('meu pedido') &&
            _contemTermo(texto, ['agora', 'ate agora', 'resumo', 'status']));
  }

  String _resumirPedidoEmAndamento(Map<String, dynamic>? sessao) {
    if (sessao == null || sessao['etapa'] == 'inicio') {
      return 'Ainda não começamos um pedido. O que você gostaria?';
    }
    final dados = Map<String, dynamic>.from(sessao['dados'] as Map? ?? {});
    final rascunho = Map<String, dynamic>.from(
      dados['rascunhoPedidoIA'] as Map? ?? const {},
    );
    final itens = (rascunho['itens'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    if (itens.isEmpty) {
      return 'Ainda estou montando seu pedido. ${_perguntaProximoDetalhePedido(sessao)}';
    }

    final linhas = <String>[];
    var quantidadeTotal = 0;
    for (var i = 0; i < itens.length; i++) {
      final item = itens[i];
      final quantidade = item['quantidade'] is num
          ? (item['quantidade'] as num).toInt()
          : null;
      if (quantidade != null) quantidadeTotal += quantidade;
      final tamanho = item['tamanho']?.toString();
      final detalhes = <String>[
        if (item['mistura'] != null) item['mistura'].toString(),
        if (item['acompanhamento'] != null) item['acompanhamento'].toString(),
      ];
      final identificacao = [
        if (quantidade != null) '${quantidade}x',
        tamanho ?? 'tamanho ainda não escolhido',
      ].join(' ');
      final faltam = <String>[
        if (tamanho == null) 'tamanho',
        if (item['mistura'] == null) 'mistura',
        if (item['acompanhamento'] == null) 'acompanhamento',
        if (item['quantidade'] == null) 'quantidade',
      ];
      linhas.add(
        '• $identificacao'
        '${detalhes.isEmpty ? '' : ' — ${detalhes.join(' com ')}'}'
        '${faltam.isEmpty ? '' : ' (falta${faltam.length > 1 ? 'm' : ''} ${faltam.join(' e ')})'}',
      );
    }
    final totalDeclarado = rascunho['quantidadeTotalSolicitada'] is num
        ? (rascunho['quantidadeTotalSolicitada'] as num).toInt()
        : null;
    final total = totalDeclarado ?? quantidadeTotal;
    final prefixo = total > 0
        ? 'Até agora anotei $total ${total == 1 ? 'marmita' : 'marmitas'}:'
        : 'Até agora anotei:';
    return '$prefixo\n${linhas.join('\n')}\n\n'
        'Ainda estou montando o pedido. ${_perguntaProximoDetalhePedido(sessao)}';
  }

  String _perguntaProximoDetalhePedido(Map<String, dynamic>? sessao) {
    final dados = Map<String, dynamic>.from(sessao?['dados'] as Map? ?? {});
    final rascunho = Map<String, dynamic>.from(
      dados['rascunhoPedidoIA'] as Map? ?? const {},
    );
    final itens = (rascunho['itens'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final total = rascunho['quantidadeTotalSolicitada'] is num
        ? (rascunho['quantidadeTotalSolicitada'] as num).toInt()
        : null;
    final cardapio = banco.obterCardapio();
    if (itens.isEmpty) {
      return (total ?? 0) > 1
          ? 'Quais tamanhos você prefere para as $total marmitas?'
          : 'O que você gostaria de pedir?';
    }
    for (var i = 0; i < itens.length; i++) {
      final item = itens[i];
      final umaSo = itens.length == 1;
      final referencia = _referenciaMarmitaIa(itens, i, totalSolicitado: total);
      if (item['tamanho'] == null) {
        return umaSo && (total ?? 0) > 1
            ? 'Quais tamanhos você prefere para as $total marmitas?'
            : umaSo
                ? 'Qual tamanho você prefere para sua marmita?'
                : 'Qual tamanho você prefere para a próxima marmita?';
      }
      if (cardapio['fluxoArrozAtivo'] == true && item['arroz'] == null) {
        return 'Qual arroz você prefere $referencia?';
      }
      if (cardapio['fluxoFeijaoAtivo'] == true && item['feijao'] == null) {
        return 'Qual feijão você prefere $referencia?';
      }
      if (item['mistura'] == null) {
        return 'Qual mistura você prefere $referencia?';
      }
      if (item['acompanhamento'] == null) {
        return 'Qual acompanhamento você prefere $referencia?';
      }
      if (item['quantidade'] == null) {
        return 'Quantas marmitas iguais a essa você gostaria?';
      }
    }
    return 'Quer incluir outra marmita ou podemos finalizar?';
  }

  String _referenciaMarmitaIa(
    List<Map<String, dynamic>> itens,
    int indice, {
    num? totalSolicitado,
  }) {
    final item = itens[indice];
    final tamanho = item['tamanho']?.toString().trim() ?? '';
    if (tamanho.isEmpty) {
      return itens.length == 1 ? 'na sua marmita' : 'na próxima marmita';
    }

    final totalRepresentado = itens.fold<int>(0, (soma, atual) {
      final qtd = atual['quantidade'];
      return soma + (qtd is num && qtd >= 1 ? qtd.toInt() : 1);
    });
    final temMultiplas = totalRepresentado > 1 || (totalSolicitado ?? 0) > 1;
    if (!temMultiplas) return 'na sua marmita';
    final repetida = itens.take(indice).any((anterior) =>
        _normalizar(anterior['tamanho']?.toString() ?? '') ==
        _normalizar(tamanho));
    return repetida
        ? 'para a próxima marmita ${tamanho.toLowerCase()}'
        : 'para sua marmita ${tamanho.toLowerCase()}';
  }

  bool _ehComandoCorrigir(String entrada) => _correspondeIntencao(entrada, [
        'corrigir',
        'quero corrigir',
        'preciso corrigir',
        'alterar resposta',
        'mudar resposta',
        'respondi errado',
        'marquei errado',
        'quero alterar',
        'quero mudar',
      ]);

  Future<void> _pedirConfirmacaoCancelamento(
    MensagemWhatsApp msg,
    Map<String, dynamic> sessao,
  ) async {
    final dados = Map<String, dynamic>.from(sessao['dados'] as Map? ?? {});
    dados['_etapaAntesCancelamento'] = sessao['etapa']?.toString() ?? 'inicio';
    banco.salvarSessao(
      telefone: msg.telefone,
      nome: msg.nome,
      etapa: 'confirmar_cancelamento',
      dados: dados,
    );
    await _enviarBotoes(
      msg.telefone,
      '⚠️ Tem certeza de que deseja cancelar o pedido atual?',
      const [
        {'id': 'cancelar_sim', 'titulo': 'Sim, cancelar'},
        {'id': 'cancelar_nao', 'titulo': 'Continuar pedido'},
      ],
    );
  }

  Future<void> _tratarConfirmarCancelamento(
    MensagemWhatsApp msg,
    Map<String, dynamic> sessao,
    String entrada,
  ) async {
    final dados = Map<String, dynamic>.from(sessao['dados'] as Map? ?? {});
    final confirmou = _ehIntencaoConfirmarCancelamento(entrada);
    final continuou = _ehNegacaoOpcional(entrada) ||
        _correspondeIntencao(entrada, [
          'cancelar_nao',
          'continuar pedido',
          'continuar',
          'nao cancelar',
          'manter pedido',
          'voltar',
          'volta',
          'volte',
        ]);

    if (confirmou) {
      _salvarInicioLimpo(msg.telefone, msg.nome);
      await _enviarBotoes(
        msg.telefone,
        _textoFluxo(
          'sistema',
          'pedidoCancelado',
          _modoIaAtivo
              ? 'Pedido cancelado. 🙂 Quando quiser, posso ajudar com outro pedido.'
              : 'Pedido cancelado. 🙂\nQuando quiser começar novamente, escolha uma opção:',
        ),
        _botoesInicio(),
      );
      return;
    }

    if (continuou) {
      final etapa =
          dados.remove('_etapaAntesCancelamento')?.toString() ?? 'inicio';
      banco.salvarSessao(
        telefone: msg.telefone,
        nome: msg.nome,
        etapa: etapa,
        dados: dados,
      );
      await whatsapp.enviarTexto(
        msg.telefone,
        '👍 Pedido mantido. Continue de onde parou.',
      );
      await _responderAjuda(msg, {'etapa': etapa});
      return;
    }

    await whatsapp.enviarTexto(
      msg.telefone,
      'Você quer cancelar o pedido ou continuar com ele?',
    );
  }

  bool _ehIntencaoConfirmarCancelamento(String entrada) {
    final texto = _normalizarIntencao(entrada);
    if (_ehNegacaoOpcional(texto)) return false;
    return _correspondeIntencao(texto, [
      'cancelar_sim',
      'sim',
      'sim, pode',
      'sim pode',
      'isso',
      'pode',
      'sim cancelar',
      'sim pode cancelar',
      'sim, pode cancelar',
      'confirmar cancelamento',
      'pode cancelar',
      'cancelar',
      'cancela',
      if (!_modoIaAtivo) '0',
    ]);
  }

  String _textoAjudaEtapa(Map<String, dynamic>? sessao) {
    final etapa = sessao?['etapa']?.toString() ?? 'inicio';
    return switch (etapa) {
      'tamanho' => _modoIaAtivo
          ? 'Qual tamanho você prefere?'
          : 'Escolha o tamanho da marmita na lista.',
      'ia_pedido' => _perguntaProximoDetalhePedido(sessao),
      'mistura' => _modoIaAtivo
          ? 'Qual mistura você gostaria?'
          : 'Escolha uma mistura na lista.',
      'acompanhamento' => _modoIaAtivo
          ? 'Qual acompanhamento você gostaria?'
          : 'Escolha um acompanhamento na lista.',
      'quantidade' => _modoIaAtivo
          ? 'Quantas marmitas você gostaria?'
          : 'Digite quantas marmitas iguais você deseja. Ex.: *2*.',
      'adicionar_outro' => _modoIaAtivo
          ? 'Quer mais alguma marmita?'
          : 'Escolha se deseja adicionar outra marmita ou finalizar o pedido.',
      'recebimento' => _modoIaAtivo
          ? 'Você prefere entrega ou retirada?'
          : 'Escolha *Entrega* ou *Retirada*.',
      'endereco' => _modoIaAtivo
          ? 'Qual é o endereço para entrega?'
          : 'Envie rua, número, bairro e complemento ou referência.',
      'cidade_entrega' => _modoIaAtivo
          ? 'Em qual cidade será a entrega?'
          : 'Escolha a cidade da entrega.',
      'pagamento' => _modoIaAtivo
          ? 'Qual forma de pagamento você prefere?'
          : 'Escolha PIX, dinheiro, cartão de crédito ou cartão de débito.',
      'troco' => _modoIaAtivo
          ? 'Vai precisar de troco?'
          : 'Digite *não* ou o valor para o troco. Ex.: *50*.',
      'observacao' => _modoIaAtivo
          ? 'Gostaria de acrescentar alguma observação?'
          : 'Escreva a observação ou digite *não* se não tiver nenhuma.',
      'bebida' => _modoIaAtivo
          ? 'Quer alguma bebida?'
          : 'Escolha uma bebida ou selecione *Sem bebida*.',
      'quantidade_bebida' => _modoIaAtivo
          ? 'Quantas unidades você gostaria?'
          : 'Digite quantas unidades da bebida você deseja.',
      'adicionar_outra_bebida' => _modoIaAtivo
          ? 'Quer mais alguma bebida?'
          : 'Escolha adicionar outra bebida ou finalizar as bebidas.',
      'confirmacao' => _modoIaAtivo
          ? 'Ficou tudo certo?'
          : 'Confira o resumo e escolha confirmar, refazer ou cancelar.',
      'confirmar_cancelamento' => _modoIaAtivo
          ? 'Você confirma que deseja cancelar?'
          : 'Escolha se deseja confirmar o cancelamento ou continuar o pedido.',
      _ => _modoIaAtivo
          ? 'Como posso ajudar?'
          : 'Escolha uma das opções exibidas para começar.',
    };
  }

  Future<void> _responderAjuda(
    MensagemWhatsApp msg,
    Map<String, dynamic>? sessao,
  ) async {
    final orientacao = _textoAjudaEtapa(sessao);
    await whatsapp.enviarTexto(
      msg.telefone,
      _modoIaAtivo
          ? orientacao
          : '❓ *AJUDA*\n$orientacao\n\n'
              'Digite *VOLTAR* para retornar, *CANCELAR* para cancelar ou '
              '*ATENDENTE* para falar com nossa equipe.',
    );
  }

  int? _parseQuantidade(String entrada) {
    final texto = _normalizar(entrada)
        .replaceFirst(
          RegExp(r'^(quero|preciso de|vou querer|sao|seriam|serao)\s+'),
          '',
        )
        .replaceFirst(RegExp(r' marmitas?$'), '');
    final primeiroTermo = texto.split(' ').first;
    final numero = int.tryParse(primeiroTermo);
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
    }[primeiroTermo];
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
        final cardapio = banco.obterCardapio();
        if (cardapio['fluxoFeijaoAtivo'] == true) {
          await _mostrarBase(msg, dados, 'feijao');
        } else if (cardapio['fluxoArrozAtivo'] == true) {
          await _mostrarBase(msg, dados, 'arroz');
        } else {
          await _mostrarTamanhos(msg, dados);
        }
        return;
      case 'feijao':
        if (banco.obterCardapio()['fluxoArrozAtivo'] == true) {
          await _mostrarBase(msg, dados, 'arroz');
        } else {
          await _mostrarTamanhos(msg, dados);
        }
        return;
      case 'arroz':
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
            _modoIaAtivo
                ? 'Quantas unidades dessa marmita você gostaria?'
                : 'Altere a quantidade da última marmita (atual: $quantidade).\nDigite de 1 a ${_intFluxo('quantidade', 'maximo', 20).clamp(1, 50)}.',
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
      case 'bebida':
        if (config['permitirObservacoes'] == true) {
          await _pedirObservacao(msg, dados, alterando: true);
        } else if (dados['pagamento'] == 'dinheiro') {
          await _pedirTroco(msg, dados);
        } else {
          await _mostrarPagamentos(msg, config, dados, permitirPulo: false);
        }
        return;
      case 'quantidade_bebida':
      case 'adicionar_outra_bebida':
        await _mostrarBebidas(msg, dados);
        return;
      case 'confirmacao':
        if (_bebidasAtivas().isNotEmpty) {
          await _mostrarBebidas(msg, dados);
        } else if (config['permitirObservacoes'] == true) {
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
          await _enviarBotoes(
            msg.telefone,
            _textoFluxo(
              'inicio',
              'mensagem',
              _modoIaAtivo ? 'Como posso ajudar?' : 'Escolha uma opção:',
            ),
            _botoesInicio(),
          );
        }
        return;
      case 'inicio':
      default:
        _salvarInicioLimpo(msg.telefone, msg.nome);
        await _enviarBotoes(
          msg.telefone,
          _textoFluxo(
            'inicio',
            'mensagem',
            _modoIaAtivo ? 'Como posso ajudar?' : 'Escolha uma opção:',
          ),
          _botoesInicio(),
        );
    }
  }

  String _saudacaoIa() {
    final hora = agoraLocal().hour;
    final cumprimento = hora >= 5 && hora < 12
        ? 'Bom dia'
        : hora >= 12 && hora < 18
            ? 'Boa tarde'
            : 'Boa noite';
    return '$cumprimento! Seja bem-vindo(a) à *Ao Ponto Marmitaria*! 😊';
  }

  void _registrarDiagnosticoConversa(
    MensagemWhatsApp msg, {
    required String etapaAntes,
    required String etapaDepois,
    required String? tipoIa,
    required String? motivoTransferencia,
    required Map<String, dynamic>? pedidoIa,
    required bool iaFalhou,
  }) {
    final entrada = _normalizar(msg.entrada);
    final categorias = <String>{};
    if (iaFalhou) categorias.add('ia_fallback');
    if (motivoTransferencia != null) categorias.add('transferencia');
    if (RegExp(r'\b(na verdade|corrigindo|troca|trocar|mudei)\b')
        .hasMatch(entrada)) {
      categorias.add('correcao_cliente');
    }
    if (RegExp(r'\b(nao sei|não sei|qualquer um|tanto faz|essa|a mesma)\b')
        .hasMatch(entrada)) {
      categorias.add('ambiguidade');
    }
    if (etapaAntes == etapaDepois &&
        entrada.isNotEmpty &&
        (tipoIa == 'duvida' || tipoIa == 'escolha')) {
      categorias.add('etapa_sem_avanco');
    }
    final itens = pedidoIa?['itens'];
    if (pedidoIa != null &&
        itens is List &&
        itens.isNotEmpty &&
        itens.any((item) =>
            item is Map &&
            (item['tamanho'] == null || item['misturas'] == null))) {
      categorias.add('pedido_incompleto');
    }
    // Conversas normais não geram diagnóstico. Assim, o recurso não cria
    // uma segunda trilha de histórico nem aumenta o banco desnecessariamente.
    if (categorias.isEmpty) return;
    banco.registrarDiagnosticoConversa({
      'etapaAntes': etapaAntes,
      'etapaDepois': etapaDepois,
      'tipoIa': tipoIa,
      'motivoTransferencia': motivoTransferencia,
      'categorias': categorias.toList(),
      'temPedidoIa': pedidoIa != null,
      'entradaTamanho': msg.entrada.length,
      'em': agoraIso(),
    });
  }

  bool get _modoIaAtivo {
    final dados = banco.obterConfiguracao()['dados'];
    return dados is Map && dados['modoAtendimento'] == 'ia';
  }

  Future<void> _enviarBotoes(
    String telefone,
    String texto,
    List<Map<String, String>> botoes,
  ) async {
    if (_modoIaAtivo) {
      await whatsapp.enviarTexto(telefone, texto);
      return;
    }
    await whatsapp.enviarBotoes(telefone, texto, botoes);
  }

  Future<void> _enviarLista(
    String telefone, {
    required String texto,
    required String tituloBotao,
    required List<Map<String, String>> opcoes,
  }) async {
    if (!_modoIaAtivo) {
      await whatsapp.enviarLista(
        telefone,
        texto: texto,
        tituloBotao: tituloBotao,
        opcoes: opcoes,
      );
      return;
    }
    await whatsapp.enviarTexto(telefone, texto);
  }

  Map<String, dynamic> _etapaFluxo(String etapa) {
    final wrapper = banco.obterConfiguracao();
    final config = Map<String, dynamic>.from(wrapper['dados'] as Map? ?? {});
    final fluxo = Map<String, dynamic>.from(config['fluxo'] as Map? ?? {});
    return Map<String, dynamic>.from(fluxo[etapa] as Map? ?? {});
  }

  String _textoFluxo(String etapa, String campo, String fallback) {
    final valor = _etapaFluxo(etapa)[campo]?.toString().trim() ?? '';
    if (valor.isEmpty) return fallback;
    if (_modoIaAtivo) {
      final normalizado = _normalizar(valor);
      final instrucao = RegExp(
            r'\b(?:digite|escreva|selecione|clique|use os botoes|responda|escolha|opcoes?|lista|botoes?)\b',
          ).hasMatch(normalizado) ||
          RegExp(r'(^|\n)\s*(?:[•*-]\s|\d+[.)]\s)').hasMatch(valor) ||
          RegExp(r'\bex(?:emplo)?\s*:', caseSensitive: false).hasMatch(valor);
      if (instrucao) return fallback;
    }
    return valor;
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
        .replaceAll(RegExp(r'[^a-z0-9_:]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _pagamentoNome(String valor) {
    switch (valor) {
      case 'pix':
        return 'PIX';
      case 'dinheiro':
        return 'Dinheiro';
      case 'credito':
        return 'Cartão de crédito';
      case 'debito':
        return 'Cartão de débito';
      default:
        return valor;
    }
  }
}

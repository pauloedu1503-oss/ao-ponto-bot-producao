import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../util/env.dart';

class InterpretacaoAtendimento {
  final String tipo;
  final String texto;
  final Map<String, dynamic> pedido;

  const InterpretacaoAtendimento(this.tipo, this.texto,
      {this.pedido = const {}});
}

/// Interpreta mensagens sem executar operações do pedido.
/// Valores e criação de pedidos continuam sob validação do fluxo do backend.
class GroqAtendimentoService {
  final http.Client _client;
  final String? _apiKey;

  GroqAtendimentoService({http.Client? client, String? apiKey})
      : _client = client ?? http.Client(),
        _apiKey = apiKey;

  bool get configurado =>
      (_apiKey ?? Env.get('GROQ_API_KEY')).trim().isNotEmpty;

  Future<InterpretacaoAtendimento?> interpretar({
    required String mensagem,
    required String etapa,
    required Map<String, dynamic> contexto,
  }) async {
    final chave = (_apiKey ?? Env.get('GROQ_API_KEY')).trim();
    if (chave.isEmpty) return null;

    final modelo = Env.get('GROQ_MODEL', padrao: 'openai/gpt-oss-20b').trim();
    final response = await _client
        .post(
          Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
          headers: {
            'Authorization': 'Bearer $chave',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': modelo,
            'max_completion_tokens': 1536,
            'reasoning_effort': 'low',
            'include_reasoning': false,
            'response_format': {
              'type': 'json_schema',
              'json_schema': {
                'name': 'atendimento_ao_ponto',
                'strict': true,
                'schema': {
                  'type': 'object',
                  'properties': {
                    'tipo': {
                      'type': 'string',
                      'enum': ['pedido', 'duvida', 'escolha'],
                    },
                    'texto': {'type': 'string'},
                    'itens': {
                      'type': 'array',
                      'items': {
                        'type': 'object',
                        'properties': {
                          'indice': {'type': 'integer'},
                          'tamanho': {
                            'type': ['string', 'null']
                          },
                          'quantidade': {
                            'type': ['integer', 'null']
                          },
                          'mistura': {
                            'type': ['string', 'null']
                          },
                          'misturas': {
                            'type': 'array',
                            'items': {'type': 'string'},
                          },
                          'acompanhamento': {
                            'type': ['string', 'null']
                          },
                          'acompanhamentos': {
                            'type': 'array',
                            'items': {'type': 'string'},
                          },
                          'arroz': {
                            'type': ['string', 'null']
                          },
                          'feijao': {
                            'type': ['string', 'null']
                          },
                        },
                        'required': [
                          'indice',
                          'tamanho',
                          'quantidade',
                          'mistura',
                          'misturas',
                          'acompanhamento',
                          'acompanhamentos',
                          'arroz',
                          'feijao',
                        ],
                        'additionalProperties': false,
                      },
                    },
                    'finalizarItens': {'type': 'boolean'},
                  },
                  'required': ['tipo', 'texto', 'itens', 'finalizarItens'],
                  'additionalProperties': false,
                },
              },
            },
            'messages': [
              {
                'role': 'system',
                'content':
                    '''Você é a atendente virtual da Ao Ponto Marmitaria. Converse em português brasileiro, com naturalidade, educação, clareza e respostas curtas. Seu objetivo é entender o que a pessoa quer, responder dúvidas com os dados autorizados abaixo e coletar um pedido com precisão.

PRIORIDADE E ESTADO
1. Siga sempre o estado atual e os dados estruturados fornecidos em etapa, etapaAtual, opcoesDaEtapa e rascunhoPedidoAtual. Esses dados representam o fluxo válido. Não apague nem contradiga informação já registrada.
2. Use somente contextoLoja e opcoesCardapio. Nunca invente pratos, disponibilidade, tamanhos, preços, taxas, cidades, horários, endereço, forma de pagamento, chave Pix ou ações concluídas.
3. O fluxo de arroz e o de feijão só existem se seus indicadores estiverem ativos. Quando desativados, não ofereça, pergunte, extraia nem inclua arroz ou feijão.
4. O backend valida e executa operações. Você apenas classifica a mensagem, extrai dados explícitos e redige respostas; nunca diga que o pedido foi enviado, confirmado ou que um atendente foi chamado, a menos que o estado/contexto confirme isso.
5. Receba a mensagem atual junto com o estado salvo, mas não presuma que recebeu todo o histórico do chat. Quando faltar informação ou houver duas interpretações plausíveis, faça uma pergunta breve e específica.

INTENÇÃO: CARDÁPIO OU DÚVIDA
- Pedir de forma geral o que há para comer significa pedir o cardápio configurado completo. Entenda abreviações, erros simples e formas naturais: “oq tem hj?”, “oe tem de bom hj?”, “oq vc tem?”, “o que tem pra hoje?”, “quais opções tem?”, “me mostra o cardápio”, “cardápio pfv”. Para esse pedido, use tipo duvida e responda apenas “CARDAPIO_CONFIGURADO”; o backend substitui esse marcador pelo cardápio real. Nunca invente uma descrição resumida.
- Não envie o cardápio inteiro quando a pessoa fizer uma pergunta específica: “o cardápio muda todo dia?” pede confirmar que sim; “vocês têm calabresa hoje?” pede responder somente sobre essa opção, conforme o contexto. “O que tem de bom hoje?” e equivalentes pedem o cardápio completo.
- Se a pessoa perguntar sobre preço, taxa, entrega, cidades, horário, ingredientes, Pix, pagamento, retirada ou disponibilidade, responda diretamente com o dado exato do contexto. Se não estiver no contexto, diga que não consegue confirmar e ofereça encaminhar a dúvida a um atendente, sem adivinhar.
- Uma saudação do cliente não é pedido nem dúvida. A saudação inicial, calculada pelo horário local, é responsabilidade do backend. Não repita a saudação nem deduza o horário pelo texto do cliente.

INTENÇÃO: MONTAR O PEDIDO
- Use tipo pedido quando a pessoa quiser pedir, informar ou corrigir qualquer detalhe de uma marmita, adicionar outra ou finalizar as marmitas.
- Extraia somente dados que a pessoa informou claramente na mensagem atual. Atualize o índice correspondente em rascunhoPedidoAtual; não duplique itens já registrados. Se não houver índice indicado e há um item incompleto, atualize-o; se todos estiverem completos e a pessoa iniciou outra marmita, use o próximo índice.
- Para cada combinação, capture tamanho, quantidade, misturas, acompanhamentos e, apenas quando ativos, arroz e feijão. O tamanho escolhido informa quantidadeMisturas e quantidadeAcompanhamentos permitidos/exigidos. Use os arrays misturas e acompanhamentos para preservar todas as escolhas, sem duplicatas e sem exceder as quantidades configuradas. Os campos singulares mistura/acompanhamento são compatibilidade e devem receber a primeira escolha quando houver escolha; os arrays devem conter todas. Se o cliente informou só uma de várias opções exigidas, preserve-a e não invente as demais. Se a quantidade da marmita não foi dita, não a invente, salvo “uma marmita”/“uma pequena”, que indica quantidade 1. Não deduza quantidade por soma, salvo se a pessoa declarar um total e todas as parcelas restantes ficarem inequívocas; nesse caso, confira a aritmética e use os índices corretos.
- Associe cada detalhe à marmita certa. Exemplo: “duas pequenas: a primeira carne e macarrão, a segunda frango e batata” cria duas combinações distintas, ambas de tamanho Pequena e quantidade 1. Exemplo: “duas pequenas de carne com batata” cria uma combinação com quantidade 2. Não misture acompanhamentos ou misturas entre combinações.
- Reconheça variações e erros de digitação somente quando houver uma única opção ativa claramente correspondente. Exemplos: “calabres” ou “pode ser calabre” podem indicar “Calabresa acebolada”; “carne moída também” indica “Carne moída”; “pode se batata” indica “Batata”. Grave sempre o nome canônico do cardápio. Se houver mais de uma opção possível, pergunte qual a pessoa quis dizer.
- Distinga pergunta de escolha. “Vocês não têm calabresa?” ou “calabresa tem?” é uma pergunta de disponibilidade, não escolha de mistura. Responda usando o cardápio. “Calabresa” ou “pode ser calabresa” durante a pergunta sobre mistura é uma escolha.
- Ao perguntar se quer outra marmita, “sim”, “quero”, “vou querer”, “vou quere”, “mais uma” ou equivalente autoriza iniciar a coleta da próxima. Isso não adiciona uma marmita vazia nem confirma novamente a anterior. “Não”, “só isso” ou “finalizar” encerra a inclusão. Uma resposta afirmativa isolada fora de uma etapa que espere confirmação não confirma o pedido inteiro. No resumo, só classifique confirmação quando a mensagem declarar claramente que a pessoa confirma o pedido. “ok”, “isso”, “beleza”, “certo”, “manda” e elogios isolados são ambíguos, não confirmam nem cancelam; peça esclarecimento. Diante de cancelamento, exija intenção de cancelar explicitamente; “sim” ou “isso” isolados nunca cancelam.
- Não transforme dúvida, saudação, “vou querer” sem detalhes ou resposta ambígua em pedido completo. Não repita “item adicionado” se não houve item novo.

COMO CONVERSAR
- Seja acolhedora e objetiva. Faça uma pergunta por vez, somente sobre o próximo dado que falta. Não despeje uma lista de perguntas ou instruções.
- Não mostre listas de opções, botões, números, exemplos de como escrever, nomes internos, etapas, JSON, explicações sobre o funcionamento da IA ou mensagens técnicas. As opções internas servem apenas para reconhecer a resposta.
- Aproveite tudo que a pessoa já disse e não pergunte de novo um campo preenchido. Ao completar uma resposta, avance para o próximo campo realmente ausente. Se a pessoa fizer uma pergunta durante o pedido, responda primeiro e preserve o rascunho.
- Nunca ecoe a mensagem do cliente como resposta. Se não entendeu, peça esclarecimento em linguagem simples. Não acrescente perguntas ou convites genéricos ao fim de respostas que já resolveram a dúvida.
- Endereço, observação e outros dados pessoais são tratados pelo backend em suas etapas próprias. Não solicite nem repita esses dados na resposta da IA.

FORMATO OBRIGATÓRIO
Devolva somente um objeto JSON válido, sem markdown, comentários ou texto antes/depois, com este formato exato:
{"tipo":"pedido|duvida|escolha","texto":"","itens":[{"indice":1,"tamanho":null,"quantidade":null,"mistura":null,"misturas":[],"acompanhamento":null,"acompanhamentos":[],"arroz":null,"feijao":null}],"finalizarItens":false}

- tipo pedido: texto vazio; itens contém apenas os campos explicitamente capturados ou corrigidos. Se ainda não há detalhe de marmita, use itens vazio e deixar o backend conduzir a pergunta seguinte.
- tipo duvida: itens vazio; texto contém somente a resposta ao cliente. Para pedido geral do cardápio, texto deve ser exatamente CARDAPIO_CONFIGURADO.
- tipo escolha: itens vazio; texto deve ser exatamente um valor permitido de opcoesDaEtapa, sem reformular nem criar um valor. Use escolha apenas para uma resposta inequívoca à etapa atual.
- Para qualquer campo de item não informado, use null. Use finalizarItens=true somente quando a pessoa disser claramente que terminou as marmitas (“só isso”, “pode finalizar”, “não quero mais nenhuma”); caso contrário, false.
- Valide mentalmente que o JSON está bem formado, os índices são inteiros positivos, quantidades são inteiros positivos e cada opção existe e está ativa no contexto.'''
              },
              {
                'role': 'user',
                'content': jsonEncode({
                  'etapa': etapa,
                  'contextoLoja': contexto,
                  'mensagemCliente': mensagem,
                }),
              },
            ],
          }),
        )
        .timeout(const Duration(seconds: 8));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpExceptionSeguro(_resumoErroSeguro(response));
    }
    final envelope = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = envelope['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const FormatException('Resposta vazia da Groq.');
    }
    final content = (choices.first as Map)['message'] is Map
        ? ((choices.first as Map)['message'] as Map)['content']?.toString()
        : null;
    if (content == null || content.length > 8000) {
      throw const FormatException('Resposta inválida da Groq.');
    }
    final parsed = jsonDecode(content);
    if (parsed is! Map) throw const FormatException('JSON inválido da Groq.');
    final tipo = parsed['tipo']?.toString();
    final texto = parsed['texto']?.toString().trim() ?? '';
    final itens = parsed['itens'];
    final pedido = <String, dynamic>{
      if (itens is List) 'itens': itens,
      'finalizarItens': parsed['finalizarItens'] == true,
    };
    if (!{'escolha', 'duvida', 'pedido'}.contains(tipo) ||
        (tipo != 'pedido' && texto.isEmpty) ||
        texto.length > 300 ||
        (itens is List && itens.length > 20)) {
      throw const FormatException('Interpretação inválida da Groq.');
    }
    return InterpretacaoAtendimento(tipo!, texto, pedido: pedido);
  }

  void fechar() => _client.close();

  String _resumoErroSeguro(http.Response response) {
    final partes = <String>['Groq HTTP ${response.statusCode}'];
    try {
      final envelope = jsonDecode(response.body);
      final erro = envelope is Map ? envelope['error'] : null;
      if (erro is Map) {
        for (final campo in ['code', 'type', 'param']) {
          final valor = erro[campo]?.toString();
          if (valor != null &&
              valor.isNotEmpty &&
              RegExp(r'^[A-Za-z0-9_.-]{1,80}$').hasMatch(valor)) {
            partes.add('$campo=$valor');
          }
        }
      }
    } catch (_) {
      // Do not log provider response bodies, prompts, or customer text.
    }
    return partes.join(': ');
  }
}

class HttpExceptionSeguro implements Exception {
  final String message;
  const HttpExceptionSeguro(this.message);
  @override
  String toString() => message;
}

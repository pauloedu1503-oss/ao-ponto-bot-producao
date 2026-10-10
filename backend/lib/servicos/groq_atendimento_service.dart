import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../util/env.dart';

class InterpretacaoAtendimento {
  final String tipo;
  final String texto;
  final Map<String, dynamic> pedido;
  final String? motivoHumano;

  const InterpretacaoAtendimento(this.tipo, this.texto,
      {this.pedido = const {}, this.motivoHumano});
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

  Future<String?> transcreverAudio(
    Uint8List bytes, {
    String filename = 'audio.ogg',
  }) async {
    final chave = (_apiKey ?? Env.get('GROQ_API_KEY')).trim();
    if (chave.isEmpty || bytes.isEmpty || bytes.length > 100 * 1024 * 1024) {
      return null;
    }
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('https://api.groq.com/openai/v1/audio/transcriptions'),
    )
      ..headers['Authorization'] = 'Bearer $chave'
      ..fields['model'] = Env.get(
        'GROQ_AUDIO_MODEL',
        padrao: 'whisper-large-v3-turbo',
      )
      ..fields['language'] = 'pt'
      ..fields['response_format'] = 'json'
      ..files
          .add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final response = await request.send().timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final body = await response.stream.bytesToString();
    final json = jsonDecode(body);
    final texto = json is Map ? json['text']?.toString().trim() : null;
    return texto?.isNotEmpty == true ? texto : null;
  }

  Future<String?> interpretarImagem(
    Uint8List bytes, {
    required String mimeType,
  }) async {
    final chave = (_apiKey ?? Env.get('GROQ_API_KEY')).trim();
    if (chave.isEmpty || bytes.isEmpty || bytes.length > 20 * 1024 * 1024) {
      return null;
    }
    final dataUrl = 'data:$mimeType;base64,${base64Encode(bytes)}';
    final response = await _client
        .post(
          Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
          headers: {
            'Authorization': 'Bearer $chave',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': Env.get(
              'GROQ_VISION_MODEL',
              padrao: 'qwen/qwen3.8-27b',
            ),
            'temperature': 0,
            'max_completion_tokens': 800,
            'messages': [
              {
                'role': 'user',
                'content': [
                  {
                    'type': 'text',
                    'text':
                        'Leia esta imagem. Extraia somente o pedido ou a dúvida do cliente em português brasileiro. Se não houver pedido ou texto legível, responda apenas INCONCLUSIVO.',
                  },
                  {
                    'type': 'image_url',
                    'image_url': {'url': dataUrl},
                  },
                ],
              },
            ],
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final envelope = jsonDecode(response.body);
    final choices = envelope is Map ? envelope['choices'] : null;
    final content = choices is List && choices.isNotEmpty
        ? (((choices.first as Map)['message'] as Map?)?['content'])
            ?.toString()
            .trim()
        : null;
    if (content == null || content.isEmpty || content == 'INCONCLUSIVO') {
      return null;
    }
    return content.length <= 2000 ? content : content.substring(0, 2000);
  }

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
                      'enum': ['pedido', 'duvida', 'escolha', 'humano'],
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
                    'motivoHumano': {
                      'type': ['string', 'null'],
                      'enum': [
                        'fora_cardapio',
                        'duvida_nao_respondida',
                        'reclamacao',
                        'reclamacao_grave',
                        'solicitacao_explicita',
                        'midia_nao_processada',
                        null,
                      ],
                    },
                  },
                  'required': [
                    'tipo',
                    'texto',
                    'itens',
                    'finalizarItens',
                    'motivoHumano',
                  ],
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
   Use historicoRecente apenas para entender referências e retomadas. O estado estruturado atual tem prioridade; não repita perguntas já respondidas e não trate uma mudança de assunto como cancelamento do pedido.
2. Use somente contextoLoja e opcoesCardapio. Nunca invente pratos, disponibilidade, tamanhos, preços, taxas, cidades, horários, endereço, forma de pagamento, chave Pix ou ações concluídas.
3. O fluxo de arroz e o de feijão só existem se seus indicadores estiverem ativos. Quando desativados, não ofereça, pergunte, extraia nem inclua arroz ou feijão.
4. O backend valida e executa operações. Você apenas classifica a mensagem, extrai dados explícitos e redige respostas; nunca diga que o pedido foi enviado, confirmado ou que um atendente foi chamado, a menos que o estado/contexto confirme isso.
5. Receba a mensagem atual junto com o estado salvo, mas não presuma que recebeu todo o histórico do chat. Quando faltar informação ou houver duas interpretações plausíveis, faça uma pergunta breve e específica.

INTENÇÃO: ELOGIOS, AGRADECIMENTOS E COMENTÁRIOS POSITIVOS
- Elogios e comentários positivos NÃO são pedidos, confirmações, cancelamentos ou dúvidas. São expressões de satisfação como "tava uma delícia", "gostei muito", "chegou rápido", "meu amigo indicou", "que maravilha", "nota 10", "parabéns pela comida".
- Agradeça cordialmente e de forma breve. Exemplos: "Que bom que você gostou! A Ao Ponto agradece o carinho 😊" ou "Que legal! Agradecemos pela indicação. Estamos à disposição se quiser pedir."
- NUNCA confunda elogio com confirmação de pedido, cancelamento ou novo pedido. Um elogio isolado NÃO altera o estado do pedido em andamento.
- Se a mensagem contiver elogio E uma pergunta ou pedido, responda ao elogio brevemente e continue tratando a pergunta ou pedido normalmente.
- Se houver um pedido em andamento, responda ao elogio e continue de onde parou, sem alterar o rascunho ou a etapa.
- Agradecimentos simples como "obrigado", "obg", "valeu", "obrigado pela ajuda" também devem ser respondidos cordialmente: "Por nada! 😊" ou "Estamos à disposição!".
- Não transforme elogio ou agradecimento em confirmação de pedido. "Obrigado" não confirma pedido.

INTENÇÃO: RECLAMAÇÕES E INSATISFAÇÃO
- Reclamações claras e clientes irritados são encaminhados ao atendimento humano pelo backend. Não tente concluir a reclamação nem prometa compensação.
- Para uma reclamação comum, use tipo humano, motivoHumano reclamacao e um texto breve, empático, dizendo que um atendente vai verificar.
- Para risco à saúde, alergia, intoxicação, ameaça, discriminação ou possível crime, use tipo humano, motivoHumano reclamacao_grave e oriente a pessoa a aguardar o atendente. Não minimize o relato.
- NUNCA confunda reclamação com confirmação ou cancelamento. Preserve os dados do pedido em andamento.
- Se houver reclamação junto com pedido ou pergunta, priorize encaminhar a conversa; não diga que a parte adicional foi resolvida antes do atendente analisar.

INTENÇÃO: INDECISÃO E AJUDA PARA ESCOLHER
- Indecisão NÃO é pedido, confirmação, cancelamento ou dúvida. É quando o cliente não sabe o que pedir, pede ajuda para escolher, ou está em dúvida entre opções.
- Ajude o cliente a escolher de forma cordial e objetiva, usando somente opções ativas do cardápio. Não afirme que algo é popular ou mais vendido sem dados de vendas. Exemplo: "Claro! Estas são algumas opções do cardápio: [liste até 3 opções]. Alguma delas te agrada?"
- NUNCA confunda indecisão com confirmação de pedido, cancelamento ou novo pedido. Uma indecisão isolada NÃO altera o estado do pedido em andamento.
- Se a mensagem contiver indecisão e também trouxer uma escolha concreta ou pedido claro, registre o pedido e pergunte somente o que faltar.
- Se houver um pedido em andamento, responda à indecisão e continue de onde parou, sem alterar o rascunho ou a etapa.
- Não invente opções ou sugestões que não estejam no cardápio. Use apenas informações reais disponíveis.

INTENÇÃO: MÚLTIPLAS INTENÇÕES NA MESMA MENSAGEM
- Mensagens podem conter múltiplas intenções, como "gostei muito! Quero pedir uma marmita" (elogio + pedido) ou "não gostei, mas obrigado pela ajuda" (reclamação + agradecimento).
- Preserve pedidos concretos que venham junto com elogios ou indecisão; não deixe de registrar os dados informados.
- Reclamação junto com outra intenção exige transferência humana; não confirme, cancele nem altere o pedido automaticamente.

INTENÇÃO: CARDÁPIO OU DÚVIDA
- Pedir de forma geral o que há para comer significa pedir o cardápio configurado completo. Entenda abreviações, erros simples e formas naturais: “oq tem hj?”, “oe tem de bom hj?”, “oq vc tem?”, “o que tem pra hoje?”, “quais opções tem?”, “me mostra o cardápio”, “cardápio pfv”. Para esse pedido, use tipo duvida e responda apenas “CARDAPIO_CONFIGURADO”; o backend substitui esse marcador pelo cardápio real. Nunca invente uma descrição resumida.
- Não envie o cardápio inteiro quando a pessoa fizer uma pergunta específica: “o cardápio muda todo dia?” pede confirmar que sim; “vocês têm calabresa hoje?” pede responder somente sobre essa opção, conforme o contexto. “O que tem de bom hoje?” e equivalentes pedem o cardápio completo.
- Se a pessoa perguntar sobre preço, taxa, entrega, cidades, horário, ingredientes, Pix, pagamento, retirada ou disponibilidade, responda diretamente com o dado exato do contexto. Se não estiver no contexto, diga que não consegue confirmar e ofereça encaminhar a dúvida a um atendente, sem adivinhar.
- Uma saudação do cliente não é pedido nem dúvida. A saudação inicial, calculada pelo horário local, é responsabilidade do backend. Não repita a saudação nem deduza o horário pelo texto do cliente.

INTENÇÃO: MONTAR O PEDIDO
- Use tipo pedido quando a pessoa quiser pedir, informar ou corrigir qualquer detalhe de uma marmita, adicionar outra ou finalizar as marmitas.
- Extraia somente dados que a pessoa informou claramente na mensagem atual. Atualize o índice correspondente em rascunhoPedidoAtual; não duplique itens já registrados. Se não houver índice indicado e há um item incompleto, atualize-o; se todos estiverem completos e a pessoa iniciou outra marmita, use o próximo índice.
- Para cada combinação, capture tamanho, quantidade, misturas, acompanhamentos e, apenas quando ativos, arroz e feijão. O tamanho escolhido informa quantidadeMisturas e quantidadeAcompanhamentos permitidos/exigidos. Use os arrays misturas e acompanhamentos para preservar todas as escolhas, sem duplicatas e sem exceder as quantidades configuradas. Os campos singulares mistura/acompanhamento são compatibilidade e devem receber a primeira escolha quando houver escolha; os arrays devem conter todas. Se o cliente informou só uma de várias opções exigidas, preserve-a e não invente as demais. Se a quantidade da marmita não foi dita, não a invente, salvo “uma marmita”/“uma pequena”, que indica quantidade 1. Não deduza quantidade por soma, salvo se a pessoa declarar um total e todas as parcelas restantes ficarem inequívocas; nesse caso, confira a aritmética e use os índices corretos.
- A quantidade configurada é o limite/possibilidade do tamanho, não uma autorização para repetir a pergunta sem necessidade. Se o cliente disser “só uma mistura”, “uma mistura só”, “apenas uma” ou equivalente, registre uma escolha e avance; não peça uma segunda mistura. A mesma regra vale para acompanhamento. Se o cliente informar todas as escolhas que deseja, não pergunte novamente nenhum desses campos.
- Se a primeira mensagem já for um pedido completo, extraia todos os dados nela: quantidade de marmitas, tamanho, mistura(s) e acompanhamento(s), mesmo que estejam escritos em linguagem natural, separados por vírgulas ou em frases longas. Não pergunte novamente quantas marmitas são nem repita campos já informados. Valide cada escolha contra opcoesCardapio; se faltar apenas algum detalhe obrigatório, pergunte somente esse detalhe.
- Se uma opção solicitada não existir em opcoesCardapio, não invente uma alternativa como se fosse a mesma. Use tipo humano, motivoHumano fora_cardapio e uma mensagem curta informando que um atendente vai verificar.
- Se a dúvida não puder ser respondida com contextoLoja, opcoesCardapio ou estado atual, use tipo humano, motivoHumano duvida_nao_respondida e não tente adivinhar.
- Quando uma mensagem trouxer várias marmitas completas, crie um item para cada combinação e mantenha as escolhas associadas à marmita correta. Quando trouxer uma quantidade seguida de uma única combinação, use essa quantidade no item, sem criar linhas duplicadas.
- Associe cada detalhe à marmita certa. Exemplo: “duas pequenas: a primeira carne e macarrão, a segunda frango e batata” cria duas combinações distintas, ambas de tamanho Pequena e quantidade 1. Exemplo: “duas pequenas de carne com batata” cria uma combinação com quantidade 2. Não misture acompanhamentos ou misturas entre combinações.
- Entenda também a forma natural agrupada: “2 pequenas com pernil, uma com macarrão, outra com farofa, e 2 médias, uma com hambúrguer e farofa, outra com linguiça e macarrão”. Isso representa quatro marmitas individuais: duas Pequenas e duas Médias. “uma” e “outra” dividem o grupo anterior; cada mistura e acompanhamento devem ficar somente na marmita da mesma frase. Nunca transforme todas as escolhas do grupo na mesma combinação e nunca responda perguntando novamente a primeira mistura se ela já foi informada.
- Reconheça variações e erros de digitação somente quando houver uma única opção ativa claramente correspondente. Exemplos: “calabres” ou “pode ser calabre” podem indicar “Calabresa acebolada”; “carne moída também” indica “Carne moída”; “pode se batata” indica “Batata”. Grave sempre o nome canônico do cardápio. Se houver mais de uma opção possível, pergunte qual a pessoa quis dizer.
- Interprete a intenção pelo conjunto da frase, não por palavras isoladas. Aceite abreviações, ausência de acentos, letras trocadas, plural, singular, “pra”, “pro”, “uma”, “outra”, “a outra”, “cada”, “com”, vírgulas e frases sem pontuação. Corrija mentalmente erros leves quando houver uma única opção do cardápio claramente compatível e devolva o nome canônico.
- Se uma palavra de escolha aparecer no campo errado da conversa, corrija pelo cardápio e pelo contexto: mistura é proteína/prato principal; acompanhamento é guarnição. Por exemplo, se “macarrão” vier descrito como mistura mas só existir em acompanhamentos, registre-o como acompanhamento; se “pernil” vier como acompanhamento mas só existir em misturas, registre-o como mistura. Não peça confirmação quando essa validação for única.
- Quando a mensagem já contiver tamanho, mistura, acompanhamento e quantidade, trate-a como pedido completo mesmo que a ordem esteja invertida, com erros ou em linguagem informal. Pergunte somente o campo realmente ausente.
- Distinga pergunta de escolha. “Vocês não têm calabresa?” ou “calabresa tem?” é uma pergunta de disponibilidade, não escolha de mistura. Responda usando o cardápio. “Calabresa” ou “pode ser calabresa” durante a pergunta sobre mistura é uma escolha.
- Ao perguntar se quer outra marmita, “sim”, “quero”, “vou querer”, “vou quere”, “mais uma” ou equivalente autoriza iniciar a coleta da próxima. Isso não adiciona uma marmita vazia nem confirma novamente a anterior. “Não”, “só isso” ou “finalizar” encerra a inclusão. Uma resposta afirmativa isolada fora de uma etapa que espere confirmação não confirma o pedido inteiro. No resumo, só classifique confirmação quando a mensagem declarar claramente que a pessoa confirma o pedido. “ok”, “isso”, “beleza”, “certo”, “manda” e elogios isolados são ambíguos, não confirmam nem cancelam; peça esclarecimento. EXCEÇÃO: depois de perguntar explicitamente se a pessoa confirma o cancelamento, “sim”, “isso”, “pode”, “sim, pode” e equivalentes confirmam o cancelamento; não faça a mesma pergunta novamente.
- Não transforme dúvida, saudação, “vou querer” sem detalhes ou resposta ambígua em pedido completo. Não repita “item adicionado” se não houve item novo.
- TRATE CONTRADIÇÕES COM SEGURANÇA: se a mensagem disser duas quantidades, tamanhos, misturas, acompanhamentos ou intenções incompatíveis (por exemplo, “uma marmita” e depois “duas”, ou “cancela” e “pode confirmar”), não escolha uma delas e não altere o pedido. Peça uma confirmação curta sobre qual informação vale.
- TRATE AMBIGUIDADES SEM CHUTE: palavras como “carne”, “frango”, “arroz”, “a mesma”, “essa” ou “mais uma” só devem ser associadas quando houver uma única opção ou referência clara no estado atual. Se houver mais de uma possibilidade, peça o detalhe mínimo necessário e preserve o rascunho.
- CORREÇÕES TÊM PRIORIDADE APENAS QUANDO EXPLÍCITAS: “na verdade”, “troca”, “corrigindo” e equivalentes podem substituir um dado já salvo somente quando identificarem claramente o campo e o novo valor. Caso contrário, trate como nova informação pendente, sem sobrescrever o pedido.

COMO CONVERSAR
- Seja acolhedora e objetiva. No início de um pedido, descubra primeiro quantas marmitas serão. Quando for apenas uma, peça tamanho, mistura(s) e acompanhamento na mesma pergunta e aceite que o cliente responda tudo de uma vez. Não faça uma sequência de perguntas separadas para esses três dados. Se a quantidade for maior que uma, associe os detalhes a cada marmita e aceite respostas completas para várias delas na mesma mensagem.
- Não mostre listas de opções, botões, índices, numeração de marmitas, expressões como “marmita 1” ou “1 de 2”, exemplos de como escrever, nomes internos, etapas, JSON, explicações sobre o funcionamento da IA ou mensagens técnicas. As opções internas servem apenas para reconhecer a resposta.
- Aproveite tudo que a pessoa já disse e não pergunte de novo um campo preenchido. Ao completar uma resposta, avance para o próximo campo realmente ausente. Se a pessoa fizer uma pergunta durante o pedido, responda primeiro e preserve o rascunho.
- Nunca ecoe a mensagem do cliente como resposta. Se não entendeu, peça esclarecimento em linguagem simples. Não acrescente perguntas ou convites genéricos ao fim de respostas que já resolveram a dúvida.
- Endereço, observação e outros dados pessoais são tratados pelo backend em suas etapas próprias. Não solicite nem repita esses dados na resposta da IA.

FORMATO OBRIGATÓRIO
Devolva somente um objeto JSON válido, sem markdown, comentários ou texto antes/depois, com este formato exato:
{"tipo":"pedido|duvida|escolha|humano","texto":"","itens":[{"indice":1,"tamanho":null,"quantidade":null,"mistura":null,"misturas":[],"acompanhamento":null,"acompanhamentos":[],"arroz":null,"feijao":null}],"finalizarItens":false,"motivoHumano":null}

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
    final motivoHumano = parsed['motivoHumano']?.toString();
    if (!{'escolha', 'duvida', 'pedido', 'humano'}.contains(tipo) ||
        (tipo != 'pedido' && texto.isEmpty) ||
        (tipo == 'humano' &&
            !{
              'fora_cardapio',
              'duvida_nao_respondida',
              'reclamacao',
              'reclamacao_grave',
              'solicitacao_explicita',
              'midia_nao_processada',
            }.contains(motivoHumano)) ||
        texto.length > 300 ||
        (itens is List && itens.length > 20)) {
      throw const FormatException('Interpretação inválida da Groq.');
    }
    return InterpretacaoAtendimento(tipo!, texto,
        pedido: pedido, motivoHumano: motivoHumano);
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

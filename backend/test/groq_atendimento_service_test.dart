import 'dart:convert';

import 'package:ao_ponto_backend/servicos/groq_atendimento_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late GroqAtendimentoService service;

  setUp(() {
    service = GroqAtendimentoService(
      apiKey: 'chave-de-teste',
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], 'openai/gpt-oss-20b');
        expect(body.containsKey('reasoning_format'), isFalse);
        expect(body['max_completion_tokens'], 1536);
        expect(body['reasoning_effort'], 'low');
        expect(body['include_reasoning'], isFalse);
        expect(body['response_format'], {
          'type': 'json_schema',
          'json_schema': {
            'name': 'atendimento_ao_ponto',
            'strict': true,
            'schema': {
              'type': 'object',
              'properties': {
                'tipo': {
                  'type': 'string',
                  'enum': ['pedido', 'duvida', 'escolha']
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
                        'items': {'type': 'string'}
                      },
                      'acompanhamento': {
                        'type': ['string', 'null']
                      },
                      'acompanhamentos': {
                        'type': 'array',
                        'items': {'type': 'string'}
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
        });
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'tipo': 'duvida',
                    'texto': 'Olá.',
                    'itens': [],
                    'finalizarItens': false,
                  })
                }
              }
            ]
          }),
          200,
        );
      }),
    );
  });

  tearDown(() {
    service.fechar();
  });

  test('uses GPT-OSS strict schema output parameters', () async {
    final result = await service.interpretar(
      mensagem: 'Oi',
      etapa: 'inicio',
      contexto: const {},
    );

    expect(result?.tipo, 'duvida');
    expect(result?.texto, 'Olá.');
  });

  test('reports safe Groq error metadata without logging request text',
      () async {
    service.fechar();
    service = GroqAtendimentoService(
      apiKey: 'chave-de-teste',
      client: MockClient((_) async => http.Response(
            jsonEncode({
              'error': {
                'type': 'invalid_request_error',
                'code': 'unsupported_value',
                'param': 'response_format',
                'message': 'private customer message and API key gsk_secret',
              }
            }),
            400,
          )),
    );

    try {
      await service.interpretar(
        mensagem: 'private customer message',
        etapa: 'inicio',
        contexto: const {},
      );
      fail('Esperava erro HTTP da Groq.');
    } on HttpExceptionSeguro catch (error) {
      expect(error.message, contains('Groq HTTP 400'));
      expect(error.message, contains('type=invalid_request_error'));
      expect(error.message, contains('code=unsupported_value'));
      expect(error.message, contains('param=response_format'));
      expect(error.message, isNot(contains('private customer message')));
      expect(error.message, isNot(contains('gsk_secret')));
    }
  });
}

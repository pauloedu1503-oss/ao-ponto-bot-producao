import 'dart:convert';
import 'package:shelf/shelf.dart';

Response jsonResponse(
  Object? body, {
  int statusCode = 200,
  Map<String, String>? headers,
}) {
  if (statusCode >= 400 && body is Map) {
    body = {
      ...body,
      'codigo': body['codigo'] ?? 'HTTP_$statusCode',
      'detalhes': body['detalhes']
    };
  }
  return Response(
    statusCode,
    body: jsonEncode(body),
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      ...?headers,
    },
  );
}

Future<Map<String, dynamic>> lerJson(Request request) async {
  final body = await lerCorpoLimitado(request);
  if (body.trim().isEmpty) return <String, dynamic>{};
  final value = jsonDecode(body);
  if (value is! Map<String, dynamic>) {
    throw const FormatException('JSON inválido.');
  }
  return value;
}

Future<String> lerCorpoLimitado(Request request) async {
  final bytes = <int>[];
  await for (final parte
      in request.read().timeout(const Duration(seconds: 10))) {
    if (bytes.length + parte.length > 1024 * 1024)
      throw const FormatException('Corpo excede 1 MB.');
    bytes.addAll(parte);
  }
  return utf8.decode(bytes);
}

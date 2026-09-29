import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiException implements Exception {
  final String mensagem;
  final int? status;
  const ApiException(this.mensagem, [this.status]);
  @override
  String toString() => mensagem;
}

class ApiService {
  String baseUrl;
  String? token;
  final http.Client _client;

  ApiService({required this.baseUrl, this.token, http.Client? client})
      : _client = client ?? http.Client();

  void fechar() => _client.close();

  Uri _uri(String path, [Map<String, String>? query]) {
    var base = baseUrl.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    final uri = Uri.tryParse(base);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const ApiException('Informe um servidor HTTP ou HTTPS válido.');
    }
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        if (token != null && token!.isNotEmpty)
          'authorization': 'Bearer $token',
      };

  Future<Map<String, dynamic>> login(String senha) async {
    final r = await _client
        .post(
          _uri('/api/auth/login'),
          headers: _headers,
          body: jsonEncode({'senha': senha}),
        )
        .timeout(const Duration(seconds: 8));
    return _map(r);
  }

  Future<void> logout() async {
    try {
      await _client
          .post(_uri('/api/auth/logout'), headers: _headers)
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  Future<Map<String, dynamic>> health() async => _map(
      await _client.get(_uri('/health')).timeout(const Duration(seconds: 5)));
  Future<Map<String, dynamic>> appVersao() async => _map(await _client
      .get(_uri('/api/app-versao'))
      .timeout(const Duration(seconds: 5)));
  Future<Map<String, dynamic>> bootstrap() async => _map(await _client
      .get(_uri('/api/bootstrap'), headers: _headers)
      .timeout(const Duration(seconds: 10)));
  Future<Map<String, dynamic>> dashboard() async => _map(await _client
      .get(_uri('/api/dashboard'), headers: _headers)
      .timeout(const Duration(seconds: 8)));
  Future<Map<String, dynamic>> configuracao() async => _map(await _client
      .get(_uri('/api/config'), headers: _headers)
      .timeout(const Duration(seconds: 8)));
  Future<Map<String, dynamic>> cardapio() async => _map(await _client
      .get(_uri('/api/cardapio'), headers: _headers)
      .timeout(const Duration(seconds: 8)));

  Future<List<dynamic>> pedidos({String status = 'todos'}) async {
    return _list(await _client
        .get(_uri('/api/pedidos', {'status': status, 'limite': '200'}),
            headers: _headers)
        .timeout(const Duration(seconds: 10)));
  }

  Future<Map<String, dynamic>> salvarConfiguracao(
      Map<String, dynamic> wrapper) async {
    return _map(await _client
        .put(
          _uri('/api/config'),
          headers: _headers,
          body: jsonEncode(wrapper),
        )
        .timeout(const Duration(seconds: 10)));
  }

  Future<Map<String, dynamic>> salvarCardapio(
      Map<String, dynamic> cardapio) async {
    return _map(await _client
        .put(
          _uri('/api/cardapio'),
          headers: _headers,
          body: jsonEncode(cardapio),
        )
        .timeout(const Duration(seconds: 10)));
  }

  Future<Map<String, dynamic>> statusPedido(int id, String status, int versao,
      {String? motivoCancelamento}) async {
    return _map(await _client
        .put(
          _uri('/api/pedidos/$id/status'),
          headers: _headers,
          body: jsonEncode({
            'status': status,
            'versao': versao,
            if (motivoCancelamento != null)
              'motivoCancelamento': motivoCancelamento,
          }),
        )
        .timeout(const Duration(seconds: 10)));
  }

  Future<List<dynamic>> humanos() async => _list(await _client
      .get(_uri('/api/humanos'), headers: _headers)
      .timeout(const Duration(seconds: 8)));

  Future<void> modoHumano(String telefone, bool ativo) async {
    final encoded = Uri.encodeComponent(telefone);
    _map(await _client
        .put(
          _uri('/api/humanos/$encoded'),
          headers: _headers,
          body: jsonEncode({'ativo': ativo}),
        )
        .timeout(const Duration(seconds: 8)));
  }

  Future<void> pararAlertaHumano(String telefone) async {
    final encoded = Uri.encodeComponent(telefone);
    _map(await _client
        .post(_uri('/api/humanos/$encoded/parar-alerta'), headers: _headers)
        .timeout(const Duration(seconds: 8)));
  }

  Future<List<dynamic>> logs() async => _list(await _client
      .get(_uri('/api/logs', {'limite': '100'}), headers: _headers)
      .timeout(const Duration(seconds: 8)));

  Future<List<dynamic>> enviosComFalha() async => _list(await _client
      .get(_uri('/api/envios'), headers: _headers)
      .timeout(const Duration(seconds: 8)));

  Future<void> resolverEnvio(int id, String acao) async {
    _map(await _client
        .post(_uri('/api/envios/$id/resolver'),
            headers: _headers, body: jsonEncode({'acao': acao}))
        .timeout(const Duration(seconds: 8)));
  }

  Future<Map<String, dynamic>> backup() async => _map(await _client
      .post(_uri('/api/backup'), headers: _headers)
      .timeout(const Duration(seconds: 15)));

  Future<void> registrarPush(String pushToken) async {
    _map(await _client
        .post(
          _uri('/api/push/token'),
          headers: _headers,
          body: jsonEncode({'token': pushToken}),
        )
        .timeout(const Duration(seconds: 10)));
  }

  Map<String, dynamic> _map(http.Response r) {
    final body = _decode(utf8.decode(r.bodyBytes));
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException(
        body is Map
            ? (body['erro']?.toString() ?? 'Erro ${r.statusCode}')
            : 'Erro ${r.statusCode}',
        r.statusCode,
      );
    }
    if (body is! Map) {
      throw const ApiException('Resposta inválida do servidor.');
    }
    return Map<String, dynamic>.from(body);
  }

  List<dynamic> _list(http.Response r) {
    final body = _decode(utf8.decode(r.bodyBytes));
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException(
        body is Map
            ? (body['erro']?.toString() ?? 'Erro ${r.statusCode}')
            : 'Erro ${r.statusCode}',
        r.statusCode,
      );
    }
    if (body is! List) {
      throw const ApiException('Resposta inválida do servidor.');
    }
    return body;
  }

  dynamic _decode(String value) {
    if (value.trim().isEmpty) return null;
    try {
      return jsonDecode(value);
    } catch (_) {
      throw const ApiException('O servidor retornou uma resposta inválida.');
    }
  }
}

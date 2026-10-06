import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';
import 'atualizacao_service.dart';
import 'notificacao_service.dart';

Map<String, dynamic> copiaMapa(Map original) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(original)) as Map);

class AppController extends ChangeNotifier {
  static const String servidorProducao = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://ao-ponto-bot-backend.de.deplexo.com',
  );

  ApiService api = ApiService(baseUrl: servidorProducao);

  bool carregando = true;
  bool autenticado = false;
  String? erroGlobal;
  Map<String, dynamic> dashboard = {};
  Map<String, dynamic> configuracao = {
    'versao': 0,
    'dados': <String, dynamic>{}
  };
  Map<String, dynamic> cardapio = {
    'versao': 0,
    'tamanhos': [],
    'misturas': [],
    'acompanhamentos': [],
    'bebidas': [],
    'fluxoArrozAtivo': false,
    'fluxoFeijaoAtivo': false,
    'arrozes': [],
    'feijoes': []
  };
  List<Map<String, dynamic>> pedidos = [];
  List<Map<String, dynamic>> humanos = [];
  List<Map<String, dynamic>> conversasAtivas = [];
  List<Map<String, dynamic>> logs = [];
  List<Map<String, dynamic>> enviosComFalha = [];
  Map<String, dynamic>? atualizacaoDisponivel;
  bool baixandoAtualizacao = false;

  Timer? _timer;
  StreamSubscription<String>? _pushSubscription;
  int _ultimoPedidoId = 0;
  bool _atualizando = false;
  bool salvandoConfig = false;
  bool salvandoCardapio = false;
  bool _descartado = false;
  int _geracao = 0;
  int _revisaoLocal = 0;
  final Set<int> _pedidosSalvando = {};

  @override
  void notifyListeners() {
    if (!_descartado) super.notifyListeners();
  }

  VoidCallback? onNovoPedido;

  Future<void> iniciar() async {
    carregando = true;
    erroGlobal = null;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 4));
      final token = prefs.getString('token');
      api = ApiService(baseUrl: servidorProducao, token: token);

      if (token != null && token.isNotEmpty) {
        try {
          await carregarTudo().timeout(const Duration(seconds: 12));
          autenticado = true;
          _iniciarPolling();
          unawaited(_registrarNotificacoes());
          unawaited(verificarAtualizacao());
        } catch (e) {
          // Token antigo, backend indisponível ou sessão incompatível nunca pode
          // impedir a abertura do app. Voltamos ao login e removemos só o token.
          autenticado = false;
          erroGlobal = _mensagemErro(e);
          if (e is ApiException && e.status == 401) {
            api.token = null;
            try {
              await prefs.remove('token').timeout(const Duration(seconds: 2));
            } catch (_) {}
          }
        }
      }
    } on TimeoutException {
      autenticado = false;
      api = ApiService(baseUrl: servidorProducao);
      erroGlobal =
          'A sessão salva demorou para carregar. O painel foi aberto em modo de login.';
    } catch (_) {
      autenticado = false;
      api = ApiService(baseUrl: servidorProducao);
      erroGlobal =
          'Não foi possível restaurar a sessão anterior. Entre novamente normalmente.';
    } finally {
      carregando = false;
      notifyListeners();
    }
  }

  Future<void> limparSessaoLocal() async {
    _geracao++;
    _timer?.cancel();
    api.fechar();
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 4));
      await prefs.remove('token');
    } catch (_) {}
    api = ApiService(baseUrl: servidorProducao);
    autenticado = false;
    erroGlobal = null;
    notifyListeners();
  }

  Future<void> login(String senha) async {
    // O carregamento inicial do app usa `carregando`. Durante o login, a própria
    // LoginPage mostra o progresso no botão. Manter `carregando = true` aqui
    // escondia a tela inteira e podia deixar apenas um spinner caso uma requisição
    // de rede demorasse ou falhasse.
    erroGlobal = null;
    try {
      _geracao++;
      api.fechar();
      api = ApiService(baseUrl: servidorProducao);
      await api.health();
      final result = await api.login(senha);
      api.token = result['token']?.toString();
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 4));
      await prefs.setString('token', api.token!);
      await carregarTudo();
      autenticado = true;
      _iniciarPolling();
      unawaited(_registrarNotificacoes());
      unawaited(verificarAtualizacao());
    } catch (e) {
      erroGlobal = _mensagemErro(e);
      autenticado = false;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> verificarAtualizacao() async {
    try {
      final instalada = await AtualizacaoService.buildInstalado();
      if (instalada <= 0) return;
      final remota = await api.appVersao();
      final build = (remota['build'] as num?)?.toInt() ?? 0;
      atualizacaoDisponivel = build > instalada ? remota : null;
      notifyListeners();
    } catch (_) {
      // Falha na consulta de versão nunca interfere no funcionamento do painel.
    }
  }

  Future<void> instalarAtualizacao() async {
    if (baixandoAtualizacao || atualizacaoDisponivel == null) return;
    baixandoAtualizacao = true;
    notifyListeners();
    try {
      await AtualizacaoService.instalar(
          atualizacaoDisponivel!['downloadUrl']?.toString() ?? '');
    } finally {
      baixandoAtualizacao = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    _geracao++;
    _timer?.cancel();
    await api.logout();
    final prefs = await SharedPreferences.getInstance()
        .timeout(const Duration(seconds: 4));
    await prefs.remove('token');
    api.token = null;
    autenticado = false;
    notifyListeners();
  }

  Future<void> trocarServidor(String url) async {
    final normalized = url.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const ApiException('Endereço de servidor inválido.');
    }
    await logout(); // Revoga no servidor antigo antes de alterar a URL.
    api.fechar();
    api = ApiService(baseUrl: normalized);
    final prefs = await SharedPreferences.getInstance()
        .timeout(const Duration(seconds: 4));
    await prefs.setString('server_url', normalized);
    notifyListeners();
  }

  Future<void> carregarTudo() async {
    final geracao = _geracao;
    final revisao = _revisaoLocal;
    final data = await api.bootstrap();
    if (geracao != _geracao || revisao != _revisaoLocal || _descartado) return;
    dashboard = Map<String, dynamic>.from(data['dashboard'] as Map? ?? {});
    configuracao =
        Map<String, dynamic>.from(data['configuracao'] as Map? ?? {});
    cardapio = Map<String, dynamic>.from(data['cardapio'] as Map? ?? {});
    pedidos = _listaMap(data['pedidos']);
    humanos = _listaMap(data['humanos']);
    _ultimoPedidoId = (dashboard['ultimoPedidoId'] as num?)?.toInt() ?? 0;
    notifyListeners();
  }

  Future<void> atualizarSilencioso() async {
    if (_atualizando || !autenticado) return;
    _atualizando = true;
    final geracao = _geracao;
    final revisao = _revisaoLocal;
    final atualApi = api;
    try {
      final resultados = await Future.wait(
          [atualApi.dashboard(), atualApi.pedidos(), atualApi.humanos()]);
      if (geracao != _geracao || revisao != _revisaoLocal || _descartado) {
        return;
      }
      final novoDashboard = Map<String, dynamic>.from(resultados[0] as Map);
      final novoId = (novoDashboard['ultimoPedidoId'] as num?)?.toInt() ?? 0;
      final houveNovo = novoId > _ultimoPedidoId;
      dashboard = novoDashboard;
      pedidos = _listaMap(resultados[1]);
      humanos = _listaMap(resultados[2]);
      _ultimoPedidoId = novoId;
      erroGlobal = null;
      if (houveNovo) onNovoPedido?.call();
      notifyListeners();
    } on ApiException catch (e) {
      if (geracao != _geracao || _descartado) return;
      if (e.status == 401) {
        await logout();
      } else {
        erroGlobal = e.mensagem;
        notifyListeners();
      }
    } catch (e) {
      if (geracao != _geracao || _descartado) return;
      erroGlobal =
          'Não foi possível atualizar os pedidos. Os dados exibidos podem estar desatualizados.';
      notifyListeners();
    } finally {
      _atualizando = false;
    }
  }

  Future<void> recarregarCardapioEConfig() async {
    cardapio = await api.cardapio();
    configuracao = await api.configuracao();
    notifyListeners();
  }

  Future<void> salvarConfigDados(Map<String, dynamic> dados,
      {int? versaoEsperada}) async {
    if (salvandoConfig) {
      throw const ApiException('Aguarde a alteração em andamento.');
    }
    salvandoConfig = true;
    _revisaoLocal++;
    try {
      configuracao = await api.salvarConfiguracao({
        'versao': versaoEsperada ?? configuracao['versao'],
        'dados': dados,
      });
      notifyListeners();
      unawaited(atualizarSilencioso());
    } on ApiException catch (e) {
      if (e.status == 409) await recarregarCardapioEConfig();
      rethrow;
    } finally {
      salvandoConfig = false;
      notifyListeners();
    }
  }

  Future<void> definirEstadoBot(String estado) async {
    final dados = copiaMapa(configuracao['dados'] as Map);
    dados['estadoBot'] = estado;
    await salvarConfigDados(dados);
  }

  Future<void> definirBotAtivo(bool ativo) async {
    final dados = copiaMapa(configuracao['dados'] as Map);
    dados['botAtivo'] = ativo;
    await salvarConfigDados(dados);
  }

  Future<void> salvarCardapio(Map<String, dynamic> novo) async {
    if (salvandoCardapio) {
      throw const ApiException('Aguarde a alteração do cardápio.');
    }
    salvandoCardapio = true;
    _revisaoLocal++;
    try {
      cardapio = await api.salvarCardapio(novo);
      notifyListeners();
    } on ApiException catch (e) {
      if (e.status == 409) cardapio = await api.cardapio();
      notifyListeners();
      rethrow;
    } finally {
      salvandoCardapio = false;
      notifyListeners();
    }
  }

  Future<void> alterarStatusPedido(Map<String, dynamic> pedido, String status,
      {String? motivoCancelamento}) async {
    final id = (pedido['id'] as num).toInt();
    if (!_pedidosSalvando.add(id)) return;
    _revisaoLocal++;
    try {
      final atualizado = await api.statusPedido(
        (pedido['id'] as num).toInt(),
        status,
        (pedido['versao'] as num).toInt(),
        motivoCancelamento: motivoCancelamento,
      );
      if (status == 'confirmado' || status == 'cancelado') {
        await NotificacaoService.pararAlerta();
      }
      final index = pedidos.indexWhere((p) => p['id'] == atualizado['id']);
      if (index >= 0) pedidos[index] = atualizado;
      notifyListeners();
      unawaited(atualizarSilencioso());
    } on ApiException catch (e) {
      if (e.status == 409) {
        pedidos = _listaMap(await api.pedidos());
        dashboard = await api.dashboard();
        notifyListeners();
      }
      rethrow;
    } finally {
      _pedidosSalvando.remove(id);
    }
  }

  Future<void> retomarBot(String telefone) async {
    await api.modoHumano(telefone, false);
    humanos = _listaMap(await api.humanos());
    notifyListeners();
  }

  Future<void> carregarConversasAtivas() async {
    conversasAtivas = _listaMap(await api.conversasAtivas());
    notifyListeners();
  }

  Future<void> pararBotNaConversa(String telefone) async {
    await api.pararBotNaConversa(telefone);
    await Future.wait([carregarConversasAtivas(), _recarregarHumanos()]);
  }

  Future<void> _recarregarHumanos() async {
    humanos = _listaMap(await api.humanos());
    notifyListeners();
  }

  Future<void> pararAlertaHumano(String telefone) async {
    await api.pararAlertaHumano(telefone);
    await NotificacaoService.pararAlerta();
    humanos = _listaMap(await api.humanos());
    notifyListeners();
  }

  Future<String> gerarBackup() async {
    final result = await api.backup();
    return result['caminho']?.toString() ?? 'Backup gerado.';
  }

  Future<void> carregarLogs() async {
    logs = _listaMap(await api.logs());
    notifyListeners();
  }

  Future<void> carregarEnvios() async {
    enviosComFalha = _listaMap(await api.enviosComFalha());
    notifyListeners();
  }

  Future<void> resolverEnvio(int id, String acao) async {
    await api.resolverEnvio(id, acao);
    await carregarEnvios();
    dashboard = await api.dashboard();
    notifyListeners();
  }

  void _iniciarPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(
        const Duration(seconds: 6), (_) => atualizarSilencioso());
  }

  Future<void> _registrarNotificacoes() async {
    try {
      final token = await NotificacaoService.obterToken();
      if (token != null && token.isNotEmpty && autenticado) {
        await api.registrarPush(token);
      }
      await _pushSubscription?.cancel();
      _pushSubscription = NotificacaoService.tokens.listen((novoToken) {
        if (autenticado) unawaited(api.registrarPush(novoToken));
      });
    } catch (_) {
      // A notificação não pode impedir o uso normal do painel.
    }
  }

  List<Map<String, dynamic>> _listaMap(dynamic value) {
    if (value is! List) return [];
    return value.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  String _mensagemErro(Object e) {
    if (e is ApiException) return e.mensagem;
    if (e is TimeoutException) {
      return 'O servidor demorou para responder. Confirme se o backend está aberto e tente novamente.';
    }
    return 'Não foi possível conectar ao servidor. Confirme o endereço e se o backend está aberto.';
  }

  @override
  void dispose() {
    _descartado = true;
    _geracao++;
    _timer?.cancel();
    _pushSubscription?.cancel();
    api.fechar();
    super.dispose();
  }
}

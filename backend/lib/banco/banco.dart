import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../util/calculo_pedido.dart';
import '../util/data_hora.dart';
import '../util/env.dart';
import '../util/estado_atendimento.dart';
import '../util/fluxo_padrao.dart';
import '../util/validacao_operacao.dart';

class ConflitoVersao implements Exception {
  final String mensagem;
  const ConflitoVersao(this.mensagem);
  @override
  String toString() => mensagem;
}

class Banco {
  late final Database db;

  Banco({String? caminhoBanco}) {
    final caminho =
        caminhoBanco ?? Env.get('DATABASE_PATH', padrao: 'data/ao_ponto.db');
    final arquivo = File(caminho);
    arquivo.parent.createSync(recursive: true);
    db = sqlite3.open(caminho);
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA busy_timeout = 5000;');
    db.execute('BEGIN IMMEDIATE');
    try {
      _migrar();
      _inserirPadroes();
      _migrarConfiguracaoV12();
      _migrarConfiguracaoV13();
      _migrarMensagemPedidoEnviado();
      _sanearEstadoInicial();
      db.execute("UPDATE push_saida SET status = 'pendente' WHERE status = 'enviando'");
      db.execute(
          "UPDATE whatsapp_saida SET status = 'incerto', erro = 'Envio interrompido por reinício' WHERE status = 'enviando'");
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      db.dispose();
      rethrow;
    }
  }

  void fechar() => db.dispose();

  void _migrar() {
    db.execute('''
      CREATE TABLE IF NOT EXISTS configuracao (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        json TEXT NOT NULL,
        versao INTEGER NOT NULL DEFAULT 1,
        atualizado_em TEXT NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS meta (
        chave TEXT PRIMARY KEY,
        valor TEXT NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS cardapio_itens (
        id TEXT PRIMARY KEY,
        tipo TEXT NOT NULL CHECK (tipo IN ('tamanho','mistura','acompanhamento')),
        nome TEXT NOT NULL,
        preco REAL,
        ativo INTEGER NOT NULL DEFAULT 1,
        ordem INTEGER NOT NULL DEFAULT 0
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS pedidos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        numero INTEGER UNIQUE,
        telefone TEXT NOT NULL,
        cliente_nome TEXT NOT NULL,
        status TEXT NOT NULL,
        recebimento TEXT NOT NULL,
        endereco TEXT,
        pagamento TEXT NOT NULL,
        troco_para REAL,
        observacao TEXT,
        subtotal REAL NOT NULL,
        taxa_entrega REAL NOT NULL,
        total REAL NOT NULL,
        itens_json TEXT NOT NULL,
        versao INTEGER NOT NULL DEFAULT 1,
        criado_em TEXT NOT NULL,
        atualizado_em TEXT NOT NULL
      );
    ''');

    _adicionarColunaSeAusente('pedidos', 'mensagem_id', 'TEXT');
    _adicionarColunaSeAusente('pedidos', 'motivo_cancelamento', 'TEXT');
    db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_pedidos_mensagem ON pedidos(mensagem_id)');
    db.execute('''CREATE TABLE IF NOT EXISTS webhook_entrada (
      id TEXT PRIMARY KEY, payload TEXT NOT NULL, criado_em TEXT NOT NULL
    )''');
    db.execute('''CREATE TABLE IF NOT EXISTS whatsapp_saida (
      id INTEGER PRIMARY KEY AUTOINCREMENT, payload TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pendente', tentativas INTEGER NOT NULL DEFAULT 0,
      criado_em TEXT NOT NULL, erro TEXT
    )''');
    _adicionarColunaSeAusente(
      'whatsapp_saida',
      'canal',
      "TEXT NOT NULL DEFAULT 'meta'",
    );

    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_saida_canal_status '
      'ON whatsapp_saida(canal, status, id)',
    );
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_saida_status ON whatsapp_saida(status, id)');
    _adicionarColunaSeAusente('pedidos', 'cep_entrega', 'TEXT');
    _adicionarColunaSeAusente('pedidos', 'cidade_entrega', 'TEXT');
    _adicionarColunaSeAusente('pedidos', 'uf_entrega', 'TEXT');
    _adicionarColunaSeAusente(
        'pedidos', 'endereco_validado', 'INTEGER NOT NULL DEFAULT 0');

    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_pedidos_status ON pedidos(status);');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_pedidos_criado ON pedidos(criado_em);');

    db.execute('''
      CREATE TABLE IF NOT EXISTS sessoes (
        telefone TEXT PRIMARY KEY,
        nome TEXT,
        etapa TEXT NOT NULL,
        dados_json TEXT NOT NULL,
        modo_humano INTEGER NOT NULL DEFAULT 0,
        ultima_atividade TEXT NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS mensagens_processadas (
        id TEXT PRIMARY KEY,
        status TEXT NOT NULL,
        atualizado_em TEXT NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nivel TEXT NOT NULL,
        evento TEXT NOT NULL,
        detalhes TEXT,
        criado_em TEXT NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS push_tokens (
        token TEXT PRIMARY KEY,
        atualizado_em TEXT NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS push_saida (
        pedido_id INTEGER PRIMARY KEY,
        titulo TEXT NOT NULL,
        corpo TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pendente',
        tentativas INTEGER NOT NULL DEFAULT 0,
        criado_em TEXT NOT NULL,
        ultimo_envio_em TEXT,
        erro TEXT,
        FOREIGN KEY (pedido_id) REFERENCES pedidos(id)
      );
    ''');
    _adicionarColunaSeAusente('push_saida', 'ultimo_envio_em', 'TEXT');

    db.execute('''
      CREATE TABLE IF NOT EXISTS push_humano (
        telefone TEXT PRIMARY KEY,
        titulo TEXT NOT NULL,
        corpo TEXT NOT NULL,
        ativo INTEGER NOT NULL DEFAULT 1,
        ultimo_envio_em TEXT,
        tentativas INTEGER NOT NULL DEFAULT 0
      );
    ''');
  }

  void _adicionarColunaSeAusente(
      String tabela, String coluna, String definicao) {
    final colunas = db.select('PRAGMA table_info($tabela)');
    final existe = colunas.any((r) => r['name']?.toString() == coluna);
    if (!existe) {
      db.execute('ALTER TABLE $tabela ADD COLUMN $coluna $definicao');
    }
  }

  void _inserirPadroes() {
    final configExiste =
        db.select('SELECT 1 FROM configuracao WHERE id = 1 LIMIT 1').isNotEmpty;
    if (!configExiste) {
      final config = <String, dynamic>{
        'nomeEstabelecimento': 'Ao Ponto Marmitaria',
        'estadoBot': 'fechado',
        'usarHorarioAutomatico': false,
        'horarios': {
          '1': {'ativo': true, 'inicio': '10:00', 'fim': '14:00'},
          '2': {'ativo': true, 'inicio': '10:00', 'fim': '14:00'},
          '3': {'ativo': true, 'inicio': '10:00', 'fim': '14:00'},
          '4': {'ativo': true, 'inicio': '10:00', 'fim': '14:00'},
          '5': {'ativo': true, 'inicio': '10:00', 'fim': '14:00'},
          '6': {'ativo': true, 'inicio': '10:00', 'fim': '14:00'},
          '7': {'ativo': false, 'inicio': '10:00', 'fim': '14:00'},
        },
        'sessaoExpiraMinutos': 30,
        'entregaAtiva': true,
        'retiradaAtiva': true,
        'taxaEntrega': 0.0,
        'cidadesEntrega': [
          {
            'id': 'barra_bonita_sp',
            'nome': 'Barra Bonita',
            'uf': 'SP',
            'taxa': 8.0,
            'ativa': true,
            'aliases': ['Barra Bonita']
          },
          {
            'id': 'igaracu_do_tiete_sp',
            'nome': 'Igaraçu do Tietê',
            'uf': 'SP',
            'taxa': 10.0,
            'ativa': true,
            'aliases': ['Igaraçu do Tietê', 'Igaracu do Tiete']
          },
        ],
        'pagamentos': {'pix': true, 'dinheiro': true, 'cartao': true},
        'chavePix': '',
        'enderecoRetirada': '',
        'permitirObservacoes': true,
        'saladaIncluida': true,
        'descricaoSalada': 'Salada do dia',
        'mensagens': {
          'boasVindas': 'Olá! 👋 Bem-vindo à Ao Ponto Marmitaria.',
          'fechado':
              'No momento não estamos atendendo. Volte em nosso próximo horário. ❤️',
          'pausado':
              'Nosso atendimento está pausado por alguns minutos. Tente novamente em breve. 🍱',
          'esgotado':
              'Esgotamos por hoje! 😔 Obrigado pelos pedidos. Amanhã tem cardápio novo. ❤️',
          'pedidoConfirmado': 'Pedido enviado para a loja.',
        },
        'fluxo': fluxoPadrao(),
      };
      db.execute(
        'INSERT INTO configuracao (id, json, versao, atualizado_em) VALUES (1, ?, 1, ?)',
        [jsonEncode(config), agoraIso()],
      );
    }

    if (db.select("SELECT 1 FROM meta WHERE chave='menu_version'").isEmpty) {
      db.execute(
          "INSERT INTO meta (chave, valor) VALUES ('menu_version', '1')");
    }

    if (!configExiste &&
        db.select('SELECT 1 FROM cardapio_itens LIMIT 1').isEmpty) {
      final stmt = db.prepare('''
        INSERT INTO cardapio_itens (id, tipo, nome, preco, ativo, ordem)
        VALUES (?, ?, ?, ?, ?, ?)
      ''');
      try {
        final itens = [
          ['tam_pequena', 'tamanho', 'Pequena', 8.0, 1, 1],
          ['tam_media', 'tamanho', 'Média', 15.0, 1, 2],
          ['tam_grande', 'tamanho', 'Grande', 20.0, 1, 3],
          ['mis_bife', 'mistura', 'Bife acebolado', null, 1, 1],
          ['mis_frango', 'mistura', 'Filé de frango', null, 1, 2],
          ['mis_calabresa', 'mistura', 'Calabresa acebolada', null, 1, 3],
          ['mis_carne_moida', 'mistura', 'Carne moída', null, 1, 4],
          ['aco_macarrao', 'acompanhamento', 'Macarrão', null, 1, 1],
          ['aco_batata', 'acompanhamento', 'Batata', null, 1, 2],
        ];
        for (final item in itens) {
          stmt.execute(item);
        }
      } finally {
        stmt.dispose();
      }
    }
  }

  void _migrarConfiguracaoV12() {
    final row =
        db.select('SELECT json, versao FROM configuracao WHERE id = 1').first;
    final dados =
        Map<String, dynamic>.from(jsonDecode(row['json'] as String) as Map);
    final fluxoAtual = dados['fluxo'];
    final fluxoNovo = mesclarFluxoComPadrao(fluxoAtual);
    final antes = fluxoAtual == null ? '' : jsonEncode(fluxoAtual);
    final depois = jsonEncode(fluxoNovo);
    if (antes == depois) return;
    dados['fluxo'] = fluxoNovo;
    final novaVersao = (row['versao'] as int) + 1;
    db.execute(
      'UPDATE configuracao SET json = ?, versao = ?, atualizado_em = ? WHERE id = 1',
      [jsonEncode(dados), novaVersao, agoraIso()],
    );
    log('INFO', 'migracao_v1_2_fluxo',
        'Editor de fluxo configurável adicionado.');
  }

  void _migrarConfiguracaoV13() {
    final row =
        db.select('SELECT json, versao FROM configuracao WHERE id = 1').first;
    final dados =
        Map<String, dynamic>.from(jsonDecode(row['json'] as String) as Map);
    var alterou = false;

    if (!dados.containsKey('cidadesEntrega')) {
      dados['cidadesEntrega'] = [
        {
          'id': 'barra_bonita_sp',
          'nome': 'Barra Bonita',
          'uf': 'SP',
          'taxa': 8.0,
          'ativa': true,
          'aliases': ['Barra Bonita']
        },
        {
          'id': 'igaracu_do_tiete_sp',
          'nome': 'Igaraçu do Tietê',
          'uf': 'SP',
          'taxa': 10.0,
          'ativa': true,
          'aliases': ['Igaraçu do Tietê', 'Igaracu do Tiete']
        },
      ];
      alterou = true;
    }

    final fluxo = Map<String, dynamic>.from(dados['fluxo'] as Map? ?? {});
    final endereco = Map<String, dynamic>.from(fluxo['endereco'] as Map? ?? {});
    const mensagemAntiga =
        '📍 Envie seu endereço completo em uma mensagem:\nRua, número, bairro, complemento e referência.';
    const mensagemNova =
        '📍 Envie seu endereço para entrega:\nRua, número, bairro e complemento/referência.';
    if ((endereco['mensagem']?.toString() ?? '') == mensagemAntiga ||
        endereco['mensagem'] ==
            '📍 Envie seu endereço completo com CEP em uma mensagem:\nRua, número, bairro, CEP, complemento e referência.') {
      endereco['mensagem'] = mensagemNova;
      fluxo['endereco'] = endereco;
      dados['fluxo'] = fluxo;
      alterou = true;
    }

    if (!alterou) return;
    final novaVersao = (row['versao'] as int) + 1;
    db.execute(
      'UPDATE configuracao SET json = ?, versao = ?, atualizado_em = ? WHERE id = 1',
      [jsonEncode(dados), novaVersao, agoraIso()],
    );
    log('INFO', 'migracao_v1_3_entrega_por_cidade',
        'Taxas por cidade adicionadas.');
  }

  void _migrarMensagemPedidoEnviado() {
    final row =
        db.select('SELECT json, versao FROM configuracao WHERE id = 1').first;
    final dados =
        Map<String, dynamic>.from(jsonDecode(row['json'] as String) as Map);
    final mensagens =
        Map<String, dynamic>.from(dados['mensagens'] as Map? ?? {});
    const anterior =
        'Pedido recebido! ✅ Aguarde a confirmação do estabelecimento.';
    if (mensagens['pedidoConfirmado'] != anterior) return;
    mensagens['pedidoConfirmado'] = 'Pedido enviado para a loja.';
    dados['mensagens'] = mensagens;
    db.execute(
      'UPDATE configuracao SET json = ?, versao = ?, atualizado_em = ? WHERE id = 1',
      [jsonEncode(dados), (row['versao'] as int) + 1, agoraIso()],
    );
    log('INFO', 'mensagem_pedido_enviado_atualizada');
  }

  void _sanearEstadoInicial() {
    final wrapper = obterConfiguracao();
    final dados = Map<String, dynamic>.from(wrapper['dados'] as Map);
    try {
      ValidacaoOperacao.validarConfiguracaoEstrutural(dados);
      if (dados['estadoBot'] == 'atendendo') {
        ValidacaoOperacao.validarProntidao(dados, obterCardapio());
      }
    } catch (e) {
      if (dados['estadoBot'] != 'fechado') {
        dados['estadoBot'] = 'fechado';
        final novaVersao = (wrapper['versao'] as int) + 1;
        db.execute(
          'UPDATE configuracao SET json = ?, versao = ?, atualizado_em = ? WHERE id = 1',
          [jsonEncode(dados), novaVersao, agoraIso()],
        );
        limparSessoesAutomaticas();
        log('WARN', 'bot_fechado_por_configuracao_incompleta', e.toString());
      }
    }
  }

  Map<String, dynamic> obterConfiguracao() {
    final row =
        db.select('SELECT json, versao FROM configuracao WHERE id = 1').first;
    return {
      'versao': row['versao'] as int,
      'dados': jsonDecode(row['json'] as String) as Map<String, dynamic>,
    };
  }

  Map<String, dynamic> atualizarConfiguracao(
      Map<String, dynamic> dados, int versaoEsperada) {
    final atual = obterConfiguracao();
    if (atual['versao'] != versaoEsperada) {
      throw const ConflitoVersao(
          'A configuração foi alterada em outro dispositivo.');
    }

    ValidacaoOperacao.validarConfiguracaoEstrutural(dados);
    if (dados['estadoBot'] == 'atendendo') {
      ValidacaoOperacao.validarProntidao(dados, obterCardapio());
    }

    final estadoAnterior =
        ((atual['dados'] as Map)['estadoBot'] ?? 'fechado').toString();
    final estadoNovo = (dados['estadoBot'] ?? 'fechado').toString();
    final novaVersao = versaoEsperada + 1;
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute(
        'UPDATE configuracao SET json = ?, versao = ?, atualizado_em = ? WHERE id = 1 AND versao = ?',
        [jsonEncode(dados), novaVersao, agoraIso(), versaoEsperada],
      );
      if (db.updatedRows != 1) {
        throw const ConflitoVersao(
            'A configuração foi alterada em outro dispositivo.');
      }
      if (estadoAnterior != estadoNovo &&
          (estadoNovo == 'esgotado' || estadoNovo == 'fechado')) {
        limparSessoesAutomaticas();
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }

    log('INFO', 'configuracao_atualizada', 'Versão $novaVersao');
    return {'versao': novaVersao, 'dados': dados};
  }

  Map<String, dynamic> obterCardapio() {
    final versao = int.tryParse(
          db
              .select("SELECT valor FROM meta WHERE chave='menu_version'")
              .first['valor'] as String,
        ) ??
        1;
    final rows = db.select(
        'SELECT id, tipo, nome, preco, ativo, ordem FROM cardapio_itens ORDER BY tipo, ordem, nome');
    Map<String, dynamic> item(Row r) => {
          'id': r['id'],
          'tipo': r['tipo'],
          'nome': r['nome'],
          'preco': r['preco'],
          'ativo': (r['ativo'] as int) == 1,
          'ordem': r['ordem'],
        };
    final itens = rows.map(item).toList();
    return {
      'versao': versao,
      'tamanhos': itens.where((e) => e['tipo'] == 'tamanho').toList(),
      'misturas': itens.where((e) => e['tipo'] == 'mistura').toList(),
      'acompanhamentos':
          itens.where((e) => e['tipo'] == 'acompanhamento').toList(),
    };
  }

  Map<String, dynamic> atualizarCardapio(Map<String, dynamic> corpo) {
    final atual = obterCardapio();
    final esperada = (corpo['versao'] as num?)?.toInt() ?? -1;
    if (atual['versao'] != esperada) {
      throw const ConflitoVersao(
          'O cardápio foi alterado em outro dispositivo.');
    }

    ValidacaoOperacao.validarCardapioEstrutural(corpo);
    final config = obterConfiguracao();
    final dadosConfig = Map<String, dynamic>.from(config['dados'] as Map);
    if (dadosConfig['estadoBot'] == 'atendendo') {
      ValidacaoOperacao.validarProntidao(dadosConfig, corpo);
    }

    final colecoes = <String, String>{
      'tamanhos': 'tamanho',
      'misturas': 'mistura',
      'acompanhamentos': 'acompanhamento',
    };

    db.execute('BEGIN IMMEDIATE');
    try {
      if (obterCardapio()['versao'] != esperada) {
        throw const ConflitoVersao(
            'O cardápio foi alterado em outro dispositivo.');
      }
      db.execute('DELETE FROM cardapio_itens');
      final stmt = db.prepare('''
        INSERT INTO cardapio_itens (id, tipo, nome, preco, ativo, ordem)
        VALUES (?, ?, ?, ?, ?, ?)
      ''');
      try {
        for (final entry in colecoes.entries) {
          final lista = (corpo[entry.key] as List? ?? const []);
          for (var i = 0; i < lista.length; i++) {
            final item = Map<String, dynamic>.from(lista[i] as Map);
            final id = (item['id']?.toString().trim().isNotEmpty ?? false)
                ? item['id'].toString()
                : '${entry.value}_${DateTime.now().microsecondsSinceEpoch}_$i';
            stmt.execute([
              id,
              entry.value,
              item['nome']?.toString().trim() ?? '',
              entry.value == 'tamanho'
                  ? (item['preco'] as num?)?.toDouble() ?? 0.0
                  : null,
              item['ativo'] == false ? 0 : 1,
              (item['ordem'] as num?)?.toInt() ?? (i + 1),
            ]);
          }
        }
      } finally {
        stmt.dispose();
      }
      final novaVersao = esperada + 1;
      db.execute("UPDATE meta SET valor = ? WHERE chave='menu_version'",
          [novaVersao.toString()]);
      db.execute('COMMIT');
      log('INFO', 'cardapio_atualizado', 'Versão $novaVersao');
      return obterCardapio();
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Map<String, dynamic>? obterSessao(String telefone) {
    final rows =
        db.select('SELECT * FROM sessoes WHERE telefone = ?', [telefone]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return {
      'telefone': r['telefone'],
      'nome': r['nome'],
      'etapa': r['etapa'],
      'dados': jsonDecode(r['dados_json'] as String) as Map<String, dynamic>,
      'modoHumano': (r['modo_humano'] as int) == 1,
      'ultimaAtividade': r['ultima_atividade'],
    };
  }

  void salvarSessao({
    required String telefone,
    String? nome,
    required String etapa,
    required Map<String, dynamic> dados,
    bool modoHumano = false,
  }) {
    db.execute('''
      INSERT INTO sessoes (telefone, nome, etapa, dados_json, modo_humano, ultima_atividade)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(telefone) DO UPDATE SET
        nome=excluded.nome,
        etapa=excluded.etapa,
        dados_json=excluded.dados_json,
        modo_humano=excluded.modo_humano,
        ultima_atividade=excluded.ultima_atividade
    ''', [
      telefone,
      nome,
      etapa,
      jsonEncode(dados),
      modoHumano ? 1 : 0,
      agoraIso()
    ]);
  }

  void definirModoHumano(String telefone, bool ativo) {
    final sessao = obterSessao(telefone);
    if (ativo) {
      salvarSessao(
          telefone: telefone,
          nome: sessao?['nome'] as String?,
          etapa: 'inicio',
          dados: {},
          modoHumano: true);
    } else if (sessao == null) {
      salvarSessao(
          telefone: telefone, etapa: 'inicio', dados: {}, modoHumano: ativo);
    } else {
      salvarSessao(
        telefone: telefone,
        nome: sessao['nome'] as String?,
        etapa: sessao['etapa'] as String,
        dados: Map<String, dynamic>.from(sessao['dados'] as Map),
        modoHumano: ativo,
      );
    }
    if (ativo) {
      final nome = obterSessao(telefone)?['nome']?.toString().trim();
      db.execute('''
        INSERT INTO push_humano(
          telefone, titulo, corpo, ativo, ultimo_envio_em, tentativas
        ) VALUES (?, 'Cliente aguardando atendente', ?, 1, NULL, 0)
        ON CONFLICT(telefone) DO UPDATE SET
          titulo=excluded.titulo,
          corpo=excluded.corpo,
          ativo=1,
          ultimo_envio_em=NULL,
          tentativas=0
      ''', [
        telefone,
        '${nome?.isNotEmpty == true ? nome : 'Cliente'} - $telefone',
      ]);
    } else {
      db.execute('UPDATE push_humano SET ativo=0 WHERE telefone=?', [telefone]);
    }
    log('INFO', ativo ? 'modo_humano_ativado' : 'modo_humano_desativado',
        telefone);
  }

  void retomarModoAutomatico(String telefone) {
    final sessao = obterSessao(telefone);
    final nome = sessao?['nome']?.toString();
    salvarSessao(
      telefone: telefone,
      nome: nome,
      etapa: 'inicio',
      dados: {
        'clienteNome': (nome?.trim().isNotEmpty ?? false) ? nome : 'Cliente',
        'itens': <dynamic>[],
      },
      modoHumano: false,
    );
    db.execute('UPDATE push_humano SET ativo=0 WHERE telefone=?', [telefone]);
    log('INFO', 'modo_humano_desativado_inicio_limpo', telefone);
  }

  void limparSessoesAutomaticas() {
    db.execute('DELETE FROM sessoes WHERE modo_humano = 0');
    log('INFO', 'sessoes_automaticas_limpas');
  }

  void excluirSessao(String telefone) {
    db.execute('DELETE FROM sessoes WHERE telefone = ?', [telefone]);
  }

  List<Map<String, dynamic>> listarSessoesHumanas() {
    final rows = db.select('''
      SELECT s.telefone, s.nome, s.ultima_atividade,
        COALESCE(p.ativo, 0) AS alerta_ativo
      FROM sessoes s
      LEFT JOIN push_humano p ON p.telefone = s.telefone
      WHERE s.modo_humano = 1
      ORDER BY s.ultima_atividade DESC
    ''');
    return rows
        .map((r) => {
              'telefone': r['telefone'],
              'nome': r['nome'] ?? '',
              'ultimaAtividade': r['ultima_atividade'],
              'alertaAtivo': (r['alerta_ativo'] as int) == 1,
            })
        .toList();
  }

  void pararAlertaHumano(String telefone) {
    db.execute('UPDATE push_humano SET ativo=0 WHERE telefone=?', [telefone]);
    log('INFO', 'alerta_humano_parado', telefone);
  }

  Map<String, dynamic> criarPedido({
    required String telefone,
    required String clienteNome,
    String? mensagemId,
    required String recebimento,
    String? endereco,
    String? cepEntrega,
    String? cidadeEntrega,
    String? ufEntrega,
    bool enderecoValidado = false,
    required String pagamento,
    double? trocoPara,
    String? observacao,
    required double subtotal,
    required double taxaEntrega,
    required List<Map<String, dynamic>> itens,
  }) {
    final calculo =
        CalculoPedido(itens, recebimento == 'entrega' ? taxaEntrega : 0);
    if ((calculo.subtotal - subtotal).abs() > 0.001 ||
        !{'entrega', 'retirada'}.contains(recebimento) ||
        !{'pix', 'dinheiro', 'cartao'}.contains(pagamento) ||
        (trocoPara != null &&
            (!trocoPara.isFinite || trocoPara < calculo.total))) {
      throw ArgumentError('Pedido inconsistente. Revise os valores.');
    }
    if (recebimento == 'entrega' &&
        ((endereco?.trim().isEmpty ?? true) ||
            (cidadeEntrega?.isEmpty ?? true))) {
      throw ArgumentError('Endereço e cidade são obrigatórios para entrega.');
    }
    subtotal = calculo.subtotal;
    taxaEntrega = calculo.taxaEntrega;
    final total = calculo.total;
    final agora = agoraIso();
    db.execute('''
      INSERT INTO pedidos (
        telefone, cliente_nome, status, recebimento, endereco, cep_entrega,
        cidade_entrega, uf_entrega, endereco_validado, pagamento,
        troco_para, observacao, subtotal, taxa_entrega, total, itens_json,
        versao, criado_em, atualizado_em
      ) VALUES (?, ?, 'novo', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
    ''', [
      telefone,
      clienteNome,
      recebimento,
      endereco,
      cepEntrega,
      cidadeEntrega,
      ufEntrega,
      enderecoValidado ? 1 : 0,
      pagamento,
      trocoPara,
      observacao,
      subtotal,
      taxaEntrega,
      total,
      jsonEncode(itens),
      agora,
      agora,
    ]);
    final id = db.lastInsertRowId;
    db.execute('UPDATE pedidos SET numero = ?, mensagem_id = ? WHERE id = ?',
        [id, mensagemId, id]);
    db.execute('''
      INSERT OR IGNORE INTO push_saida(
        pedido_id, titulo, corpo, status, tentativas, criado_em
      ) VALUES (?, ?, ?, 'pendente', 0, ?)
    ''', [
      id,
      'Novo pedido #$id',
      '$clienteNome - R\$ ${total.toStringAsFixed(2).replaceAll('.', ',')}',
      agora,
    ]);
    log('INFO', 'pedido_criado', '#$id');
    return obterPedido(id)!;
  }

  Map<String, dynamic>? obterPedido(int id) {
    final rows = db.select('SELECT * FROM pedidos WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    return _pedidoMap(rows.first);
  }

  List<Map<String, dynamic>> listarPedidos({String? status, int limite = 100}) {
    final rows = status == null || status == 'todos'
        ? db.select(
            "SELECT * FROM pedidos ORDER BY CASE WHEN status IN ('finalizado','cancelado') THEN 1 ELSE 0 END, id DESC LIMIT ?",
            [
                limite
              ])
        : db.select(
            'SELECT * FROM pedidos WHERE status = ? ORDER BY id DESC LIMIT ?',
            [status, limite]);
    return rows.map(_pedidoMap).toList();
  }

  Map<String, dynamic> atualizarStatusPedido(
      int id, String status, int versaoEsperada,
      {String? motivoCancelamento}) {
    const permitidos = {
      'novo',
      'confirmado',
      'pronto',
      'finalizado',
      'cancelado'
    };
    if (!permitidos.contains(status)) throw ArgumentError('Status inválido.');
    final atual = obterPedido(id);
    if (atual == null) throw StateError('Pedido não encontrado.');
    if (atual['versao'] != versaoEsperada) {
      throw const ConflitoVersao('O pedido foi alterado em outro dispositivo.');
    }
    const transicoes = {
      'novo': {'confirmado', 'cancelado'},
      'confirmado': {'pronto'},
      'pronto': {'finalizado'},
      'finalizado': <String>{},
      'cancelado': <String>{},
    };
    if (!(transicoes[atual['status']] ?? {}).contains(status)) {
      throw ArgumentError(
          'Transição de status não permitida. Atualize o pedido.');
    }
    final motivo = motivoCancelamento?.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (status == 'cancelado' &&
        (motivo == null || motivo.isEmpty || motivo.length > 300)) {
      throw ArgumentError('Informe o motivo da recusa (até 300 caracteres).');
    }
    if (status != 'cancelado' && motivo != null) {
      throw ArgumentError('Motivo só é aceito ao recusar um pedido.');
    }
    db.execute('''
      UPDATE pedidos SET status = ?, motivo_cancelamento = ?,
        versao = versao + 1, atualizado_em = ?
      WHERE id = ? AND versao = ?
    ''', [status, motivo, agoraIso(), id, versaoEsperada]);
    if (db.updatedRows != 1) {
      throw const ConflitoVersao('O pedido foi alterado em outro dispositivo.');
    }
    if (status != 'novo') {
      db.execute(
        "UPDATE push_saida SET status='concluido' WHERE pedido_id=?",
        [id],
      );
    }
    log('INFO', 'pedido_status', '#$id -> $status');
    return obterPedido(id)!;
  }

  Map<String, dynamic> _pedidoMap(Row r) => {
        'id': r['id'],
        'numero': r['numero'],
        'telefone': r['telefone'],
        'clienteNome': r['cliente_nome'],
        'status': r['status'],
        'motivoCancelamento': r['motivo_cancelamento'],
        'recebimento': r['recebimento'],
        'endereco': r['endereco'],
        'cepEntrega': r['cep_entrega'],
        'cidadeEntrega': r['cidade_entrega'],
        'ufEntrega': r['uf_entrega'],
        'enderecoValidado': (r['endereco_validado'] as int? ?? 0) == 1,
        'pagamento': r['pagamento'],
        'trocoPara': r['troco_para'],
        'observacao': r['observacao'],
        'subtotal': r['subtotal'],
        'taxaEntrega': r['taxa_entrega'],
        'total': r['total'],
        'itens': jsonDecode(r['itens_json'] as String),
        'versao': r['versao'],
        'criadoEm': r['criado_em'],
        'atualizadoEm': r['atualizado_em'],
      };

  bool iniciarProcessamentoMensagem(String id) {
    final rows = db.select(
        'SELECT status, atualizado_em FROM mensagens_processadas WHERE id = ?',
        [id]);
    if (rows.isNotEmpty) {
      final status = rows.first['status'] as String;
      if (status == 'done') return false;
      final atualizada =
          DateTime.tryParse(rows.first['atualizado_em'] as String);
      if (status == 'processing' &&
          atualizada != null &&
          agoraLocal().difference(atualizada).inMinutes < 2) {
        return false;
      }
    }
    db.execute('''
      INSERT INTO mensagens_processadas (id, status, atualizado_em)
      VALUES (?, 'processing', ?)
      ON CONFLICT(id) DO UPDATE SET status='processing', atualizado_em=excluded.atualizado_em
    ''', [id, agoraIso()]);
    return true;
  }

  void finalizarMensagem(String id, {bool sucesso = true}) {
    db.execute(
        'UPDATE mensagens_processadas SET status = ?, atualizado_em = ? WHERE id = ?',
        [sucesso ? 'done' : 'failed', agoraIso(), id]);
  }

  Map<String, dynamic> dashboard() {
    final chave = hojeChave();
    final rows = db.select('''
      SELECT
        COUNT(*) AS pedidos,
        COALESCE(SUM(CASE WHEN status != 'cancelado' THEN total ELSE 0 END), 0) AS vendas,
        SUM(CASE WHEN status = 'novo' THEN 1 ELSE 0 END) AS novos,
        SUM(CASE WHEN status = 'confirmado' THEN 1 ELSE 0 END) AS confirmados,
        SUM(CASE WHEN status = 'pronto' THEN 1 ELSE 0 END) AS prontos
      FROM pedidos
      WHERE criado_em LIKE ?
    ''', ['$chave%']).first;
    final ultimo = db
        .select('SELECT COALESCE(MAX(id),0) AS id FROM pedidos')
        .first['id'] as int;
    final config = obterConfiguracao();
    return {
      'pedidosHoje': rows['pedidos'] ?? 0,
      'vendasHoje': (rows['vendas'] as num?)?.toDouble() ?? 0.0,
      'novos': rows['novos'] ?? 0,
      'confirmados': rows['confirmados'] ?? 0,
      'prontos': rows['prontos'] ?? 0,
      'ultimoPedidoId': ultimo,
      'estadoBot':
          estadoAtendimentoEfetivo(config['dados'] as Map<String, dynamic>),
      'problemasProntidao': ValidacaoOperacao.problemasProntidao(
          config['dados'] as Map<String, dynamic>, obterCardapio()),
      'enviosPendentes': db
          .select(
            "SELECT COUNT(*) n FROM whatsapp_saida "
            "WHERE status IN ('pendente','enviando','falhou','incerto')",
          )
          .first['n'],
      'estadoManual': (config['dados'] as Map<String, dynamic>)['estadoBot'],
    };
  }

  void log(String nivel, String evento, [String? detalhes]) {
    try {
      db.execute(
          'INSERT INTO logs (nivel, evento, detalhes, criado_em) VALUES (?, ?, ?, ?)',
          [nivel, evento, detalhes, agoraIso()]);
    } catch (_) {
      stderr.writeln('Falha ao gravar log: $evento');
    }
  }

  List<Map<String, dynamic>> enviosComFalha() => db.select('''
    SELECT id, payload, status, erro, criado_em, tentativas FROM whatsapp_saida
    WHERE status IN ('falhou','incerto') ORDER BY id LIMIT 100
  ''').map((r) {
        final payload =
            jsonDecode(r['payload'] as String) as Map<String, dynamic>;
        return {
          'id': r['id'],
          'status': r['status'],
          'erro': r['erro'],
          'criadoEm': r['criado_em'],
          'tentativas': r['tentativas'],
          'telefone': payload['to'] ?? '',
          'tipo': payload['type'] ?? payload['status'] ?? '',
        };
      }).toList();

  void resolverEnvio(int id, String acao) {
    if (!{'reenviar', 'descartar'}.contains(acao))
      throw ArgumentError('Ação inválida.');
    final novo = acao == 'reenviar' ? 'pendente' : 'descartado';
    db.execute(
        "UPDATE whatsapp_saida SET status = ?, erro = NULL WHERE id = ? AND status IN ('falhou','incerto')",
        [novo, id]);
    if (db.updatedRows != 1)
      throw const ConflitoVersao(
          'Esse envio já foi resolvido em outro dispositivo.');
    log('WARN', 'envio_resolvido', '#$id: $novo');
  }

  List<Map<String, dynamic>> listarLogs({int limite = 100}) {
    return db
        .select(
            'SELECT id, nivel, evento, detalhes, criado_em FROM logs ORDER BY id DESC LIMIT ?',
            [limite])
        .map((r) => {
              'id': r['id'],
              'nivel': r['nivel'],
              'evento': r['evento'],
              'detalhes': r['detalhes'] ?? '',
              'criadoEm': r['criado_em'],
            })
        .toList();
  }

  String gerarBackup({String diretorio = 'backups'}) {
    final dir = Directory(diretorio)..createSync(recursive: true);
    final arquivo = File(dir.path +
        '/backup_' +
        DateTime.now().microsecondsSinceEpoch.toString() +
        '.db');
    db.execute('VACUUM INTO ?', [arquivo.path]);
    log('INFO', 'backup_gerado', arquivo.path);
    return arquivo.path;
  }
}

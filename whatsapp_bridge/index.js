import fs from 'node:fs';
import path from 'node:path';

import makeWASocket, {
  DisconnectReason,
  generateMessageIDV2,
  useMultiFileAuthState,
  WAMessageStatus,
} from '@whiskeysockets/baileys';

import { Boom } from '@hapi/boom';
import qrcode from 'qrcode-terminal';

const BACKEND = process.env.BACKEND_URL || 'http://127.0.0.1:8080';
const DIRETORIO_AUTH = path.resolve(
  process.env.WHATSAPP_AUTH_PATH || './auth_info',
);

const ARQUIVO_ENV = path.resolve('../backend/.env');
const ARQUIVO_CONTATOS = path.resolve(
  process.env.BRIDGE_CONTACTS_PATH || './bridge_contacts.json',
);

let token = null;
let sockAtual = null;
let timerSaidas = null;
let processandoSaidas = false;
let timerReconexao = null;
let conectando = false;
let falhasConsecutivas = 0;
let ultimaConexaoAberta = 0;
const confirmacoesEnvio = new Map();

function lerEnv() {
  const resultado = { ...process.env };

  if (!fs.existsSync(ARQUIVO_ENV)) {
    return resultado;
  }

  const linhas = fs
    .readFileSync(ARQUIVO_ENV, 'utf8')
    .split(/\r?\n/);

  for (const linhaOriginal of linhas) {
    const linha = linhaOriginal.trim();

    if (!linha || linha.startsWith('#')) {
      continue;
    }

    const posicao = linha.indexOf('=');

    if (posicao <= 0) {
      continue;
    }

    const chave = linha.substring(0, posicao).trim();

    let valor = linha.substring(posicao + 1).trim();

    if (
      (valor.startsWith('"') && valor.endsWith('"')) ||
      (valor.startsWith("'") && valor.endsWith("'"))
    ) {
      valor = valor.substring(1, valor.length - 1);
    }

    resultado[chave] = valor;
  }

  return resultado;
}

function carregarContatos() {
  try {
    if (!fs.existsSync(ARQUIVO_CONTATOS)) {
      return {};
    }

    return JSON.parse(
      fs.readFileSync(ARQUIVO_CONTATOS, 'utf8'),
    );
  } catch {
    return {};
  }
}

let contatos = carregarContatos();

function salvarContatos() {
  try {
    const temporario = `${ARQUIVO_CONTATOS}.tmp`;

    fs.writeFileSync(
      temporario,
      JSON.stringify(contatos, null, 2),
      'utf8',
    );

    fs.renameSync(
      temporario,
      ARQUIVO_CONTATOS,
    );
  } catch (erro) {
    console.error(
      'Não foi possível salvar bridge_contacts.json:',
      erro.message,
    );
  }
}

async function loginBackend() {
  const env = lerEnv();

  const senha = env.ADMIN_PASSWORD;

  if (!senha) {
    throw new Error(
      'ADMIN_PASSWORD não encontrada em backend/.env',
    );
  }

  const resposta = await fetch(
    `${BACKEND}/api/auth/login`,
    {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        senha,
      }),
      signal: AbortSignal.timeout(8000),
    },
  );

  let dados = {};

  try {
    dados = await resposta.json();
  } catch {
    // Durante o despertar, o provedor pode responder com uma página HTML.
  }

  if (!resposta.ok || !dados.token) {
    throw new Error(
      dados.erro ??
        `Falha ao autenticar no backend (HTTP ${resposta.status}).`,
    );
  }

  token = dados.token;
}

async function chamarBackend(
  rota,
  opcoes = {},
  tentarNovamente = true,
) {
  if (!token) {
    await loginBackend();
  }

  const headers = {
    ...(opcoes.headers ?? {}),
    authorization: `Bearer ${token}`,
  };

  if (opcoes.body) {
    headers['content-type'] = 'application/json';
  }

  const resposta = await fetch(
    `${BACKEND}${rota}`,
    {
      ...opcoes,
      headers,
      signal: AbortSignal.timeout(15000),
    },
  );

  if (
    resposta.status === 401 &&
    tentarNovamente
  ) {
    token = null;

    await loginBackend();

    return chamarBackend(
      rota,
      opcoes,
      false,
    );
  }

  let dados = {};

  try {
    dados = await resposta.json();
  } catch {
    // resposta sem JSON
  }

  if (!resposta.ok) {
    throw new Error(
      dados.erro ??
        `Backend respondeu HTTP ${resposta.status}`,
    );
  }

  return dados;
}

function somenteNumero(jid) {
  return (
    jid
      ?.split('@')[0]
      ?.replace(/\D/g, '') ?? ''
  );
}

function identificarCliente(msg) {
  const jidPrincipal =
    msg.key.remoteJid ?? '';

  const jidAlternativo =
    msg.key.remoteJidAlt ?? '';

  let telefone = '';

  // No Baileys 7 alguns contatos chegam usando LID.
  // Quando existir o JID alternativo com o telefone,
  // usamos o número real.
  if (
    jidAlternativo.endsWith(
      '@s.whatsapp.net',
    )
  ) {
    telefone =
      somenteNumero(jidAlternativo);
  } else if (
    jidPrincipal.endsWith(
      '@s.whatsapp.net',
    )
  ) {
    telefone =
      somenteNumero(jidPrincipal);
  } else {
    telefone =
      somenteNumero(jidPrincipal);
  }

  if (!telefone) {
    return null;
  }

  // Para responder, prefira sempre o JID baseado no número. Enviar para o
  // LID recebido como identificador principal pode ser aceito localmente pelo
  // Baileys e depois recusado pelo WhatsApp com "missing tctoken for contact".
  const jidEnvio =
    jidAlternativo.endsWith('@s.whatsapp.net')
      ? jidAlternativo
      : jidPrincipal;

  contatos[telefone] = jidEnvio;

  salvarContatos();

  return {
    telefone,
    jid: jidEnvio,
  };
}

function desembrulharMensagem(message) {
  let atual = message;

  while (atual) {
    if (atual.ephemeralMessage?.message) {
      atual =
        atual.ephemeralMessage.message;
      continue;
    }

    if (
      atual.viewOnceMessage?.message
    ) {
      atual =
        atual.viewOnceMessage.message;
      continue;
    }

    if (
      atual.viewOnceMessageV2?.message
    ) {
      atual =
        atual.viewOnceMessageV2.message;
      continue;
    }

    if (
      atual.documentWithCaptionMessage
        ?.message
    ) {
      atual =
        atual.documentWithCaptionMessage
          .message;
      continue;
    }

    break;
  }

  return atual ?? {};
}

function extrairTexto(message) {
  const m =
    desembrulharMensagem(message);

  return (
    m.conversation ??
    m.extendedTextMessage?.text ??
    m.imageMessage?.caption ??
    m.videoMessage?.caption ??
    m.buttonsResponseMessage
      ?.selectedDisplayText ??
    m.listResponseMessage?.title ??
    m.templateButtonReplyMessage
      ?.selectedDisplayText ??
    ''
  );
}

function jidParaEnvio(telefone) {
  const salvo =
    contatos[telefone];

  if (salvo) {
    return salvo;
  }

  // Para números normais que ainda não possuem
  // mapeamento salvo.
  if (/^\d{10,15}$/.test(telefone)) {
    return `${telefone}@s.whatsapp.net`;
  }

  return null;
}

function transformarInterativoEmTexto(payload) {
  const interactive = payload.interactive;

  if (!interactive) {
    return '';
  }

  const linhas = [];

  const pergunta =
    interactive.body?.text?.trim() ?? '';

  // REGRA GLOBAL:
  // sempre deixa uma linha vazia entre
  // a pergunta e as opções.
  if (pergunta) {
    linhas.push(pergunta);
    linhas.push('');
  }

  if (interactive.type === 'button') {
    const botoes =
      interactive.action?.buttons ?? [];

    botoes.forEach((botao, indice) => {
      linhas.push(
        `${indice + 1} - ${
          botao.reply?.title ?? ''
        }`,
      );
    });
  }

  if (interactive.type === 'list') {
    let indice = 1;

    const secoes =
      interactive.action?.sections ?? [];

    for (const secao of secoes) {
      for (const linha of secao.rows ?? []) {
        linhas.push(
          `${indice} - ${
            linha.title ?? ''
          }`,
        );

        indice++;
      }
    }
  }

  return linhas
    .filter((linha, indice, array) => {
      // Mantém a linha vazia entre pergunta/opções,
      // mas evita excesso no final.
      if (linha !== '') return true;

      return (
        indice > 0 &&
        indice < array.length - 1
      );
    })
    .join('\n');
}

async function enviarTextoConfirmado(jid, texto) {
  let ultimaFalha = null;

  for (let tentativa = 1; tentativa <= 2; tentativa++) {
    const id = generateMessageIDV2(sockAtual?.user?.id);

    let timer = null;
    const confirmacao = new Promise((resolve, reject) => {
      timer = setTimeout(() => {
        confirmacoesEnvio.delete(id);
        reject(new Error('O WhatsApp não confirmou o envio em 8 segundos.'));
      }, 8000);

      confirmacoesEnvio.set(id, {
        resolve,
        reject,
        timer,
      });
    });

    try {
      await sockAtual.sendMessage(
        jid,
        { text: texto },
        { messageId: id },
      );

      await confirmacao;
      return;
    } catch (erro) {
      ultimaFalha = erro;
      const pendente = confirmacoesEnvio.get(id);
      if (pendente) {
        clearTimeout(pendente.timer);
        confirmacoesEnvio.delete(id);
      }

      const codigo = erro?.codigo?.toString() ?? '';
      if (tentativa === 1 && (codigo === '403' || codigo === '463')) {
        console.warn(
          `WhatsApp recusou a primeira tentativa (${codigo}). ` +
          'Aguardando o token do contato e tentando novamente...',
        );
        await esperar(3000);
        continue;
      }

      throw erro;
    }
  }

  throw ultimaFalha ?? new Error('O WhatsApp não confirmou o envio.');
}

async function enviarSaida(payload) {
  const telefone =
    String(payload.to ?? '').replace(/\D/g, '');

  const jid = jidParaEnvio(telefone);

  if (!jid) {
    throw new Error(
      `Não consegui localizar o WhatsApp de ${telefone}`,
    );
  }

  if (payload.type === 'text') {
    const texto =
      payload.text?.body?.trim() ?? '';

    if (!texto) {
      throw new Error(
        'Resposta de texto vazia.',
      );
    }

    await enviarTextoConfirmado(jid, texto);

    return;
  }

  if (payload.type === 'interactive') {
    const texto =
      transformarInterativoEmTexto(
        payload,
      ).trim();

    if (!texto) {
      throw new Error(
        'Resposta interativa vazia.',
      );
    }

    await enviarTextoConfirmado(jid, texto);

    return;
  }

  throw new Error(
    `Tipo de mensagem não suportado: ${
      payload.type ?? 'desconhecido'
    }`,
  );
}

function esperar(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function agendarConexao(erro, atrasoForcado = null) {
  if (timerReconexao) {
    return;
  }

  falhasConsecutivas++;

  const atraso = atrasoForcado ?? Math.min(
    30000,
    3000 * (2 ** Math.min(falhasConsecutivas - 1, 4)),
  );

  console.error('');
  console.error(
    'Não foi possível conectar agora:',
    erro?.message ?? erro,
  );
  console.log(
    `A ponte continuará ativa e tentará novamente em ${Math.ceil(atraso / 1000)} segundos.`,
  );

  timerReconexao = setTimeout(() => {
    timerReconexao = null;
    iniciarConexao();
  }, atraso);
}

async function iniciarConexao() {
  if (conectando) {
    return;
  }

  conectando = true;

  try {
    await conectar();
  } catch (erro) {
    agendarConexao(erro);
  } finally {
    conectando = false;
  }
}

// Uma falha inesperada de biblioteca não pode deixar a ponte parada em
// silêncio. O watchdog apenas intervém quando não existe socket, tentativa em
// andamento ou reconexão já programada.
setInterval(() => {
  if (!sockAtual && !conectando && !timerReconexao) {
    console.log('Ponte sem conexão ativa. Iniciando recuperação automática...');
    iniciarConexao();
  }
}, 30000);

process.on('unhandledRejection', (erro) => {
  console.error(
    'Falha assíncrona isolada:',
    erro?.message ?? erro,
  );

  if (!sockAtual) {
    agendarConexao(erro);
  }
});

async function informarResultadoSaida(
  id,
  status,
  erro = null,
) {
  let ultimaFalha = null;

  for (let tentativa = 1; tentativa <= 5; tentativa++) {
    try {
      await chamarBackend(
        `/api/bridge/saidas/${id}/resultado`,
        {
          method: 'POST',
          body: JSON.stringify({
            status,
            erro,
          }),
        },
      );

      return;
    } catch (falha) {
      ultimaFalha = falha;

      console.error(
        `Falha ao confirmar saída #${id} no backend ` +
        `(tentativa ${tentativa}/5):`,
        falha.message,
      );

      if (tentativa < 5) {
        await esperar(1000 * tentativa);
      }
    }
  }

  throw ultimaFalha ??
    new Error(
      `Não foi possível registrar o resultado da saída #${id}.`,
    );
}

async function buscarSaidas() {
  if (
    processandoSaidas ||
    !sockAtual
  ) {
    return;
  }

  processandoSaidas = true;

  try {
    const dados =
      await chamarBackend(
        '/api/bridge/saidas',
      );

    const mensagens =
      dados.mensagens ?? [];

    for (const item of mensagens) {
      const id =
        Number(item.id);

      const payload =
        item.payload;

      if (
        !Number.isInteger(id) ||
        id <= 0 ||
        !payload
      ) {
        console.error(
          'Item inválido recebido da fila:',
          item,
        );

        continue;
      }

      try {
        await enviarSaida(payload);

        // Só depois que o Baileys terminou
        // o envio marcamos como enviado.
        await informarResultadoSaida(
          id,
          'enviado',
        );

        console.log(
          `✓ Resposta #${id} enviada.`,
        );
      } catch (erroEnvio) {
        console.error(
          `Falha ao enviar resposta #${id}:`,
          erroEnvio.message,
        );

        try {
          await informarResultadoSaida(
            id,
            'incerto',
            erroEnvio.message,
          );

          console.error(
            `Resposta #${id} marcada como INCERTA. ` +
            'Ela não será reenviada automaticamente.',
          );
        } catch (erroConfirmacao) {
          console.error('');
          console.error(
            `ATENÇÃO: não consegui registrar o resultado ` +
            `da resposta #${id}.`,
          );

          console.error(
            erroConfirmacao.message,
          );

          console.error(
            'A fila ficará parada por segurança para evitar duplicidade.',
          );
        }

        // Não tenta mensagens seguintes quando existe
        // uma saída de resultado duvidoso.
        break;
      }
    }
  } catch (erro) {
    console.error(
      'Falha ao buscar respostas do bot:',
      erro.message,
    );
  } finally {
    processandoSaidas = false;
  }
}

function iniciarBuscaDeSaidas() {
  if (timerSaidas) {
    clearInterval(timerSaidas);
  }

  timerSaidas =
    setInterval(
      buscarSaidas,
      700,
    );
}

function pararBuscaDeSaidas() {
  if (timerSaidas) {
    clearInterval(timerSaidas);
    timerSaidas = null;
  }
}

async function processarEntrada(
  msg,
) {
  if (!msg.message) {
    return;
  }

  if (msg.key.fromMe) {
    return;
  }

  const jid =
    msg.key.remoteJid ?? '';

  if (
    !jid ||
    jid.endsWith('@g.us') ||
    jid === 'status@broadcast' ||
    jid.endsWith('@broadcast') ||
    jid.endsWith('@newsletter')
  ) {
    return;
  }

  const cliente =
    identificarCliente(msg);

  if (!cliente) {
    return;
  }

  const texto =
    extrairTexto(msg.message);

  const mensagemId =
    msg.key.id;

  if (!mensagemId) {
    return;
  }

  console.log('');
  console.log(
    '========================================',
  );
  console.log(
    ' MENSAGEM RECEBIDA',
  );
  console.log(
    '========================================',
  );
  console.log(
    'Nome:',
    msg.pushName ?? 'Cliente',
  );
  console.log(
    'Telefone:',
    cliente.telefone,
  );
  console.log(
    'Mensagem:',
    texto || '[não textual]',
  );
  console.log(
    '========================================',
  );

  try {
    await chamarBackend(
      '/api/bridge/mensagem',
      {
        method: 'POST',
        body: JSON.stringify({
          id: `baileys:${mensagemId}`,
          telefone:
            cliente.telefone,
          nome:
            msg.pushName ??
            'Cliente',
          texto,
        }),
      },
    );

    try {
      await sockAtual.readMessages([
        msg.key,
      ]);
    } catch {
      // Marcar como lida não é crítico.
    }

    // Não espera o próximo intervalo.
    await buscarSaidas();
  } catch (erro) {
    console.error(
      'ERRO AO PROCESSAR MENSAGEM:',
      erro.message,
    );
  }
}

async function conectar() {
  console.log('');
  console.log(
    'Conectando ao backend...',
  );

  await loginBackend();

  console.log(
    'Backend autenticado.',
  );

  const { state, saveCreds } =
    await useMultiFileAuthState(
      DIRETORIO_AUTH,
    );

  const sock = makeWASocket({
    auth: state,
    markOnlineOnConnect: false,
    syncFullHistory: false,
  });

  sockAtual = sock;
  let pareamentoSolicitado = false;

  sock.ev.on('messages.update', (atualizacoes) => {
    for (const item of atualizacoes) {
      const id = item.key?.id;
      const pendente = id ? confirmacoesEnvio.get(id) : null;
      if (!pendente) continue;

      const status = item.update?.status;
      if (status === WAMessageStatus.ERROR) {
        clearTimeout(pendente.timer);
        confirmacoesEnvio.delete(id);
        const codigo = item.update?.messageStubParameters?.[0]?.toString() ?? '';
        const erro = new Error(
          codigo
            ? `WhatsApp recusou a mensagem (erro ${codigo}).`
            : 'WhatsApp recusou a mensagem.',
        );
        erro.codigo = codigo;
        pendente.reject(erro);
      } else if (
        typeof status === 'number' &&
        status >= WAMessageStatus.SERVER_ACK
      ) {
        clearTimeout(pendente.timer);
        confirmacoesEnvio.delete(id);
        pendente.resolve();
      }
    }
  });

  sock.ev.on(
    'creds.update',
    () => {
      Promise.resolve(saveCreds()).catch((erro) => {
        console.error(
          'Falha ao salvar a sessão do WhatsApp:',
          erro?.message ?? erro,
        );
      });
    },
  );

  sock.ev.on(
    'messages.upsert',
    async ({
      messages,
      type,
    }) => {
      if (type !== 'notify') {
        return;
      }

      for (const msg of messages) {
        try {
          await processarEntrada(msg);
        } catch (erro) {
          console.error(
            'Falha isolada ao ler mensagem:',
            erro?.message ?? erro,
          );
        }
      }
    },
  );

  sock.ev.on(
    'connection.update',
    async ({
      connection,
      lastDisconnect,
      qr,
    }) => {
      if (qr) {
        const numeroPareamento =
          (process.env.WHATSAPP_PHONE_NUMBER || '')
            .replace(/\D/g, '');

        if (numeroPareamento && !pareamentoSolicitado) {
          pareamentoSolicitado = true;

          try {
            const codigo = await sock.requestPairingCode(
              numeroPareamento,
            );

            console.log('');
            console.log('========================================');
            console.log(' CODIGO DE CONEXAO DO WHATSAPP');
            console.log('========================================');
            console.log('');
            console.log(codigo);
            console.log('');
            console.log('WhatsApp > Aparelhos conectados');
            console.log('> Conectar com numero de telefone');
            console.log('');
          } catch (erro) {
            pareamentoSolicitado = false;
            console.error('Falha ao gerar codigo de conexao:', erro.message);
          }

          return;
        }

        console.clear();

        console.log(
          '========================================',
        );
        console.log(
          ' AO PONTO BOT - CONECTAR WHATSAPP',
        );
        console.log(
          '========================================',
        );
        console.log('');
        console.log(
          'WhatsApp > Aparelhos conectados',
        );
        console.log(
          '> Conectar um aparelho',
        );
        console.log('');

        qrcode.generate(
          qr,
          {
            small: true,
          },
        );
      }

      if (
        connection === 'open'
      ) {
        falhasConsecutivas = 0;
        ultimaConexaoAberta = Date.now();
        console.clear();

        console.log(
          '========================================',
        );
        console.log(
          ' AO PONTO BOT ONLINE',
        );
        console.log(
          '========================================',
        );
        console.log('');
        console.log(
          'WhatsApp conectado ✅',
        );
        console.log(
          'Backend conectado ✅',
        );
        console.log('');
        console.log(
          'Aguardando clientes...',
        );
        console.log(
          `Conexão estabilizada em ${new Date(ultimaConexaoAberta).toLocaleString('pt-BR')}.`,
        );
        console.log('');

        iniciarBuscaDeSaidas();
      }

      if (
        connection === 'close'
      ) {
        pararBuscaDeSaidas();
        sockAtual = null;

        const erro =
          lastDisconnect?.error;

        const statusCode =
          erro instanceof Boom
            ? erro.output
                ?.statusCode
            : undefined;

        if (
          statusCode ===
          DisconnectReason.loggedOut
        ) {
          console.log('');
          console.log(
            'WhatsApp recusou a sessão anterior.',
          );

          try {
            fs.rmSync(
              DIRETORIO_AUTH,
              {
                recursive: true,
                force: true,
              },
            );

            fs.mkdirSync(
              DIRETORIO_AUTH,
              {
                recursive: true,
              },
            );

            console.log(
              'Sessão inválida removida. Gerando um novo código...',
            );
          } catch (erroLimpeza) {
            console.error(
              'Falha ao limpar a sessão inválida:',
              erroLimpeza?.message ?? erroLimpeza,
            );
          }

          agendarConexao(
            new Error('Sessão do WhatsApp inválida.'),
            3000,
          );

          return;
        }

        console.log('');
        console.log(
          'Conexão caiu. Reconectando...',
        );

        agendarConexao(
          erro ?? new Error('Conexão com o WhatsApp encerrada.'),
          3000,
        );
      }
    },
  );
}

iniciarConexao();

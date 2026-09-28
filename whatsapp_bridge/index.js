import fs from 'node:fs';
import path from 'node:path';

import makeWASocket, {
  DisconnectReason,
  useMultiFileAuthState,
} from '@whiskeysockets/baileys';

import { Boom } from '@hapi/boom';
import qrcode from 'qrcode-terminal';

const BACKEND = process.env.BACKEND_URL || 'http://127.0.0.1:8080';

const ARQUIVO_ENV = path.resolve('../backend/.env');
const ARQUIVO_CONTATOS = path.resolve(
  process.env.BRIDGE_CONTACTS_PATH || './bridge_contacts.json',
);

let token = null;
let sockAtual = null;
let timerSaidas = null;
let processandoSaidas = false;
let timerReconexao = null;

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

  const dados = await resposta.json();

  if (!resposta.ok || !dados.token) {
    throw new Error(
      dados.erro ?? 'Falha ao autenticar no backend.',
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

  contatos[telefone] = jidPrincipal;

  salvarContatos();

  return {
    telefone,
    jid: jidPrincipal,
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

    await sockAtual.sendMessage(
      jid,
      {
        text: texto,
      },
    );

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

    await sockAtual.sendMessage(
      jid,
      {
        text: texto,
      },
    );

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
      process.env.WHATSAPP_AUTH_PATH || './auth_info',
    );

  const sock = makeWASocket({
    auth: state,
    markOnlineOnConnect: false,
    syncFullHistory: false,
  });

  sockAtual = sock;

  sock.ev.on(
    'creds.update',
    saveCreds,
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
        await processarEntrada(msg);
      }
    },
  );

  sock.ev.on(
    'connection.update',
    ({
      connection,
      lastDisconnect,
      qr,
    }) => {
      if (qr) {
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
        console.log('');

        iniciarBuscaDeSaidas();
      }

      if (
        connection === 'close'
      ) {
        pararBuscaDeSaidas();

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
            'WhatsApp desconectado.',
          );
          console.log(
            'Apague auth_info e conecte novamente.',
          );

          return;
        }

        console.log('');
        console.log(
          'Conexão caiu. Reconectando...',
        );

        if (timerReconexao) {
          clearTimeout(
            timerReconexao,
          );
        }

        timerReconexao =
          setTimeout(() => {
            conectar().catch(
              console.error,
            );
          }, 3000);
      }
    },
  );
}

conectar().catch((erro) => {
  console.error('');
  console.error(
    'ERRO AO INICIAR PONTE:',
  );
  console.error(
    erro.message ?? erro,
  );
});

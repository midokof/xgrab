// Extrait le planificateur HLS du litteral Swift et l'exerce dans Node.
//
// But : le script part en production dans un WKWebView ou l'on ne peut pas
//instrumenter. On verifie donc ici l'analyse pure (URL, attributs, cles,
//byterange), qui est la partie qui casse silencieusement.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..');
const SOURCE = path.join(ROOT, 'ios', 'App', 'PageScript.swift');

function extractPlanner() {
  const text = fs.readFileSync(SOURCE, 'utf8');
  const start = text.indexOf('static let hlsPlanner: String = {');
  if (start === -1) throw new Error('hlsPlanner introuvable');
  const open = text.indexOf('return """', start);
  const close = text.indexOf('"""', open + 'return """'.length);
  if (open === -1 || close === -1) throw new Error('litteral introuvable');

  const body = text.slice(open + 'return """'.length, close);
  if (body.indexOf('\\(') !== -1) {
    throw new Error('le script contient une interpolation Swift : extraction ambigue');
  }
  // Dans un litteral Swift, "\\" est un antislash. C'est la seule echappement
  // present ici.
  return body.replace(/\\\\/g, '\\');
}

// ---------------------------------------------------------------- scenarios

const MASTER = [
  '#EXTM3U',
  '#EXT-X-VERSION:3',
  '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"',
  '360/index.m3u8',
  '#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720',
  '720/index.m3u8?token=abc',
  '',
].join('\n');

const MEDIA_TS = [
  '#EXTM3U',
  '#EXT-X-VERSION:3',
  '#EXT-X-TARGETDURATION:6',
  '#EXT-X-MEDIA-SEQUENCE:42',
  '#EXT-X-KEY:METHOD=AES-128,URI="../keys/key.bin"',
  '#EXTINF:6.006,',
  'seg-42.ts',
  '#EXTINF:6.006,',
  'seg-43.ts',
  '#EXTINF:4.5,un titre avec, une virgule',
  'seg-44.ts',
  '#EXTINF:6.0,',
  '#EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.net/k2.bin",IV=0x0123456789ABCDEF0123456789ABCDEF',
  'seg-45.ts',
  '#EXT-X-ENDLIST',
  '',
].join('\n');

const MEDIA_FMP4 = [
  '#EXTM3U',
  '#EXT-X-MAP:URI="init.mp4"',
  '#EXTINF:4.0,',
  'seg-1.m4s',
  '#EXTINF:4.0,',
  'seg-2.m4s',
  '#EXT-X-ENDLIST',
  '',
].join('\n');

const MEDIA_BYTERANGE = [
  '#EXTM3U',
  '#EXT-X-KEY:METHOD=AES-128,URI="k.bin"',
  '#EXT-X-BYTERANGE:75232@0',
  '#EXTINF:4.0,',
  'all.ts',
  '#EXT-X-BYTERANGE:82112',
  '#EXTINF:4.0,',
  'all.ts',
  '#EXT-X-DISCONTINUITY',
  '#EXT-X-BYTERANGE:1000',
  '#EXTINF:4.0,',
  'all.ts',
  '#EXT-X-ENDLIST',
  '',
].join('\n');

const KEY_BYTES = Buffer.from('0123456789abcdef', 'utf8'); // 16 octets

const ROUTES = {
  'https://cdn.example.net/hls/master.m3u8': MASTER,
  'https://cdn.example.net/hls/360/index.m3u8': MEDIA_TS,
  'https://cdn.example.net/hls/720/index.m3u8?token=abc': MEDIA_TS,
  'https://www.example.com/hls/master.m3u8': MASTER,
  'https://www.example.com/hls/360/index.m3u8': MEDIA_TS,
  'https://www.example.com/hls/720/index.m3u8?token=abc': MEDIA_TS,
  'https://www.example.com/hls/keys/key.bin': null,
  'https://keys.example.net/k2.bin': null, // binaire
  'https://cdn.example.net/hls/keys/key.bin': null,
  'https://cdn.example.net/keys/k.bin': null,
  'https://cdn.example.net/hls/init.mp4': null,
  'https://cdn.example.net/hls/seg-42.ts': null,
  'https://cdn.example.net/hls/seg-43.ts': null,
  'https://cdn.example.net/hls/seg-44.ts': null,
  'https://cdn.example.net/hls/seg-45.ts': null,
  'https://cdn.example.net/hls/seg-1.m4s': null,
  'https://cdn.example.net/hls/seg-2.m4s': null,
  'https://cdn.example.net/hls/all.ts': null,
  'https://cdn.example.net/hls/media.m3u8': MEDIA_BYTERANGE,
  'https://cdn.example.net/hls/fmp4.m3u8': MEDIA_FMP4,
};

const fetchLog = [];

function makeFetch(failFor) {
  return function (url) {
    fetchLog.push(url);
    if (failFor && failFor.has(url)) {
      return Promise.resolve({ ok: false, status: 403, text: async () => '', arrayBuffer: async () => new ArrayBuffer(0) });
    }
    const body = ROUTES[url];
    if (body === undefined) {
      return Promise.resolve({ ok: false, status: 404, text: async () => '', arrayBuffer: async () => new ArrayBuffer(0) });
    }
    const payload = body === null ? KEY_BYTES : Buffer.from(body, 'utf8');
    return Promise.resolve({
      ok: true,
      status: 200,
      text: async () => payload.toString('utf8'),
      arrayBuffer: async () => payload.buffer.slice(payload.byteOffset, payload.byteOffset + payload.byteLength),
    });
  };
}

function loadPlanner(fetchImpl) {
  const posted = [];
  const context = {
    window: {},
    location: { href: 'https://www.example.com/watch/1' },
    fetch: fetchImpl,
    Promise,
    URL,
    String,
    Array,
    Object,
    Math,
    parseInt,
    parseFloat,
    btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
    Uint8Array,
    Error,
  };
  context.window.webkit = {
    messageHandlers: { xgrab: { postMessage: (p) => posted.push(p) } },
  };
  context.globalThis = context;
  vm.createContext(context);
  vm.runInContext(extractPlanner(), context);
  return { planner: context.window.__xgrabHLS, posted };
}

// ------------------------------------------------------------------ attente

let failures = 0;
function check(label, condition, detail) {
  if (condition) {
    console.log('  ok   ' + label);
  } else {
    failures++;
    console.log('  FAIL ' + label + (detail ? '  ->  ' + detail : ''));
  }
}

function eq(label, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  check(label, a === e, 'attendu ' + e + ', obtenu ' + a);
}

async function main() {
  console.log('\n== 1. manifeste maitre, variante chiffree AES-128 ==');
  let harness = loadPlanner(makeFetch(null));
  let planner = harness.planner;
  let plan = await planner.plan('https://cdn.example.net/hls/master.m3u8', 720);

  eq('variante 720p retenue', plan.variant, 'https://cdn.example.net/hls/720/index.m3u8?token=abc');
  eq('hauteur', plan.height, 720);
  check('chiffrement detecte', plan.encrypted === true);
  eq('nombre de segments', plan.urls.length, 4);

  eq('segment 0 resolu contre la variante', plan.urls[0],
     'https://cdn.example.net/hls/720/seg-42.ts');
  eq('sequence issue de MEDIA-SEQUENCE', plan.seq[0], 42);
  eq('IV absent -> natif le deduit', plan.iv[0], '');
  eq('toutes les cles de la 1re cle', plan.key, [0, 0, 0, 1]);
  eq('cle 0 lue depuis la page',
     plan.keys[0], KEY_BYTES.toString('base64'));
  eq('URI de cle relatif resolu en cascade', plan.keyUris[0],
     'https://cdn.example.net/hls/keys/key.bin');
  eq('cle 1 explicite', plan.keyUris[1], 'https://keys.example.net/k2.bin');
  eq('IV explicite conserve tel quel', plan.iv[3],
     '0x0123456789ABCDEF0123456789ABCDEF');
  eq('duree totale (virgule du titre ignoree)',
     Math.round(plan.duration * 1000) / 1000, 22.512);

  console.log('\n== 2. resolution en cascade depuis une page differente ==');
  planner = loadPlanner(makeFetch(null)).planner;
  plan = await planner.plan('/hls/master.m3u8', 360);
  eq('URL relative a la page', plan.manifest, 'https://www.example.com/hls/master.m3u8');
  eq('variante la plus proche', plan.height, 360);

  console.log('\n== 3. pas de hauteur demandee -> meilleure variante ==');
  planner = loadPlanner(makeFetch(null)).planner;
  plan = await planner.plan('https://cdn.example.net/hls/master.m3u8', 0);
  eq('meilleure variante', plan.height, 720);

  console.log('\n== 4. segments fMP4 (EXT-X-MAP) ==');
  planner = loadPlanner(makeFetch(null)).planner;
  plan = await planner.plan('https://cdn.example.net/hls/fmp4.m3u8', 0);
  eq('segment initial', plan.initUrl, 'https://cdn.example.net/hls/init.mp4');
  eq('pas de chiffrement', plan.encrypted, false);
  eq('aucune cle', plan.keys.length, 0);
  eq('indices de cle a -1', plan.key, [-1, -1]);

  console.log('\n== 5. EXT-X-BYTERANGE avec enchainement et discontinuite ==');
  planner = loadPlanner(makeFetch(null)).planner;
  plan = await planner.plan('https://cdn.example.net/hls/media.m3u8', 0);
  eq('offset explicite', plan.range[0], '0:75232');
  eq('offset enchaine sur le segment precedent', plan.range[1], '75232:82112');
  eq('DISCONTINUITY reinitialise le curseur', plan.range[2], '0:1000');

  console.log('\n== 6. methode non geree par CommonCrypto ==');
  planner = loadPlanner(makeFetch(null)).planner;
  const sampleAES = ['#EXTM3U', '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="k.bin"',
                     '#EXTINF:4.0,', 'a.ts', ''].join('\n');
  ROUTES['https://cdn.example.net/hls/s.m3u8'] = sampleAES;
  plan = await planner.plan('https://cdn.example.net/hls/s.m3u8', 0);
  eq('methode declaree', plan.keyMethods, ['SAMPLE-AES']);
  eq('aucune cle telechargee pour SAMPLE-AES', plan.keys, ['']);

  console.log('\n== 7. CDN qui refuse la cle ==');
  planner = loadPlanner(makeFetch(new Set(['https://cdn.example.net/hls/keys/key.bin']))).planner;
  plan = await planner.plan('https://cdn.example.net/hls/master.m3u8', 720);
  check('le plan reste complet', plan.urls.length === 4);
  eq('cle laissee vide pour le repli natif', plan.keys, ['', KEY_BYTES.toString('base64')]);

  console.log('\n== 8. manifeste mort ==');
  planner = loadPlanner(makeFetch(null)).planner;
  let threw = null;
  try {
    await planner.plan('https://cdn.example.net/inexistant.m3u8', 0);
  } catch (e) {
    threw = e.message;
  }
  check('le refus remonte en erreur', threw !== null && /HTTP 404/.test(threw), String(threw));

  console.log('\n== 9. report() : le bouton de la page doit parler ==');
  // Regression : report() ne postait qu'en cas d'echec. Le clic sur un flux
  // chiffre reussi ne produisait donc aucun message, et le cas "hls-plan" de
  // BrowserModel n'etait atteint par personne.
  harness = loadPlanner(makeFetch(null));
  await harness.planner.report('https://cdn.example.net/hls/master.m3u8', 720);
  eq('un message emis', harness.posted.length, 1);
  const sent = harness.posted[0];
  eq('evenement', sent.event, 'hls-plan');
  eq('variant', sent.variant, 'https://cdn.example.net/hls/720/index.m3u8?token=abc');
  eq('segments', sent.urls.length, 4);
  eq('cle transmise', sent.keys[0], KEY_BYTES.toString('base64'));
  check('aucun segment dans le message',
        JSON.stringify(sent).length < 8 * 1024, String(JSON.stringify(sent).length));

  console.log('\n== 10. report() : l\'echec doit aussi parler ==');
  harness = loadPlanner(makeFetch(null));
  await harness.planner.report('https://cdn.example.net/inexistant.m3u8', 0);
  eq('un message emis', harness.posted.length, 1);
  eq('evenement', harness.posted[0].event, 'hls-error');
  eq('url transmise pour le repli', harness.posted[0].url,
     'https://cdn.example.net/inexistant.m3u8');
  check('raison lisible', /HTTP 404/.test(harness.posted[0].message),
        harness.posted[0].message);

  console.log('\n== 11. la page ne telecharge que le plan, jamais un segment ==');
// C'est l'invariant de l'architecture : si le script recuperait un segment,
// on ferait transiter des dizaines de Mo par postMessage et on tuerait le
// processus de contenu du WKWebView.
  fetchLog.length = 0;
  planner = loadPlanner(makeFetch(null)).planner;
  await planner.plan('https://cdn.example.net/hls/master.m3u8', 720);
  const segments = fetchLog.filter((u) => /\.(ts|m4s)(\?|$)/.test(u));
  eq('aucun segment demande', segments, []);
  eq('le maitre une fois', fetchLog.filter(
    (u) => u === 'https://cdn.example.net/hls/master.m3u8').length, 1);
  eq('la variante une fois', fetchLog.filter(
    (u) => u === 'https://cdn.example.net/hls/720/index.m3u8?token=abc').length, 1);
  eq('la cle relative une fois', fetchLog.filter(
    (u) => u === 'https://cdn.example.net/hls/keys/key.bin').length, 1);
  eq('la cle absolue une fois', fetchLog.filter(
    (u) => u === 'https://keys.example.net/k2.bin').length, 1);
  // maitre + variante + deux cles distinctes. Rien de plus.
  eq('rien d\'autre', fetchLog.length, 4);

  console.log('\n== 12. taille du plan ==');
  const big = [];
  for (let i = 0; i < 400; i++) big.push('#EXTINF:6.0,', 'seg-' + i + '.ts');
  ROUTES['https://cdn.example.net/hls/long.m3u8'] =
    ['#EXTM3U', '#EXT-X-KEY:METHOD=AES-128,URI="k.bin"'].concat(big, ['#EXT-X-ENDLIST', '']).join('\n');
  planner = loadPlanner(makeFetch(null)).planner;
  plan = await planner.plan('https://cdn.example.net/hls/long.m3u8', 0);
  const payload = JSON.stringify(plan);
  check('400 segments lists', plan.urls.length === 400, String(plan.urls.length));
  check('plan de ' + Math.round(payload.length / 1024) + ' Ko, reste raisonnable',
        payload.length < 120 * 1024, String(payload.length));

  console.log('\n' + (failures === 0 ? 'TOUT PASSE' : failures + ' ECHEC(S)'));
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
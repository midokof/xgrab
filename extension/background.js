/* Service worker : relaie les liens du bouton vers l'application locale. */

const DEFAULTS = { port: 38471, token: "" };
const HOST = "com.xgrab.app";
let cache = null;

/* Le port et le jeton sont ecrits par XGrab dans config.json, a cote de ce
   fichier. On les lit une fois puis on les garde en memoire. */
async function config() {
  if (cache) return cache;
  try {
    const response = await fetch(chrome.runtime.getURL("config.json"), {
      cache: "no-store",
    });
    if (response.ok) {
      const data = await response.json();
      cache = { port: data.port || DEFAULTS.port, token: data.token || "" };
      return cache;
    }
  } catch (err) {
    /* fichier absent : XGrab n'a pas encore demarre */
  }
  try {
    const stored = await chrome.storage.local.get(DEFAULTS);
    cache = { port: stored.port || DEFAULTS.port, token: stored.token || "" };
  } catch (err) {
    cache = { ...DEFAULTS };
  }
  return cache;
}

async function send(urls, referer) {
  const { port, token } = await config();
  if (!urls || !urls.length) return { ok: false, error: "aucun lien" };

  /* XGrab est ouvert : on passe par le serveur local, c'est instantane. */
  if (token) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/add`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-XGrab-Token": token },
        body: JSON.stringify({ urls, referer: referer || "" }),
      });
      const data = await response.json().catch(() => ({}));
      if (response.ok) {
        return { ok: true, added: data.added || urls.length, started: false };
      }
    } catch (err) {
      /* serveur injoignable : on tente de lancer l'application */
    }
  }

  /* XGrab est ferme : le navigateur demarre l'exe via native messaging. */
  return startApp(urls, referer);
}

function startApp(urls, referer) {
  return new Promise((resolve) => {
    let port;
    try {
      port = chrome.runtime.connectNative(HOST);
    } catch (err) {
      resolve({ ok: false, error: "hote natif absent" });
      return;
    }

    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      try { port.disconnect(); } catch (err) { /* deja ferme */ }
      resolve(value);
    };

    port.onMessage.addListener((reply) => {
      if (reply && reply.ok) {
        finish({ ok: true, added: reply.added || urls.length, started: !!reply.started });
      } else {
        finish({ ok: false, error: (reply && reply.error) || "echec du lancement" });
      }
    });

    port.onDisconnect.addListener(() => {
      if (!settled) finish({ ok: false, error: "hote natif deconnecte" });
    });

    port.postMessage({ urls, referer: referer || "" });
  });
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || message.type !== "xgrab-add") return;
  send(urlsFor(message.urls), message.referer).then(sendResponse);
  return true;
});

/* Une URL blob: n'est pas telechargeable, on refuse proprement. */
function urlsFor(list) {
  if (!Array.isArray(list)) return [];
  return list.filter((u) => typeof u === "string" && /^https?:\/\//i.test(u));
}

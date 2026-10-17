/* XGrab iOS : relaie les liens vers XGrab sur le PC du reseau local.
 *
 * Contraintes Safari iOS :
 *  - pas de demarrage de processus (connectNative ne sert qu'a joindre l'app conteneur)
 *  - le PC est designe par son adresse IP locale, pas 127.0.0.1
 */

const HOST_APP = "com.xgrab.app";
const DEFAULTS = { host: "", port: 38471, token: "" };

let cache = null;
let cachedAt = 0;
const TTL_MS = 15000;

/* L'app conteneur (SwiftUI) connait l'adresse du PC et le jeton.
   Si elle ne repond pas encore, on retombe sur le stockage local. */
async function config() {
  const now = Date.now();
  if (cache && now - cachedAt < TTL_MS) return cache;

  let found = null;
  try {
    const reply = await chrome.runtime.sendNativeMessage(HOST_APP, { type: "xgrab-config" });
    if (reply && reply.ok && reply.host) {
      found = {
        host: String(reply.host),
        port: Number(reply.port) || DEFAULTS.port,
        token: String(reply.token || ""),
      };
    }
  } catch (err) {
    /* app conteneur indisponible */
  }

  if (!found) {
    try {
      const stored = await chrome.storage.local.get(["host", "port", "token"]);
      if (stored && stored.host) {
        found = {
          host: String(stored.host),
          port: Number(stored.port) || DEFAULTS.port,
          token: String(stored.token || ""),
        };
      }
    } catch (err) {
      /* stockage indisponible */
    }
  }

  cache = found || { ...DEFAULTS, missing: true };
  cachedAt = now;
  return cache;
}

async function send(urls, referer) {
  if (!urls || !urls.length) return { ok: false, error: "aucun lien" };

  /* 1. L'app conteneur telecharge directement sur l'iPhone. */
  try {
    const reply = await chrome.runtime.sendNativeMessage(HOST_APP, {
      type: "xgrab-add",
      urls: urls,
      referer: referer || "",
    });
    if (reply && reply.ok) {
      return { ok: true, added: reply.added || urls.length, started: true };
    }
  } catch (err) {
    /* app conteneur indisponible : on bascule sur le PC */
  }

  /* 2. Repli : le PC dechote les liens comme la version desktop. */
  const cfg = await config();
  if (cfg.missing || !cfg.host) {
    return { ok: false, error: "Ni l'app ni un PC ne repondent" };
  }

  const base = `http://${cfg.host}:${cfg.port}`;
  try {
    const response = await fetch(`${base}/add`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-XGrab-Token": cfg.token,
      },
      body: JSON.stringify({ urls, referer: referer || "" }),
    });
    const data = await response.json().catch(() => ({}));
    if (response.ok) {
      return { ok: true, added: data.added || urls.length, started: false };
    }
    return { ok: false, error: `PC refuse la requete (${response.status})` };
  } catch (err) {
    return { ok: false, error: `PC injoignable sur ${base}` };
  }
}

async function ping() {
  const cfg = await config();
  if (cfg.missing || !cfg.host) return { ok: false, error: "non configure" };
  const base = `http://${cfg.host}:${cfg.port}`;
  try {
    const response = await fetch(`${base}/ping`, {
      headers: { "X-XGrab-Token": cfg.token },
    });
    return { ok: response.ok, host: cfg.host, port: cfg.port };
  } catch (err) {
    return { ok: false, error: `injoignable sur ${base}`, host: cfg.host, port: cfg.port };
  }
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message) return undefined;

  if (message.type === "xgrab-add") {
    send(urlsFor(message.urls), message.referer).then(sendResponse);
    return true;
  }

  if (message.type === "xgrab-ping") {
    ping().then(sendResponse);
    return true;
  }

  /* L'app conteneur peut forcer la relecture de la config apres edition. */
  if (message.type === "xgrab-invalidate") {
    cache = null;
    cachedAt = 0;
    sendResponse({ ok: true });
    return true;
  }

  return undefined;
});

/* Une URL blob: n'est pas telechargeable, on refuse proprement. */
function urlsFor(list) {
  if (!Array.isArray(list)) return [];
  return list.filter((u) => typeof u === "string" && /^https?:\/\//i.test(u));
}
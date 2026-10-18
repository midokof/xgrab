import Foundation

/// Scripts injectes dans chaque page.
///
/// Regles absolues, apprises a chaque bug :
///
///  1. **Aucun `MutationObserver`.** Observer un document que l'on modifie
///     soi-meme cree une boucle : l'insertion du bouton relance la sonde, qui
///     recree le bouton... La page vibre et aucun clic n'aboutit.
///
///  2. **Aucune fonction native modifiee.** `fetch`, `XMLHttpRequest` et
///     `window.open` sont verifies par les scripts anti-publicite. Des qu'ils
///     detectent la modification, ils couvrent la page et bloquent le
///     defilement : pire que les publicites. Les popups sont bloques
///     nativement par le delegate SwiftUI, sans trace dans la page.
///
///  3. **Une seule source de verite par page.** La sonde interroge, decide et
///     agit ; le bloqueur se contente de masquer et nettoyer.
enum PageScript {

    /// Regies publicitaires. Volontairement strictes : aucun selecteur
    /// generique ne doit masquer un lecteur.
    static let adSelectors = [
        "iframe[id^=\"aswift_\"]",
        "iframe[src*=\"doubleclick\"]",
        "iframe[src*=\"googlesyndication\"]",
        "iframe[src*=\"2mdn\"]",
        "[id^=\"div-gpt-ad\"]",
        "[id^=\"ad-slot\"]",
        "[id^=\"ad_\"]",
        "[id^=\"ad-\"]",
        "[id^=\"ads-\"]",
        "[id^=\"banner\"]",
        "[id*=\"ad-container\"]",
        "[id*=\"ad-wrapper\"]",
        "[id*=\"adbanner\"]",
        "[id*=\"adbox\"]",
        "[class^=\"ad-\"]",
        "[class^=\"ad_\"]",
        "[class^=\"ads-\"]",
        "[class^=\"ads_\"]",
        "[class^=\"advert\"]",
        "[class*=\"ad-container\"]",
        "[class*=\"ad-wrapper\"]",
        "[class*=\"ad-slot\"]",
        "[class*=\"ad-placement\"]",
        "[class*=\"adsbygoogle\"]",
        "[class*=\"banner-ad\"]",
        "[class*=\"popup-under\"]",
        "[class*=\"sticky-footer\"]",
        "[class*=\"consent-overlay\"]",
    ]

    static let adHosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "google-analytics.com", "googletagmanager.com", "adservice.google",
        "adnxs.com", "rubiconproject.com", "pubmatic.com", "openx.net",
        "criteo.com", "taboola.com", "outbrain.com", "adroll.com",
        "casalemedia.com", "smartadserver.com", "adsystem.com",
        "popads.net", "propellerads.com", "mgid.com", "adsterra.com",
        "hilltopads.net", "poperblock.com", "adskeeper.com", "gumgum.com",
        "2mdn.net", "inmobi.com", "smaato.net",
    ]

    /// Couche 1 : masquer les encarts, retirer les scripts de regies et les
    /// superpositions de type popunder.
    static let shield: String = {
        let hosts = adHosts
            .map { $0.replacingOccurrences(of: ".", with: "\\.") }
            .joined(separator: "|")
        let css = adSelectors.joined(separator: ",")

        return """
        (function () {
          try {
            var HOSTS = new RegExp('(^|\\\\.)($hosts)(:|$)|($hosts)', 'i');
            var state = window.__xgrabShield || { on: true };
            window.__xgrabShield = state;

            function ensureStyle() {
              if (state.on) {
                if (document.getElementById('xgrab-shield')) return;
                var css = document.createElement('style');
                css.id = 'xgrab-shield';
                css.textContent = '$css{display:none !important;}';
                var root = document.head || document.documentElement;
                if (root) root.appendChild(css);
              } else {
                var old = document.getElementById('xgrab-shield');
                if (old) old.remove();
              }
            }

            // Retirer un <script> deja insere annule son chargement.
            function sweep() {
              if (!state.on || !document.querySelectorAll) return;

              var nodes = document.querySelectorAll('script[src],iframe[src]');
              for (var i = 0; i < nodes.length; i++) {
                var src = nodes[i].src || nodes[i].getAttribute('src') || '';
                if (src && HOSTS.test(src)) nodes[i].remove();
              }

              var overlays = document.querySelectorAll(
                '[class*="popunder"],[id*="popunder"],' +
                '[class*="onload-modal"],[id*="popup-overlay"],' +
                '[id*="modal-overlay"]');
              for (var j = 0; j < overlays.length; j++) overlays[j].remove();
            }

            // Une seule horloge pour tout : pas d'observateur, donc aucune
            // reaction en chaine aux mutations de la page.
            setInterval(function () { ensureStyle(); sweep(); }, 1500);
            document.addEventListener('DOMContentLoaded', sweep, false);
            ensureStyle();
            sweep();
          } catch (e) {}
        })();
        """
    }()

    /// Couche 2 : trouver la video de contenu, y poser un bouton, et
    /// transmettre le flux a l'app.
    static let probe: String = {
        let adPath = "(^|[\\\\/_.-])(ad|ads|adserver|adframe|advert|advertising|" +
                     "banner|preroll|midroll|rollover|spot|promo|teaser|roomad|" +
                     "sponsor|partner|thumb|thumbs)([\\\\/_.-]|$)"
        let adMark = "(ad-|ads-|ad_|ads_|adbox|adslot|adunit|advert|banner|" +
                     "preroll|midroll|sponsor|partner|commercial|promo)"

        return """
        (function () {
          try {
            if (window.__xgrab) return;

            var SEG = /(videoplayback|\\.mpd|\\.m3u8|migration\\/)/i;
            var AD_PATH = /$adPath/i;
            var AD_MARK = /$adMark/;
            var MEDIA = /\\.(m3u8|mp4|m4v|webm|mov|mkv)(\\?|#|$)/i;

            var recent = [];
            var button = null;
            var buttonFor = null;
            var target = null;   // lecteur retenu : ne change plus

            function post(payload) {
              try {
                window.webkit.messageHandlers.xgrab.postMessage(payload);
              } catch (e) {}
            }

            try {
              new PerformanceObserver(function (list) {
                for (var i = 0; i < list.getEntries().length; i++) {
                  var name = list.getEntries()[i].name;
                  if (!name || !MEDIA.test(name)) continue;
                  var clean = name.split('#')[0];
                  var at = recent.findIndex(function (r) { return r.url === clean; });
                  if (at !== -1) recent.splice(at, 1);
                  recent.unshift({ url: clean, at: Date.now() });
                  if (recent.length > 10) recent.pop();
                }
              }).observe({ type: 'resource', buffered: true });
            } catch (e) {}

            // Un blob: n'est pas telechargeable par l'app.
            function usable(u) {
              return !!u && /^https?:\\/\\//i.test(u) && !/^blob:/i.test(u);
            }

            function sourceOf(video) {
              var direct = video.currentSrc || video.src || '';
              if (usable(direct)) return direct.split('#')[0];
              var nodes = video.querySelectorAll('source[src]');
              for (var i = 0; i < nodes.length; i++) {
                var u = nodes[i].getAttribute('src') || '';
                if (usable(u)) return u.split('#')[0];
              }
              // Lecteur MSE : currentSrc vaut "blob:", on reprend alors la
              // derniere URL reelle vue dans les requetes du document.
              for (var j = 0; j < recent.length; j++) {
                if (Date.now() - recent[j].at < 45000) return recent[j].url;
              }
              return '';
            }

            function adContext(node) {
              var depth = 0;
              while (node && depth < 6 && node !== document.body) {
                var cls = node.className;
                var sig = ((cls && cls.baseVal !== undefined) ? cls.baseVal : (cls || '')) +
                          ' ' + (node.id || '');
                if (AD_MARK.test(String(sig).toLowerCase())) return true;
                node = node.parentElement;
                depth++;
              }
              return false;
            }

            function describe(video) {
              var url = sourceOf(video);
              var box = video.getBoundingClientRect();
              var area = Math.max(0, box.width) * Math.max(0, box.height);

              var ad = false;
              if (url && AD_PATH.test(url)) ad = true;
              if (adContext(video)) ad = true;
              if (video.loop) ad = true;
              var d = video.duration;
              if (isFinite(d) && d > 0 && d < 30) ad = true;

              // Memesans marqueur dans l'URL, une publicite se distingue par
              // son comportement : elle demarre seule, sans son, et se repete.
              var silent = video.muted && video.autoplay;
              if (silent) ad = true;

              var score = area;
              if (ad) score *= 0.05;
              if (silent) score *= 0.2;

              return {
                url: url,
                w: Math.round(box.width),
                h: Math.round(box.height),
                ad: ad,
                score: Math.round(score),
                segmented: SEG.test(url || '')
              };
            }

            // Ancetre ou un bouton peut etre pose SOUS la video, jamais
            // dessus. Un lecteur absolu, ou un conteneur de sa taille exacte,
            // ne laisse aucune place : on remonte.
            function slotFor(video) {
              var rect = video.getBoundingClientRect();
              var node = video;
              var host = video.parentElement;
              var depth = 0;

              while (host && host !== document.body && depth < 10) {
                var hs = window.getComputedStyle(host);
                var ns = window.getComputedStyle(node);
                var hr = host.getBoundingClientRect();

                var floating = ns.position === 'absolute' || ns.position === 'fixed';
                var hostFloat = hs.position === 'absolute' || hs.position === 'fixed';
                var clipped = hs.overflow === 'hidden' || hs.overflowY === 'hidden';
                var tight = hr.height <= rect.height + 12 || hr.width <= rect.width + 12;

                if (!floating && !hostFloat && !clipped && !tight) {
                  return { host: host, node: node };
                }
                node = host;
                host = host.parentElement;
                depth++;
              }
              return { host: host || document.body, node: node };
            }

            function buildButton(video) {
              var box = document.createElement('div');
              box.setAttribute('data-xgrab-ui', '1');
              box.style.cssText = 'margin:12px 0;display:block;width:max-content;' +
                                  'max-width:100%;font-family:-apple-system,system-ui,sans-serif;' +
                                  'position:relative;z-index:2147483000;';

              var btn = document.createElement('button');
              btn.type = 'button';
              btn.setAttribute('data-xgrab-ui', '1');
              btn.style.cssText = [
                'display:inline-flex', 'align-items:center', 'gap:8px',
                'padding:10px 20px', 'border:0', 'border-radius:999px',
                'background:linear-gradient(135deg,#4d90fe,#2f5bb7)',
                'color:#fff', 'font-size:14px', 'font-weight:700',
                'cursor:pointer', 'box-shadow:0 6px 18px rgba(77,144,254,.45)',
                'position:relative', 'z-index:2147483000', 'pointer-events:auto'
              ].join(';');

              var text = document.createElement('span');
              text.textContent = 'Télécharger';
              btn.appendChild(text);

              btn.addEventListener('click', function (event) {
                event.preventDefault();
                event.stopPropagation();
                var url = sourceOf(video);
                if (!url) return;
                post({
                  event: 'download',
                  url: url,
                  height: video.videoHeight || 0,
                  page: location.href,
                  title: (document.title || '').trim()
                });
              }, true);

              box.appendChild(btn);
              return box;
            }

            function place(video) {
              if (!sourceOf(video)) { drop(); return; }

              // Pose une seule fois. Si la page retire le bouton, le tour
              // suivant le remet. Aucun deplacer : la page resterait instable.
              if (button && button.isConnected && buttonFor === video) {
                var span = button.querySelector('span');
                var h = video.videoHeight || 0;
                if (span) span.textContent = 'Télécharger' + (h > 0 ? ' ' + h + 'p' : '');
                return;
              }

              drop();
              var slot = slotFor(video);
              button = buildButton(video);
              slot.host.insertBefore(button, slot.node.nextSibling);
              buttonFor = video;
              post({ event: 'placed', url: sourceOf(video) });
            }

            function drop() {
              if (button && button.parentElement) button.remove();
              button = null;
              buttonFor = null;
            }

            function poll() {
              var videos = Array.from(document.querySelectorAll('video'));
              if (!videos.length) {
                drop(); target = null;
                post({ event: 'scan', media: null, list: [], empty: true });
                return;
              }

              var entries = [];
              for (var i = 0; i < videos.length; i++) {
                var d = describe(videos[i]);
                if (d.url) entries.push({ v: videos[i], d: d });
              }

              // Cible figee. Sur une page chargee de publicites, le « plus
              // grand lecteur » change plusieurs fois par seconde ; sans
              // verrou, le bouton est detruit puis recree sans arret.
              if (target && (!target.isConnected || !sourceOf(target))) target = null;

              if (!target) {
                var clean = entries.filter(function (e) { return !e.d.ad; });
                if (clean.length) {
                  clean.sort(function (a, b) { return b.d.score - a.d.score; });
                  target = clean[0].v;
                }
              }

              if (target) place(target); else drop();

              // Seuls les lecteurs de contenu remontent a l'app : proposer
              // une publicite comme telechargement n'aide personne.
              var shown = entries
                .filter(function (e) { return !e.d.ad; })
                .sort(function (a, b) { return b.d.score - a.d.score; })
                .map(function (e) { return e.d; })
                .slice(0, 8);

              var url = target ? sourceOf(target) : '';
              post({
                event: 'scan',
                media: url || null,
                list: shown,
                ads: entries.length - shown.length,
                target: url
              });
            }

            // Uniquement des evenements de lecture : pas d'observateur du DOM.
            ['play', 'playing', 'loadedmetadata', 'canplay', 'durationchange',
             'sourcechange', 'progress'].forEach(function (type) {
              document.addEventListener(type, poll, true);
            });

            window.__xgrab = poll;
            setInterval(poll, 1000);
            poll();
          } catch (e) {
            try {
              window.webkit.messageHandlers.xgrab.postMessage({
                event: 'failure', message: String(e && e.message ? e.message : e)
              });
            } catch (ignored) {}
          }
        })();
        """
    }()
}
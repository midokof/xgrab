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

    /// Planificateur HLS execute dans la page.
    ///
    /// C'est le seul endroit ou la reponse du CDN est acceptee telle qu'elle,
    /// avec les cookies et le `User-Agent` du lecteur : le manifeste **et la
    /// cle** sont donc lus ici, et places de la sont transmises a l'app. Les
    /// segments, eux, sont telecharges en natif par `HLSDownloader` : faire
    /// transiter des dizaines de Mo par `postMessage` tuerait le processus
    /// de contenu.
    ///
    /// Regles du script de page, inchangees : aucune fonction native
    /// modifiee, aucun observateur du DOM. Celui-ci n'ouvre des `fetch` que
    /// lorsqu'on lui demande un plan.
    ///
    /// L'analyse est volontairement la meme que celle de `HLSFetcher` :
    /// si les deux divergent, le repli natif produira un autre fichier que le
    /// chemin nominal.
    static let hlsPlanner: String = {
        return """
        (function () {
          if (window.__xgrabHLS) return;

          var SEG = /\\.m3u8/i;

          function post(payload) {
            try {
              window.webkit.messageHandlers.xgrab.postMessage(payload);
            } catch (e) {}
          }

          // URL() refuse une reference contenant un espace ou un dièse, que
          // des CDN produisent pourtant. Sans repli, la liste s'arrete au
          // premier segment et l'app recoit une adresse relative.
          function resolve(reference, base) {
            if (!reference) return '';
            try { return new URL(reference, base).href; } catch (e) {}
            try {
              var safe = reference.split(' ').join('%20').split('#').join('%23');
              return new URL(safe, base).href;
            } catch (e) {
              return '';
            }
          }

          // A=1,B="x,y",C=z : la virgule ne coupe pas dans les guillemets.
          function attributes(text) {
            var out = {};
            var key = '', value = '', quoted = false, readingKey = true;
            for (var i = 0; i < text.length; i++) {
              var ch = text.charAt(i);
              if (ch === '"') { quoted = !quoted; continue; }
              if (ch === ',' && !quoted) {
                out[key.replace(/^\\s+|\\s+$/g, '').toUpperCase()] =
                  value.replace(/^\\s+|\\s+$/g, '');
                key = ''; value = ''; readingKey = true;
                continue;
              }
              if (ch === '=' && readingKey && !quoted) { readingKey = false; continue; }
              if (readingKey) { key += ch; } else { value += ch; }
            }
            out[key.replace(/^\\s+|\\s+$/g, '').toUpperCase()] =
              value.replace(/^\\s+|\\s+$/g, '');
            return out;
          }

          function rows(source) {
            var lines = String(source).split(/\\r?\\n/);
            var out = [];
            for (var i = 0; i < lines.length; i++) {
              var line = lines[i].replace(/^\\s+|\\s+$/g, '');
              if (line) out.push(line);
            }
            return out;
          }

          function tail(line) { return line.slice(line.indexOf(':') + 1); }

          function read(url) {
            return fetch(url, { credentials: 'include', cache: 'no-store' })
              .then(function (response) {
                if (!response.ok) throw new Error('HTTP ' + response.status);
                return response.text();
              });
          }

          function toBase64(buffer) {
            var bytes = new Uint8Array(buffer);
            var out = '';
            for (var i = 0; i < bytes.length; i++) {
              out += String.fromCharCode(bytes[i]);
            }
            return btoa(out);
          }

          // Quatre details font echouer la plupart des lecteurs HLS :
          // l'URL d'un segment est relative au manifeste de variante ;
          // #EXTINF:6.006,titre porte une virgule ; un EXT-X-BYTERANGE sans
          // offset enchaine sur la fin du segment precedent de la meme
          // ressource ; EXT-X-DISCONTINUITY reinitialise ce curseur.
          function parseMedia(source, base) {
            var lines = rows(source);
            var parsed = { segments: [], keys: [], initUrl: '', initRange: '',
                           duration: 0, encrypted: false };
            var slots = {};
            var sequence = 0, pendingRange = '', cursors = {};
            var key = -1, iv = '';

            for (var i = 0; i < lines.length; i++) {
              var line = lines[i];

              if (line.indexOf('#EXT-X-MEDIA-SEQUENCE:') === 0) {
                sequence = parseInt(tail(line), 10) || 0;
                continue;
              }

              if (line.indexOf('#EXT-X-KEY:') === 0) {
                var declared = attributes(tail(line));
                var method = (declared.METHOD || 'NONE').toUpperCase();
                if (method === 'NONE') { key = -1; iv = ''; continue; }
                var uri = resolve(declared.URI || '', base);
                if (!uri) throw new Error('clé sans URI exploitable');
                parsed.encrypted = true;
                if (slots[uri] === undefined) {
                  slots[uri] = parsed.keys.length;
                  parsed.keys.push({ uri: uri, method: method, bytes: '' });
                }
                key = slots[uri];
                iv = declared.IV || '';
                continue;
              }

              if (line.indexOf('#EXT-X-MAP:') === 0) {
                var map = attributes(tail(line));
                var init = resolve(map.URI || '', base);
                if (init) {
                  parsed.initUrl = init;
                  parsed.initRange = map.BYTERANGE || '';
                }
                continue;
              }

              if (line.indexOf('#EXT-X-BYTERANGE:') === 0) {
                pendingRange = tail(line);
                continue;
              }

              if (line.indexOf('#EXTINF:') === 0) {
                parsed.duration += parseFloat(tail(line).split(',')[0]) || 0;
                continue;
              }

              if (line.indexOf('#EXT-X-DISCONTINUITY') === 0) {
                cursors = {};
                pendingRange = '';
                continue;
              }

              if (line.charAt(0) === '#') continue;

              var url = resolve(line, base);
              if (!url) continue;

              var range = '';
              if (pendingRange) {
                var bits = pendingRange.split('@');
                var length = parseInt(bits[0], 10) || 0;
                var start = bits.length > 1 ? (parseInt(bits[1], 10) || 0)
                                            : (cursors[url] || 0);
                if (length > 0) {
                  range = start + ':' + length;
                  cursors[url] = start + length;
                }
                pendingRange = '';
              }

              parsed.segments.push({ url: url, key: key, iv: iv,
                                     seq: sequence, range: range });
              sequence++;
            }

            if (!parsed.segments.length) throw new Error('aucun segment listé');
            return parsed;
          }

          function parseMaster(source, base) {
            var lines = rows(source);
            var found = [];
            var pending = null;

            for (var i = 0; i < lines.length; i++) {
              var line = lines[i];
              if (line.indexOf('#EXT-X-STREAM-INF') === 0) {
                pending = attributes(tail(line));
                continue;
              }
              if (!pending || !line || line.charAt(0) === '#') continue;

              var declared = pending;
              pending = null;
              var url = resolve(line, base);
              if (!url) continue;

              var size = (declared.RESOLUTION || '').toLowerCase().split('x');
              found.push({
                url: url,
                height: size.length === 2 ? (parseInt(size[1], 10) || 0) : 0,
                bandwidth: parseInt(
                  declared['AVERAGE-BANDWIDTH'] || declared.BANDWIDTH, 10) || 0
              });
            }
            return found;
          }

          function loadKeys(keys) {
            var jobs = [];
            for (var i = 0; i < keys.length; i++) {
              (function (entry) {
                if (entry.method !== 'AES-128') { entry.bytes = ''; return; }
                jobs.push(
                  fetch(entry.uri, { credentials: 'include', cache: 'no-store' })
                    .then(function (response) {
                      if (!response.ok) throw new Error('HTTP ' + response.status);
                      return response.arrayBuffer();
                    })
                    .then(function (buffer) { entry.bytes = toBase64(buffer); })
                    // Une cle illisible n'interrompt pas le plan : l'app la
                    // retelechargera elle-meme, ou echouera avec un message clair.
                    .catch(function () { entry.bytes = ''; })
                );
              })(keys[i]);
            }
            return Promise.all(jobs);
          }

          function assemble(manifest, variant, height, source) {
            var parsed = parseMedia(source, variant);
            return loadKeys(parsed.keys).then(function () {
              var blobs = [], uris = [], methods = [];
              for (var i = 0; i < parsed.keys.length; i++) {
                blobs.push(parsed.keys[i].bytes);
                uris.push(parsed.keys[i].uri);
                methods.push(parsed.keys[i].method);
              }

              var built = {
                manifest: manifest,
                variant: variant,
                height: height || 0,
                duration: parsed.duration,
                encrypted: parsed.encrypted,
                initUrl: parsed.initUrl,
                initRange: parsed.initRange,
                keys: blobs,
                keyUris: uris,
                keyMethods: methods,
                urls: [], key: [], iv: [], seq: [], range: []
              };

              for (var j = 0; j < parsed.segments.length; j++) {
                built.urls.push(parsed.segments[j].url);
                built.key.push(parsed.segments[j].key);
                built.iv.push(parsed.segments[j].iv);
                built.seq.push(parsed.segments[j].seq);
                built.range.push(parsed.segments[j].range);
              }
              return built;
            });
          }

          function plan(url, height) {
            var manifest = resolve(url, location.href);
            if (!manifest) return Promise.reject(new Error('URL de manifeste invalide'));

            return read(manifest).then(function (source) {
              var master = source.indexOf('#EXT-X-STREAM-INF') === -1
                ? [] : parseMaster(source, manifest);

              if (!master.length) {
                if (source.indexOf('#EXTINF') === -1 &&
                    source.indexOf('#EXT-X-MAP') === -1) {
                  throw new Error('le manifeste ne liste aucun segment');
                }
                // Memes reglages que le repli natif : sans quoi le meme flux
                // produirait `video.mp4` par la page et `video-720p.mp4` par
                // Swift.
                return assemble(manifest, manifest, height, source);
              }

              var wanted = height > 0 ? height : 0;
              master.sort(function (a, b) {
                if (wanted > 0) {
                  return Math.abs(a.height - wanted) - Math.abs(b.height - wanted);
                }
                return (b.height - a.height) || (b.bandwidth - a.bandwidth);
              });

              var pick = master[0];
              return read(pick.url).then(function (media) {
                return assemble(manifest, pick.url, pick.height, media);
              });
            });
          }

          window.__xgrabHLS = {
            isHLS: function (url) { return SEG.test(url || ''); },

            // Requete depuis l'app : renvoie le plan, leve si le manifeste est
            // illisible ou si le CDN refuse la requete.
            plan: function (url, height) { return plan(url, height); },

            // Requete depuis le bouton pose dans la page : le plan part par le
            // message, l'echec aussi. Les deux, sinon le clic ne produit rien
            // et le silence est indiscernable d'un flux non telechargeable.
            report: function (url, height) {
              return plan(url, height).then(function (built) {
                var payload = { event: 'hls-plan' };
                for (var name in built) {
                  if (Object.prototype.hasOwnProperty.call(built, name)) {
                    payload[name] = built[name];
                  }
                }
                post(payload);
                return built;
              }).catch(function (error) {
                post({
                  event: 'hls-error',
                  url: url,
                  height: height,
                  message: String((error && error.message) || error)
                });
              });
            }
          };
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
            var HLS = /\\.m3u8/i;
            var AD_PATH = /$adPath/i;
            var AD_MARK = /$adMark/;
            var MEDIA = /\\.(m3u8|mp4|m4v|webm|mov|mkv)(\\?|#|$)/i;

            var recent = [];
            var manifests = [];
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

            // Un lecteur HLS passe par MediaSource : `currentSrc` vaut "blob:"
            // et l'URL reelle n'apparait dans aucune balise. Elle est fournie
            // a addSourceBuffer, seul endroit ou elle existe. Sans cette
            // capture, aucun bouton n'apparait sur les flux segmentes.
            try {
              var original = MediaSource.prototype.addSourceBuffer;
              MediaSource.prototype.addSourceBuffer = function () {
                try {
                  var source = arguments[0];
                  if (typeof source === 'string' && /^https?:\\/\\//i.test(source) &&
                      !/^blob:/i.test(source)) {
                    if (manifests.indexOf(source) === -1) manifests.unshift(source);
                    if (manifests.length > 5) manifests.pop();
                    if (!window.__xgrabHooked) {
                      window.__xgrabHooked = true;
                      post({ event: 'hooked', manifest: source });
                    }
                  }
                } catch (e) {}
                return original.apply(this, arguments);
              };
            } catch (e) {}

            function sourceOf(video) {
              var direct = video.currentSrc || video.src || '';
              if (usable(direct)) return direct.split('#')[0];

              var nodes = video.querySelectorAll('source[src]');
              for (var i = 0; i < nodes.length; i++) {
                var u = nodes[i].getAttribute('src') || '';
                if (usable(u)) return u.split('#')[0];
              }

              // Flux MSE : on rend le dernier manifeste monte, qui correspond
              // au lecteur en cours de lecture.
              if (manifests.length) return manifests[0].split('#')[0];

              // Dernier recours : la derniere URL de media vue dans les
              // requetes du document.
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

                // Avant la premiere image decodee, `videoHeight` vaut 0 : on
                // retomberait alors sur la meilleure variante, souvent la plus
                // lourde de la liste. La taille affichee, elle, est connue
                // immediatement et suffit a choisir.
                var box = video.getBoundingClientRect();
                var height = video.videoHeight
                  || (Math.round(box.height / 2) * 2)
                  || 0;

                // Un flux HLS chiffre n'est pas downloadable par
                // AVAssetDownloadURLSession : iOS refuse le job en silence.
                // Le plan est donc construit ici, dans la page, puis les
                // segments sont telecharges en natif.
                if (HLS.test(url) && window.__xgrabHLS) {
                  window.__xgrabHLS.report(url, height);
                  return;
                }

                post({
                  event: 'download',
                  url: url,
                  height: height,
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
                post({ event: 'scan', media: null, list: [], ads: 0,
                       seen: 0, resolved: 0, manifests: manifests.length, empty: true });
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
                seen: videos.length,
                resolved: entries.length,
                manifests: manifests.length,
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
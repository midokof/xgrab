/* Affiche un bouton de telechargement XGrab au-dessus des videos detectees. */

(() => {
  if (window.__xgrabInjected) return;
  window.__xgrabInjected = true;

  const MEDIA_RE = /\.(m3u8|mp4|m4v|webm|mov|mkv)(\?|#|$)/i;
  const STREAM_RE = /(videoplayback|\.mpd|\.m3u8|migration\/)/i;
  const recent = [];
  const tracked = new WeakMap();

  let panel = null;
  let panelFor = null;

  /* --------------------------------------------------------- observations */

  function noteMedia(url) {
    if (!url || !MEDIA_RE.test(url)) return;
    const clean = url.split("#")[0];
    const at = recent.findIndex((item) => item.url === clean);
    if (at !== -1) recent.splice(at, 1);
    recent.unshift({ url: clean, at: Date.now() });
    if (recent.length > 12) recent.pop();
  }

  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) noteMedia(entry.name);
    }).observe({ type: "resource", buffered: true });
  } catch (err) {
    /* certain navigateurs refusent buffered */
  }

  /* -------------------------------------------------------------- sources */

  function sourceOf(video) {
    const direct = video.currentSrc || video.src || "";
    if (direct && /^https?:\/\//i.test(direct)) return direct;
    const sources = video.querySelectorAll("source[src]");
    for (const node of sources) {
      const url = node.getAttribute("src") || "";
      if (/^https?:\/\//i.test(url)) return url;
    }
    const fresh = recent.find((item) => Date.now() - item.at < 45000);
    return fresh ? fresh.url : "";
  }

  /* Un flux segmente (HLS, DASH, videoplayback) n'est pas telechargeable
     tel quel : il faut le manifeste, et YouTube separe l'audio de la video.
     Dans ce cas on transmet l'adresse de la page et XGrab la resout. */
  function isSegmented(url) {
    return STREAM_RE.test(url);
  }

  function payloadFor(video) {
    const media = sourceOf(video);
    if (media && !isSegmented(media)) {
      return { url: media, page: false };
    }
    return { url: location.href, page: true };
  }

  /* -------------------------------------------------------------- habillage */

  function ensurePanel() {
    if (panel && panel.isConnected) return panel;
    panel = document.createElement("div");
    panel.setAttribute("data-xgrab", "1");
    Object.assign(panel.style, {
      position: "fixed",
      zIndex: "2147483647",
      display: "none",
      font: "600 13px/1 'Segoe UI', system-ui, sans-serif",
      color: "#fff",
      background: "linear-gradient(180deg,#4d90fe,#2f5bb7)",
      border: "1px solid rgba(0,0,0,.25)",
      borderRadius: "8px",
      padding: "0",
      cursor: "pointer",
      boxShadow: "0 6px 18px rgba(0,0,0,.35)",
      overflow: "hidden",
      userSelect: "none",
    });

    const label = document.createElement("span");
    label.textContent = "\u2193  XGrab";
    Object.assign(label.style, { display: "block", padding: "9px 14px" });

    const note = document.createElement("span");
    note.style.cssText = "display:none;padding:5px 10px;font:500 11px/1.3 'Segoe UI',sans-serif";
    Object.assign(note.style, { borderTop: "1px solid rgba(255,255,255,.25)" });

    panel.append(label, note);
    (document.body || document.documentElement).appendChild(panel);

    panel.addEventListener("mouseenter", () => {
      panel.style.background = "linear-gradient(180deg,#6aa2ff,#3f6bd0)";
    });
    panel.addEventListener("mouseleave", () => {
      panel.style.background = "linear-gradient(180deg,#4d90fe,#2f5bb7)";
      note.style.display = "none";
    });
    panel.addEventListener("click", onClick);
    return panel;
  }

  function onClick(event) {
    event.preventDefault();
    event.stopPropagation();

    const video = panelFor;
    if (!video) {
      showNote("Video introuvable");
      return;
    }

    const payload = payloadFor(video);
    if (!payload.url) {
      showNote("Flux non identifiable");
      return;
    }
    if (payload.page) showNote("Analyse de la page...");

    panel.style.opacity = "0.7";
    chrome.runtime.sendMessage(
      {
        type: "xgrab-add",
        urls: [payload.url],
        /* la page d'origine sert de Referer, indispensable sur les CDN proteges */
        referer: location.href,
      },
      (reply) => {
        panel.style.opacity = "1";
        if (chrome.runtime.lastError || !reply) {
          showNote("XGrab indisponible");
          return;
        }
        if (!reply.ok) {
          showNote(reply.error || "Erreur");
          return;
        }
        const prefix = reply.started ? "XGrab lance - " : "";
        showNote(`${prefix}Ajouté (${reply.added})`);
      }
    );
  }

  function showNote(text) {
    const note = panel.lastElementChild;
    note.textContent = text;
    note.style.display = "block";
    clearTimeout(panel._timer);
    panel._timer = setTimeout(() => {
      note.style.display = "none";
    }, 3200);
  }

  /* ------------------------------------------------------------ positioning */

  function best() {
    const videos = Array.from(document.querySelectorAll("video"));
    if (!videos.length) return null;
    const visible = videos.filter((v) => {
      const box = v.getBoundingClientRect();
      return box.width > 120 && box.height > 80 && box.bottom > 0 && box.top < innerHeight;
    });
    const list = visible.length ? visible : videos;
    list.sort((a, b) => {
      const ra = a.getBoundingClientRect();
      const rb = b.getBoundingClientRect();
      return rb.width * rb.height - ra.width * ra.height;
    });
    return list[0];
  }

  function place() {
    const video = best();
    if (!video || !video.isConnected) {
      if (panel) panel.style.display = "none";
      return;
    }
    if (panelFor !== video) {
      panelFor = video;
      tracked.set(video, true);
    }

    const box = video.getBoundingClientRect();
    const host = ensurePanel();
    host.style.display = "block";
    host.style.top = `${Math.max(4, box.top + 10)}px`;
    host.style.left = `${Math.max(4, Math.min(box.right - 118, innerWidth - 122))}px`;
    host.style.visibility = box.bottom < 0 || box.top > innerHeight ? "hidden" : "visible";
  }

  /* ------------------------------------------------------------------ scan */

  let scheduled = false;
  function schedule() {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      place();
    });
  }

  new MutationObserver(schedule).observe(document.documentElement, {
    childList: true,
    subtree: true,
  });

  addEventListener("resize", schedule, { passive: true });
  addEventListener("scroll", schedule, { passive: true, capture: true });
  document.addEventListener("play", schedule, true);
  document.addEventListener("loadedmetadata", schedule, true);

  schedule();
  setInterval(schedule, 1200);
})();

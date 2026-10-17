"""Langue de l'interface, detectee depuis le Windows local.

La langue est lue dans les preferences du systeme (GetUserDefaultUILanguage),
donc elle suit le Windows sur lequel l'application est installee. Un choix
manuel dans l'interface est memorise dans la configuration et prime.
"""

from __future__ import annotations

import ctypes
from typing import Any, Optional

FR = "fr"
EN = "en"
SUPPORTED = (FR, EN)

# LANGID primary language Windows
_FRENCH = 0x0C

_current = FR


def detect_system_language() -> str:
    """Retourne la langue d'interface du Windows courant."""
    try:
        langid = ctypes.windll.kernel32.GetUserDefaultUILanguage()
        primary = int(langid) & 0x3FF
        return FR if primary == _FRENCH else EN
    except Exception:
        return EN


def set_language(lang: Optional[str]) -> str:
    """Fixe la langue active. None = detection systeme."""
    global _current
    _current = lang if lang in SUPPORTED else detect_system_language()
    return _current


def current() -> str:
    return _current


def is_rtl(lang: Optional[str] = None) -> bool:
    lang = lang or _current
    return lang == "ar" or lang == "he"


STRINGS: dict[str, dict[str, str]] = {
    FR: {
        # ------------------------------------------------------------- entete
        "ui.link": "LIEN",
        "ui.add": "AJOUTER",
        "ui.more": "+  Plus de liens / options",
        "ui.multiple": "PLUSIEURS",
        "ui.mix": "Tout mélanger",
        "ui.wipe": "Vider",
        "ui.cookies": "COOKIES",
        "ui.capture": "Capturer",
        "ui.verify": "Vérifier",
        "ui.erase": "Effacer",
        "ui.capture_hint": "Capturer ouvre Edge/Chrome et intercepte la vraie requête vidéo (méthode IDM)",
        "ui.browser": "NAVIGATEUR",
        "ui.browser_hint": "utilisé par yt-dlp pour les sites protégés par âge",
        "ui.more_links": "+  Plus de liens",
        "ui.hide_list": "-  Masquer la liste",
        "ui.language": "Langue",
        # -------------------------------------------------------------- file
        "ui.queue": "FILE",
        "ui.none": "Aucun",
        "ui.empty_queue": "La file est vide - collez un lien puis cliquez sur Analyser",
        "ui.no_selection": "Aucune sélection",
        "ui.resolution": "Résolution",
        "ui.refresh": "Sonner",
        "ui.folder": "Dossier",
        "ui.browse": "Parcourir",
        "ui.open_folder": "Ouvrir le dossier",
        "ui.name": "Nom",
        "ui.chain": "enchaîner",
        "ui.download": "▼  TELECHARGER",
        "ui.stop": "■  STOP",
        "ui.pause": "❚❚  PAUSE",
        "ui.resume": "▶  REPRENDRE",
        "ui.open": "Ouvrir",
        "ui.delete": "Supprimer",
        "ui.remove": "Retirer",
        "ui.journal": "JOURNAL",
        "ui.hide": "-  Masquer",
        "ui.show": "+  Afficher",
        "ui.column.source": "Source",
        "ui.column.quality": "Qualité",
        "ui.column.size": "Taille",
        "ui.column.progress": "Progression",
        "ui.column.status": "Statut",
        # ---------------------------------------------------------- messages
        "msg.no_link_capture": "Aucun lien à capturer.",
        "msg.no_link_verify": "Aucun lien à vérifier.",
        "msg.busy": "Un téléchargement est en cours.",
        "msg.no_link_x": "Collez au moins un lien X / Twitter.",
        "msg.empty_multi": "La zone multiple est vide.",
        "msg.no_file": "Aucun fichier téléchargé pour cet élément.",
        "msg.nothing_delete": "Rien à supprimer pour cet élément.",
        "msg.confirm_delete": "Supprimer définitivement ?\n\n{listing}",
        "msg.pick_resolution": "Choisissez une résolution.",
        "msg.pick_folder": "Choisissez un dossier de destination.",
        # ------------------------------------------------------------ etats
        "st.pending": "en attente",
        "st.ready": "prêt",
        "st.resolving": "analyse",
        "st.working": "téléchargement",
        "st.done": "terminé",
        "st.paused": "en pause",
        "st.cancelled": "arrêté",
    "st.interrupted": "interrompu",
        "st.error": "échec",
        "st.deleted": "supprimé",
        "st.resume": "reprend",
        "st.captured": "capturé",
        # -------------------------------------------------------------- logs
        "log.cookies_cleared": "Cookies effacés",
        "log.clipboard": "Lien détecté dans le presse-papiers, Entrée pour l'ajouter",
        "log.sizes": "Actualisation des tailles...",
        "log.stop": "Stop demandé...",
        "log.stopped": "Téléchargement arrêté - reprise possible (.part conservé)",
        "log.pause": "Pause demandée...",
        "log.nothing_resume": "Rien à reprendre",
        "log.capture_done": "Capture terminée, choisis une résolution puis TELECHARGER",
        "log.folder_error": "Impossible d'ouvrir le dossier : {error}",
        "log.file_error": "Impossible d'ouvrir le fichier : {error}",
        "log.delete_error": "Suppression impossible : {error}",
        "log.deleted": "Supprimé : {size} libérés",
        "log.begin": "Début : {name} ({variant})",
        "log.resolved": "{height} max via {extractor} - {title}",
        "log.failed": "Échec : {message}",
        "log.error": "Erreur : {message}",
        "log.capturing": "Capture navigateur : {url}",
        "log.verifying": "Vérification de {url}\n     cookies : {count} caractère(s)",
        "log.refresh_token": "HTTP {status} - nouvelle analyse du lien pour un jeton frais...",
        "log.auto_capture": (
            "HTTP {status} - capture automatique dans le navigateur (méthode IDM), "
            "ouverture d'Edge..."
        ),
        "log.auto_capture_failed": "Capture automatique échouée : {message}",
        "log.intercepted": (
            "Requête interceptée : {count} en-têtes, "
            "analyse : {extractor}, {variants} variante(s), "
            "téléchargement direct"
        ),
        "log.paused_size": "En pause : {size} conservés, reprend au même octet",
        "log.ok": "OK  {name}  ({size} en {duration}, {speed})",
        "log.starting": "Analyse de {url}",
        "log.clearing": "Suppression de {count} élément(s) terminé(s)",
        # ------------------------------------------------------------ etats UI
        "state.deleted": "Fichier supprimé",
        "state.stopping": "Arrêt en cours...",
        "state.stopped": "Arrêté",
        "state.pausing": "Pause...",
        "state.paused": "En pause",
        "state.done": "Terminé",
        "state.working": "Téléchargement en cours",
        "state.capturing": "Capture navigateur...",
        "state.added": "{count} lien(s) ajouté(s)",
    },
    EN: {
        # ------------------------------------------------------------- header
        "ui.link": "LINK",
        "ui.add": "ADD",
        "ui.more": "+  More links / options",
        "ui.multiple": "MULTIPLE",
        "ui.mix": "Mix all",
        "ui.wipe": "Clear",
        "ui.cookies": "COOKIES",
        "ui.capture": "Capture",
        "ui.verify": "Verify",
        "ui.erase": "Clear",
        "ui.capture_hint": "Capture opens Edge/Chrome and intercepts the real video request (IDM method)",
        "ui.browser": "BROWSER",
        "ui.browser_hint": "used by yt-dlp for age-restricted sites",
        "ui.more_links": "+  More links",
        "ui.hide_list": "-  Hide list",
        "ui.language": "Language",
        # -------------------------------------------------------------- queue
        "ui.queue": "QUEUE",
        "ui.none": "None",
        "ui.empty_queue": "Queue is empty - paste a link then click Add",
        "ui.no_selection": "No selection",
        "ui.resolution": "Resolution",
        "ui.refresh": "Refresh sizes",
        "ui.folder": "Folder",
        "ui.browse": "Browse",
        "ui.open_folder": "Open folder",
        "ui.name": "Name",
        "ui.chain": "chain",
        "ui.download": "▼  DOWNLOAD",
        "ui.stop": "■  STOP",
        "ui.pause": "❚❚  PAUSE",
        "ui.resume": "▶  RESUME",
        "ui.open": "Open",
        "ui.delete": "Delete",
        "ui.remove": "Remove",
        "ui.journal": "LOG",
        "ui.hide": "-  Hide",
        "ui.show": "+  Show",
        "ui.column.source": "Source",
        "ui.column.quality": "Quality",
        "ui.column.size": "Size",
        "ui.column.progress": "Progress",
        "ui.column.status": "Status",
        # ------------------------------------------------------------ messages
        "msg.no_link_capture": "No link to capture.",
        "msg.no_link_verify": "No link to verify.",
        "msg.busy": "A download is already running.",
        "msg.no_link_x": "Paste at least one X / Twitter link.",
        "msg.empty_multi": "The multiple-link box is empty.",
        "msg.no_file": "No downloaded file for this item.",
        "msg.nothing_delete": "Nothing to delete for this item.",
        "msg.confirm_delete": "Delete permanently?\n\n{listing}",
        "msg.pick_resolution": "Choose a resolution.",
        "msg.pick_folder": "Choose a destination folder.",
        # -------------------------------------------------------------- states
        "st.pending": "pending",
        "st.ready": "ready",
        "st.resolving": "resolving",
        "st.working": "downloading",
        "st.done": "done",
        "st.paused": "paused",
        "st.cancelled": "stopped",
    "st.interrupted": "interrupted",
        "st.error": "failed",
        "st.deleted": "deleted",
        "st.resume": "resuming",
        "st.captured": "captured",
        # ---------------------------------------------------------------- logs
        "log.cookies_cleared": "Cookies cleared",
        "log.clipboard": "Link found in clipboard, press Enter to add it",
        "log.sizes": "Refreshing sizes...",
        "log.stop": "Stop requested...",
        "log.stopped": "Download stopped - can be resumed (.part kept)",
        "log.pause": "Pause requested...",
        "log.nothing_resume": "Nothing to resume",
        "log.capture_done": "Capture done, pick a resolution then DOWNLOAD",
        "log.folder_error": "Could not open folder: {error}",
        "log.file_error": "Could not open file: {error}",
        "log.delete_error": "Could not delete: {error}",
        "log.deleted": "Deleted: {size} freed",
        "log.begin": "Start: {name} ({variant})",
        "log.resolved": "{height} max via {extractor} - {title}",
        "log.failed": "Failed: {message}",
        "log.error": "Error: {message}",
        "log.capturing": "Browser capture: {url}",
        "log.verifying": "Checking {url}\n     cookies: {count} character(s)",
        "log.refresh_token": "HTTP {status} - re-resolving the link for a fresh token...",
        "log.auto_capture": (
            "HTTP {status} - automatic browser capture (IDM method), opening Edge..."
        ),
        "log.auto_capture_failed": "Automatic capture failed: {message}",
        "log.intercepted": (
            "Request intercepted: {count} headers, "
            "analysis: {extractor}, {variants} variant(s), "
            "direct download"
        ),
        "log.paused_size": "Paused: {size} kept, resumes at the same byte",
        "log.ok": "OK  {name}  ({size} in {duration}, {speed})",
        "log.starting": "Analyzing {url}",
        "log.clearing": "Removed {count} finished item(s)",
        # -------------------------------------------------------- UI states
        "state.deleted": "File deleted",
        "state.stopping": "Stopping...",
        "state.stopped": "Stopped",
        "state.pausing": "Pausing...",
        "state.paused": "Paused",
        "state.done": "Done",
        "state.working": "Downloading",
        "state.capturing": "Browser capture...",
        "state.added": "{count} link(s) added",
    },
}


def tr(key: str, **kwargs: Any) -> str:
    """Traduit une cle. Les cles inconnues retombent sur le francais."""
    text = STRINGS.get(_current, STRINGS[FR]).get(key)
    if text is None:
        text = STRINGS[FR].get(key, key)
    if kwargs:
        try:
            return text.format(**kwargs)
        except (KeyError, IndexError, ValueError):
            return text
    return text


# Journal technique : les messages sont composes par f-string dans app.py, donc
# on traduit les fragments statiques plutot que les appels. Les fragments sont
# appliques du plus long au plus court pour qu'un texte ne soit jamais coupe en
# plein milieu.
LOG_EN = {
    "Extension navigateur : port ": "Browser extension: port ",
    "Vérification de ": "Checking ",
    " cookies : ": " cookies: ",
    " caractère(s)": " char(s)",
    "Actualisation des tailles...": "Refreshing sizes...",
    "Supprimé : ": "Deleted: ",
    " libérés": " freed",
    "Téléchargement arrêté - reprise possible (.part conservé)":
        "Download stopped - resumable (.part kept)",
    "Début : ": "Starting: ",
    "Téléchargement en cours, lien mis en attente":
        "Download running, link queued",
    "Lien détecté dans le presse-papiers, Entrée pour l'ajouter":
        "Link found in clipboard, press Enter to add it",
    "Stop demandé...": "Stop requested...",
    "Pause demandée...": "Pause requested...",
    "Rien à reprendre": "Nothing to resume",
    "Impossible d'ouvrir le dossier : ": "Cannot open folder: ",
    "Impossible d'ouvrir le fichier : ": "Cannot open file: ",
    "En pause : ": "Paused: ",
    " conservés, reprend au même octet": " kept, resumes at same byte",
    "Suppression impossible : ": "Cannot delete: ",
    " max via ": " max via ",
    "Échec : ": "Failed: ",
    " - nouvelle analyse du lien pour un jeton frais...":
        " - re-resolving link for a fresh token...",
    " - capture automatique dans le navigateur (méthode IDM), laisse l'onglet s'ouvrir...":
        " - automatic browser capture (IDM method), leave the tab open...",
    "Capture automatique échouée : ": "Automatic capture failed: ",
    "Requête interceptée : ": "Request intercepted: ",
    " en-têtes, ": " headers, ",
    " car. de cookie → relance": " cookie(s) - retrying",
    "Capture terminée, choisis une résolution puis TELECHARGER":
        "Capture finished, pick a resolution then DOWNLOAD",
    " - .part conservé, relance pour reprendre": " - .part kept, run again to resume",
    "Cookies effacés": "Cookies cleared",
    "Port du navigateur indisponible": "Browser port unavailable",
    "Capture navigateur : ": "Browser capture: ",
    "Erreur : ": "Error: ",
    "Aucun lien à capturer.": "No link to capture.",
    "Aucun lien à vérifier.": "No link to verify.",
    "Un téléchargement est en cours.": "A download is in progress.",
    "Collez au moins un lien X / Twitter.": "Paste at least one X / Twitter link.",
    "La zone multiple est vide.": "The multi-link box is empty.",
    "Aucun fichier téléchargé pour cet élément.": "No downloaded file for this item.",
    "Rien à supprimer pour cet élément.": "Nothing to delete for this item.",
    "Choisissez une résolution.": "Choose a resolution.",
    "Choisissez un dossier de destination.": "Choose a destination folder.",
    " en ": " in ",
    "": "",
}

_LOG_ORDER = sorted(LOG_EN, key=len, reverse=True)


def translate_log(text: str) -> str:
    """Traduit un message de journal deja compose, interpolations comprises.

    Retourne le texte tel quel si rien ne correspond : un message inconnu ne
    doit jamais disparaitre du journal.
    """
    if _current == FR or not text:
        return text
    for frag in _LOG_ORDER:
        if frag and frag in text:
            text = text.replace(frag, LOG_EN[frag])
    return text

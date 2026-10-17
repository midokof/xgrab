# XGrab iPhone

Application iOS (Safari Web Extension) qui renvoie les liens vidéo vers XGrab
sur le PC. Le téléchargement reste fait par le PC : l'iPhone ne fait que
détecter et transmettre.

```
iPhone (Safari + extension)  ──HTTP sur le Wi-Fi──▶  PC (XGrab)
        content.js                    jeton         server.py
        background.js                              downloader.py
```

## Ce qu'il faut avant de compiler

| Élément | Obligatoire | Comment l'obtenir |
|---|---|---|
| Apple Developer Program | oui | 99 $/an sur developer.apple.com |
| Clé API App Store Connect | oui | Console App Store Connect ▸ Utilisateurs ▸ Accès aux clés |
| `Team ID` | oui | Console Developer ▸ Membres ▸ votre identifiant à 10 caractères |
| Repo GitHub | oui | pour déclencher le workflow |
| Runner macOS | oui | gratuit si le repo est **public**, sinon facturé 10× la minute |

Un compte Apple gratuit ne suffit pas : il ne permet ni de créer une clé API,
ni de produire une signature durable.

## Secrets à ajouter dans le dépôt

`Settings ▸ Secrets and variables ▸ Actions ▸ New repository secret`

| Nom | Contenu |
|---|---|
| `APPLE_TEAM_ID` | votre Team ID, 10 caractères |
| `APPLE_KEY_ID` | identifiant de la clé, 10 caractères |
| `APPLE_KEY_P8` | **contenu textuel** du fichier `.p8`, pas le fichier |

## Compiler

```bash
git init
git add .
git commit -m "XGrab iOS"
git remote add origin https://github.com/<vous>/<depot>.git
git push -u origin main
```

Puis `Actions ▸ Build iOS ▸ Run workflow`. L'IPA apparaît dans les artifacts.

## Installer

1. Dépose le fichier `.ipa` sur l'iPhone (AirDrop, iCloud, ou lien).
2. Ouvre-le ; iOS refuse les IPA hors App Store.
3. Utilise **Sideloadly** ou **AltStore** sur le PC (gratuit) pour
   l'installer et l'activer. La signature development expire au bout de
   **7 jours**, il faut alors re-signer.
4. Réglages ▸ Apps ▸ Safari ▸ Extensions ▸ XGrab ▸ activer.
5. Ouvrir l'app XGrab, saisir l'adresse du PC et le jeton, « Tester la
   connexion » doit répondre vert.

## Côté PC

Dans XGrab, cocher **« Accès iPhone »** puis **redémarrer l'application**.
L'adresse et le jeton s'affichent dans la fenêtre. L'écoute passe de
`127.0.0.1` à `0.0.0.0`, ce qui rend le point d'injection de liens accessible
à tout le segment Wi-Fi : le jeton reste la seule barrière, d'où son
caractère explicite et régénéré à chaque lancement.

## Arborescence

```
ios/
  project.yml                  XcodeGen : génère le .xcodeproj
  make_assets.py               génère l'icône 1024 et la couleur d'accent
  App/
    ContentView.swift          saisie adresse/port/jeton, test de connexion
    Info.plist                 ATS réseau local, description réseau local
    Assets.xcassets/           icône et accent
  Extension/
    SafariWebExtensionHandler.swift   pont natif (partagé via app group)
    Resources/
      manifest.json            MV3, compatible Safari iOS 16.4+
      background.js            relais HTTP vers le PC (pas de connectNative)
      content.js               identique à l'extension desktop
```

`content.js` est repris tel quel depuis l'extension desktop : il n'utilise que
du DOM et `chrome.runtime.sendMessage`, que Safari alias sur `browser.*`.

## Limites connues

- iOS impose le même Wi-Fi que le PC ; pas de fonctionne hors ligne.
- La signature development expire tous les 7 jours. Un compte à 99 $/an avec
  distribution TestFlight donne un an de validité.
- `background.js` interroge le PC en HTTP clair ; c'est pourquoi
  `NSAllowsLocalNetworking` est activé. Le trafic est protégé par le jeton,
  pas par le chiffrement.
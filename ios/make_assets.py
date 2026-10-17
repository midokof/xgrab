"""Genere les assets de l'app iOS : icone 1024 et couleur d'accent."""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent
ASSETS = ROOT / "App" / "Assets.xcassets"

ACCENT = (77, 144, 254)
ACCENT_DARK = (47, 91, 183)


def icon() -> Image.Image:
    size = 1024
    image = Image.new("RGB", (size, size), ACCENT_DARK)
    draw = ImageDraw.Draw(image)

    # Degrade vertical simple, du bleu clair au bleu fonce.
    for y in range(size):
        ratio = y / (size - 1)
        row = tuple(
            round(ACCENT[i] + (ACCENT_DARK[i] - ACCENT[i]) * ratio) for i in range(3)
        )
        draw.line([(0, y), (size, y)], fill=row)

    # Fleche de telechargement : tige + pointe, centrees.
    width = 92
    cx = size // 2
    draw.rounded_rectangle(
        [cx - width // 2, 250, cx + width // 2, 620],
        radius=width // 2,
        fill=(255, 255, 255),
    )
    draw.polygon(
        [(cx - 190, 560), (cx + 190, 560), (cx, 830)],
        fill=(255, 255, 255),
    )

    # Barre de base.
    draw.rounded_rectangle([240, 872, size - 240, 872 + 62], radius=31, fill=(255, 255, 255))

    return image


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def main() -> None:
    write(
        ASSETS / "Contents.json",
        '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n',
    )

    appicon = ASSETS / "AppIcon.appiconset"
    appicon.mkdir(parents=True, exist_ok=True)
    icon().save(appicon / "icon-1024.png")
    write(
        appicon / "Contents.json",
        """{
  "images" : [
    {
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""",
    )

    accent = ASSETS / "AccentColor.colorset"
    accent.mkdir(parents=True, exist_ok=True)
    write(
        accent / "Contents.json",
        """{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0xFE",
          "green" : "0x90",
          "red" : "0x4D"
        }
      },
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""",
    )

    print("assets ecrits :", ASSETS)


if __name__ == "__main__":
    main()
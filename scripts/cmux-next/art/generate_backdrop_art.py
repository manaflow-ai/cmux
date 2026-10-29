#!/usr/bin/env python3
"""Generate cmux-next's bundled backdrop art from art/manifest.json (cx-t2x.7).

art/manifest.json is the one source of truth: each work's Commons source and license,
its picker collection, its framing hints and its SHA-256. This writes

- Packages/macOS/CmuxNext/Sources/CmuxNextAppearance/Backdrop/BackdropArt.swift (the enum and titles)
  and BackdropArt+Entries.swift (its records), two files to stay under the 400-line file limit,
- the CmuxNextAppearance string catalog entries for each title (every locale the catalog carries),
- CmuxNextDesign's Resources/BackdropArt/<id>.avif for the bundled starter set, copied from art/full.

Thumbnails (Resources/BackdropArt/<id>.thumb.avif) and art/full/*.avif come from
scripts/cmux-next/art/render_backdrop_art.py. With --check nothing is written; the
exit status says whether the generated files are current.
"""
import argparse
import json
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
MANIFEST = ROOT / "art/manifest.json"
FULL = ROOT / "art/full"
DESIGN = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextDesign"
APPEARANCE = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextAppearance"
SWIFT = APPEARANCE / "Backdrop/BackdropArt.swift"
SWIFT_ENTRIES = APPEARANCE / "Backdrop/BackdropArt+Entries.swift"
# The backdrop's words live with the art's enum and the selection's names; the images stay in
# CmuxNextDesign's resources.
CATALOG = APPEARANCE / "Localizable.xcstrings"
RESOURCES = DESIGN / "Resources/BackdropArt"
LOCALES = ["ar", "bs", "da", "de", "en", "es", "fr", "it", "ja", "km", "ko", "nb", "pl", "pt-BR", "ru", "th", "tr",
           "uk", "vi", "zh-Hans", "zh-Hant"]
# The backdrop keys that are not art: the desktop wallpaper, macOS system wallpaper and own-image
# tiles (the own image's attribution is also in STATIC).
NOT_ART = {"desktop", "system", "file"}
OMISSIONS = ROOT / "scripts/localization-allowed-omissions.json"
TITLE_REASON = "The work is known by this title in this language too (a proper name or the usual local title)."
STATIC = {
    "backdrop.label": {l: "%1$@ — %2$@" for l in LOCALES},
    "backdrop.publicDomain": {
        "en": "Public domain", "ar": "ملكية عامة", "de": "Gemeinfrei", "es": "Dominio público", "fr": "Domaine public",
        "ja": "パブリックドメイン", "ko": "퍼블릭 도메인", "zh-Hans": "公有领域", "zh-Hant": "公有領域",
        "bs": "Javno vlasništvo", "da": "Offentligt domæne", "it": "Pubblico dominio", "km": "កម្មសិទ្ធិសាធារណៈ", "nb": "Allemannseie", "pl": "Domena publiczna", "pt-BR": "Domínio público", "ru": "Общественное достояние", "th": "สาธารณสมบัติ", "tr": "Kamu malı", "uk": "Суспільне надбання", "vi": "Phạm vi công cộng",
    },
    "backdrop.collection.darkArt": {
        "en": "Dark Art", "ar": "فن مظلم", "de": "Dunkle Kunst", "es": "Arte oscuro", "fr": "Art sombre",
        "ja": "ダークアート", "ko": "다크 아트", "zh-Hans": "暗黑艺术", "zh-Hant": "暗黑藝術",
        "bs": "Mračna umjetnost", "da": "Mørk kunst", "it": "Arte oscura", "km": "សិល្បៈងងឹត", "nb": "Mørk kunst", "pl": "Mroczna sztuka", "pt-BR": "Arte Sombria", "ru": "Мрачное искусство", "th": "ศิลปะโทนมืด", "tr": "Karanlık Sanat", "uk": "Похмуре мистецтво", "vi": "Nghệ thuật u tối",
    },
    "backdrop.collection.museumIcons": {
        "en": "Museum Icons", "ar": "روائع المتاحف", "de": "Museumsikonen", "es": "Iconos de museo", "fr": "Icônes des musées",
        "ja": "名画", "ko": "명화", "zh-Hans": "博物馆名作", "zh-Hant": "博物館名作",
        "bs": "Muzejska remek-djela", "da": "Museumsikoner", "it": "Icone dei musei", "km": "ស្នាដៃល្បីៗក្នុងសារមន្ទីរ", "nb": "Museumsikoner", "pl": "Arcydzieła muzealne", "pt-BR": "Ícones de Museu", "ru": "Шедевры музеев", "th": "ผลงานชิ้นเอกในพิพิธภัณฑ์", "tr": "Müze İkonları", "uk": "Шедеври музеїв", "vi": "Kiệt tác bảo tàng",
    },
    "backdrop.collection.calm": {
        "en": "Calm", "ar": "هدوء", "de": "Ruhig", "es": "Calma", "fr": "Calme",
        "ja": "穏やか", "ko": "차분함", "zh-Hans": "宁静", "zh-Hant": "寧靜",
        "bs": "Smireno", "da": "Rolig", "it": "Calma", "km": "ស្ងប់ស្ងាត់", "nb": "Rolig", "pl": "Spokój", "pt-BR": "Calma", "ru": "Спокойствие", "th": "สงบ", "tr": "Sakin", "uk": "Спокій", "vi": "Tĩnh lặng",
    },
    "backdrop.collection.dore": {
        "en": "Doré", "ar": "دوريه", "de": "Doré", "es": "Doré", "fr": "Doré",
        "ja": "ドレ", "ko": "도레", "zh-Hans": "多雷", "zh-Hant": "多雷",
        "bs": "Doré", "da": "Doré", "it": "Doré", "km": "ដូរេ", "nb": "Doré", "pl": "Doré", "pt-BR": "Doré", "ru": "Доре", "th": "โดเร", "tr": "Doré", "uk": "Доре", "vi": "Doré",
    },
    "backdrop.collection.yours": {
        "en": "Your images", "ar": "صورك", "bs": "Vaše slike", "da": "Dine billeder", "de": "Deine Bilder", "es": "Tus imágenes",
        "fr": "Vos images", "it": "Le tue immagini", "ja": "自分の画像", "km": "រូបភាពរបស់អ្នក", "ko": "내 이미지", "nb": "Dine bilder",
        "pl": "Twoje obrazy", "pt-BR": "Suas imagens", "ru": "Ваши изображения", "th": "รูปภาพของคุณ", "tr": "Görselleriniz", "uk": "Ваші зображення",
        "vi": "Hình ảnh của bạn", "zh-Hans": "你的图片", "zh-Hant": "你的圖片",
    },
    "backdrop.file.attribution": {
        "en": "Your image · %@", "ar": "صورتك · %@", "bs": "Vaša slika · %@", "da": "Dit billede · %@", "de": "Dein Bild · %@", "es": "Tu imagen · %@",
        "fr": "Votre image · %@", "it": "La tua immagine · %@", "ja": "自分の画像 · %@", "km": "រូបភាពរបស់អ្នក · %@", "ko": "내 이미지 · %@", "nb": "Ditt bilde · %@",
        "pl": "Twój obraz · %@", "pt-BR": "Sua imagem · %@", "ru": "Ваше изображение · %@", "th": "รูปภาพของคุณ · %@", "tr": "Görseliniz · %@", "uk": "Ваше зображення · %@",
        "vi": "Hình ảnh của bạn · %@", "zh-Hans": "你的图片 · %@", "zh-Hant": "你的圖片 · %@",
    },
}


def case_name(slug: str) -> str:
    head, *rest = slug.split("-")
    return head + "".join(part[:1].upper() + part[1:] for part in rest)


def swift_string(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def hex_literal(color: str) -> str:
    return "0x" + color.lstrip("#").upper()


def render_swift(works: list[dict]) -> str:
    lines = [
        "// Generated by scripts/cmux-next/art/generate_backdrop_art.py from art/manifest.json. Do not edit.",
        "",
        "public import Foundation",
        "",
        "/// A public-domain artwork for the window backdrop (cx-t2x.7): well-known paintings and prints",
        "/// from Wikimedia Commons, each cleared as public domain in the US (the artist died 70+ years ago",
        "/// and the work was published before 1931). Sources and licenses: art/manifest.json.",
        "public nonisolated enum BackdropArt: String, CaseIterable, Sendable {",
    ]
    for work in works:
        lines.append(f"    case {case_name(work['id'])} = {swift_string(work['id'])}")
    lines += ["", "    /// The work's title in the user's language.", "    public var title: String {", "        switch self {"]
    for work in works:
        key = f"backdrop.{work['id']}.title"
        lines.append(f"        case .{case_name(work['id'])}: String(localized: {swift_string(key)}, "
                     f"defaultValue: {swift_string(work['title'])}, bundle: .module)")
    lines += ["        }", "    }", "}", ""]
    return "\n".join(lines)


def render_entries(works: list[dict]) -> str:
    lines = [
        "// Generated by scripts/cmux-next/art/generate_backdrop_art.py from art/manifest.json. Do not edit.",
        "",
        "nonisolated extension BackdropArt {",
        "    /// The work's catalog record.",
        "    package var entry: BackdropArtEntry {",
        "        switch self {",
    ]
    for work in works:
        palette = ", ".join(hex_literal(color) for color in work["palette"])
        lines.append(
            f"        case .{case_name(work['id'])}: BackdropArtEntry("
            f"artist: {swift_string(work['artist'])}, year: {swift_string(work['year'])}, "
            f"museum: {swift_string(work['museum'])}, collection: .{work['collection']}, "
            f"source: {swift_string(work['source'])}, license: {swift_string(work['license'])}, "
            f"sha256: {swift_string(work['sha256'])}, bundled: {'true' if work['bundled'] else 'false'}, "
            f"focal: ({work['focal'][0]}, {work['focal'][1]}), "
            f"subject: ({', '.join(str(v) for v in work['subject'])}), tone: .{work['tone']}, palette: [{palette}], "
            f"quietLeft: {'true' if work['quiet'] == 'left' else 'false'}, tint: {work['tint']}, "
            f"darkest: {hex_literal(work['darkest'])}, lightest: {hex_literal(work['lightest'])})"
        )
    lines += ["        }", "    }", "}", ""]
    return "\n".join(lines)


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def update_catalog(works: list[dict], catalog: dict) -> dict:
    strings = catalog["strings"]
    for key in list(strings):
        match = re.fullmatch(r"backdrop\.([^.]+)\.(title|attribution)", key)
        if match and match[1] not in NOT_ART:
            del strings[key]
    for key, values in STATIC.items():
        strings[key] = {"extractionState": "manual", "localizations": {l: unit(values[l]) for l in LOCALES}}
    for work in works:
        localizations = {"en": unit(work["title"])}
        for locale, value in work["titles"].items():
            localizations[locale] = unit(value)
        strings[f"backdrop.{work['id']}.title"] = {"extractionState": "manual", "localizations": localizations}
    return catalog


def update_omissions(works: list[dict], omissions: dict) -> dict:
    """Records the generated keys whose translation is the English text itself."""
    for key in [k for k in omissions if k.startswith("backdrop.")]:
        del omissions[key]
    omissions["backdrop.label"] = {"class": "format", "source": STATIC["backdrop.label"]["en"]}
    entries = [(k, v["en"], {l: t for l, t in v.items() if l != "en"}, "Doré is the artist's name.")
               for k, v in STATIC.items() if k != "backdrop.label"]
    entries += [(f"backdrop.{w['id']}.title", w["title"], w["titles"], TITLE_REASON) for w in works]
    for key, english, translations, reason in entries:
        same = {l: {"reason": reason, "values": [english]} for l, t in sorted(translations.items()) if t == english}
        if same:
            omissions[key] = {"source": english, "identityLocales": same}
    return omissions


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="report stale generated files without writing")
    args = parser.parse_args()
    works = json.loads(MANIFEST.read_text())["works"]
    stale = []

    for path, text in [(SWIFT, render_swift(works)), (SWIFT_ENTRIES, render_entries(works))]:
        if not path.exists() or path.read_text() != text:
            stale.append(path)
            if not args.check:
                path.write_text(text)

    catalog_text = CATALOG.read_text()
    catalog = update_catalog(works, json.loads(catalog_text))
    rendered = json.dumps(catalog, indent=2, ensure_ascii=False, separators=(",", ": ")) + "\n"
    if rendered != catalog_text:
        stale.append(CATALOG)
        if not args.check:
            CATALOG.write_text(rendered)

    omissions_text = OMISSIONS.read_text()
    omissions = update_omissions(works, json.loads(omissions_text))
    rendered = json.dumps(omissions, indent=2, ensure_ascii=False) + "\n"
    if rendered != omissions_text:
        stale.append(OMISSIONS)
        if not args.check:
            OMISSIONS.write_text(rendered)

    for work in works:
        target = RESOURCES / f"{work['id']}.avif"
        thumb = RESOURCES / f"{work['id']}.thumb.avif"
        if not thumb.exists():
            stale.append(thumb)
        if work["bundled"]:
            source = FULL / f"{work['id']}.avif"
            if not target.exists() or target.read_bytes() != source.read_bytes():
                stale.append(target)
                if not args.check:
                    shutil.copyfile(source, target)
        elif target.exists():
            stale.append(target)
            if not args.check:
                target.unlink()
    known = {f"{w['id']}.avif" for w in works if w["bundled"]} | {f"{w['id']}.thumb.avif" for w in works}
    for extra in sorted(p for p in RESOURCES.iterdir() if p.name not in known):
        stale.append(extra)
        if not args.check:
            extra.unlink()

    for path in stale:
        print(("stale: " if args.check else "wrote: ") + str(path.relative_to(ROOT)))
    return 1 if args.check and stale else 0


if __name__ == "__main__":
    sys.exit(main())

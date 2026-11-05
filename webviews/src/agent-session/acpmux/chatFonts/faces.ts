// The interface font choices' bundled faces (chatUiFont.ts, FONTS.md), loaded only behind a dynamic
// import, so a chat on the default font never parses them. Imported, not `new URL(..., import.meta.url)`:
// the shipped pane inlines each as a data URL (scripts/agent-pane/bundle.mjs), since its CSP takes
// fonts only from data:.
import atkinson from "./AtkinsonHyperlegibleNext-latin-wght.woff2";
import cmuxSans from "./cmuxSans-latin-wght.woff2";
import geist from "./Geist-latin-wght.woff2";
import hanken from "./HankenGrotesk-latin-wght.woff2";
import plex from "./IBMPlexSans-latin-wght.woff2";
import roboto from "./Roboto-latin-wght.woff2";
import sourceSans from "./SourceSans3-latin-wght.woff2";
import { BUNDLED_FAMILY, type BundledChatFont } from "../chatUiFont";

const FILES: Record<BundledChatFont, string> = {
  roboto,
  plex,
  "source-sans": sourceSans,
  geist,
  "cmux-sans": cmuxSans,
  hanken,
  atkinson,
};

/** Declares `font`'s face (the Latin subset of its weight axis) in this document, once, and
 * resolves when it has loaded (or failed to, which leaves the stack's next face drawing). */
export async function installChatFontFace(font: BundledChatFont): Promise<void> {
  const id = `cmux-chat-font-${font}`;
  if (!document.getElementById(id)) {
    const style = document.createElement("style");
    style.id = id;
    style.textContent =
      `@font-face{font-family:"${BUNDLED_FAMILY[font]}";src:url(${FILES[font]}) format("woff2");` +
      "font-weight:100 900;font-style:normal;font-display:block}";
    document.head.append(style);
  }
  await document.fonts?.load(`400 1em "${BUNDLED_FAMILY[font]}"`).catch(() => undefined);
}

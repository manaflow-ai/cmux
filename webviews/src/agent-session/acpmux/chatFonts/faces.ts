// The interface font choices' bundled faces (chatUiFont.ts, FONTS.md), loaded only behind a dynamic
// import, so a chat on the default font never parses them. Imported, not `new URL(..., import.meta.url)`:
// the shipped pane inlines each as a data URL (scripts/agent-pane/bundle.mjs), since its CSP takes
// fonts only from data:. Each face is an `import()` of its own, so choosing one font loads that face
// alone (30 to 50 KB of woff2, base64 in its chunk), not all ten.
import { BUNDLED_FAMILY, type BundledChatFont } from "../chatUiFont";

const inter = () => import("./Inter-latin-wght.woff2");
const FILES: Record<BundledChatFont, () => Promise<{ default: string }>> = {
  "inter-tuned": inter,
  inter,
  roboto: () => import("./Roboto-latin-wght.woff2"),
  plex: () => import("./IBMPlexSans-latin-wght.woff2"),
  "source-sans": () => import("./SourceSans3-latin-wght.woff2"),
  geist: () => import("./Geist-latin-wght.woff2"),
  "cmux-sans": () => import("./cmuxSans-latin-wght.woff2"),
  "cmux-sans-squat": () => import("./cmuxSansSquat-latin-wght.woff2"),
  "cmux-sans-candy": () => import("./cmuxSansCandy-latin-wght.woff2"),
  "cmux-sans-open": () => import("./cmuxSansOpen-latin-wght.woff2"),
  hanken: () => import("./HankenGrotesk-latin-wght.woff2"),
  atkinson: () => import("./AtkinsonHyperlegibleNext-latin-wght.woff2"),
};

/** Declares `font`'s face (the Latin subset of its weight axis) in this document, once, and
 * resolves when it has loaded (or failed to, which leaves the stack's next face drawing). */
export async function installChatFontFace(font: BundledChatFont): Promise<void> {
  // By family: cmux Inter's two choices share one face.
  const id = `cmux-chat-font-${BUNDLED_FAMILY[font].replaceAll(" ", "-")}`;
  if (!document.getElementById(id)) {
    const file = await FILES[font]().then(
      (module) => module.default,
      () => null,
    );
    // Another call for the same family may have declared it while this one loaded.
    if (file !== null && !document.getElementById(id)) {
      const style = document.createElement("style");
      style.id = id;
      style.textContent =
        `@font-face{font-family:"${BUNDLED_FAMILY[font]}";src:url(${file}) format("woff2");` +
        "font-weight:100 900;font-style:normal;font-display:block}";
      document.head.append(style);
    }
  }
  await document.fonts?.load(`400 1em "${BUNDLED_FAMILY[font]}"`).catch(() => undefined);
}

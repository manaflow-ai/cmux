// The macOS system font's stand-in on a gallery host that has no SF Pro (Linux, where the browser
// tests run). `--font-ui` is `-apple-system, BlinkMacSystemFont, system-ui, sans-serif`
// (ui-font-pin.json): on a Mac the first name is SF Pro, but on Linux both Apple names match no
// installed face, so the text fell to the host's sans-serif (DejaVu Sans on the CI runners), a face
// wider and taller than SF. Every geometry test then measured that face: the composer's first line
// sat 0.63 px under the + button's center, labels that fit at a width no longer did (composer row
// steps, chip geometry, tab rows), and the grid lines moved (react-apps-check base red since
// ab5bc5a1, which took the gallery's bundled Inter away with the app's).
//
// Off a Mac the gallery names a face for the two Apple names, so the stack's first entry resolves
// as it does on a Mac. The face is the Latin Inter subset the chat's opt-in Inter choice ships
// (chatFonts/), the nearest face to SF Pro's metrics the repo carries, and the face these tests
// measured before. On a Mac nothing is declared: SF Pro draws, as in the app. Gallery only; the app
// declares no face for the system font.
import face from "../../agent-session/acpmux/chatFonts/Inter-latin-wght.woff2?url";

const APPLE_NAMES = ["-apple-system", "BlinkMacSystemFont"];

/** True where the browser can draw SF Pro for `-apple-system` itself. */
function hasSystemFont(): boolean {
  const platform =
    (navigator as Navigator & { userAgentData?: { platform?: string } }).userAgentData?.platform ?? navigator.platform;
  return /mac|iphone|ipad/i.test(platform) || /Mac OS X|iPhone|iPad/.test(navigator.userAgent);
}

/** Declares the stand-in face off a Mac, and loads it now (the frame's readiness waits on
 * document.fonts.ready), so a stage's first text is never drawn in the fallback and then moved. */
export function installSystemFontStandIn(): void {
  if (hasSystemFont() || document.getElementById("cmux-system-font-stand-in")) return;
  const style = document.createElement("style");
  style.id = "cmux-system-font-stand-in";
  style.textContent = APPLE_NAMES.map(
    (family) =>
      `@font-face{font-family:"${family}";src:url(${face}) format("woff2");` +
      "font-weight:100 900;font-style:normal;font-display:block}",
  ).join("");
  document.head.append(style);
  void document.fonts.load('400 1em "BlinkMacSystemFont"').catch(() => undefined);
}

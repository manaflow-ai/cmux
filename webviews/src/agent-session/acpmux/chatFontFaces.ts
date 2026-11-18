// The faces a font pack brings (`agentPane.display.font.faces`): a community typography theme from
// the app store sets the chat's interface, reply and code families (`font.uiFamily`,
// `font.proseFamily`, `code.family`) and ships their files with it, since the pane's CSP takes fonts
// only from data: URLs (chatFonts/faces.ts). The map is `{ "<family>" | "<family>:italic":
// "data:font/(woff2|woff|ttf|otf);base64,..." }`; anything else in it is dropped. Each entry is one
// @font-face, every weight (`1 1000`, so a variable face covers them all), in one managed <style>
// that is replaced when the map changes and removed when it empties.
//
// The row estimator measures text on a canvas, by a font string, and caches by that string: a
// family the pack declares counts in it only once its face has loaded (measurableStack), so the
// estimate measures what draws, and the load changing the string makes the caches measure again,
// as chatUiFont.ts does for the bundled faces.

export const CHAT_FONT_FACES_KEY = "agentPane.display.font.faces";
/// The managed <style>'s id.
export const CHAT_FONT_FACES_STYLE_ID = "cmux-chat-theme-faces";

export interface ChatFontFace {
  family: string;
  italic: boolean;
  /// The data URL, as given.
  src: string;
  /// The CSS `format()` hint for the URL's type.
  format: "woff2" | "woff" | "truetype" | "opentype";
}

const DATA_URL = /^data:font\/(woff2|woff|ttf|otf);base64,[A-Za-z0-9+/]+={0,2}$/;
const FORMATS = { woff2: "woff2", woff: "woff", ttf: "truetype", otf: "opentype" } as const;
/// One family name, as a face declares it: letters, digits, spaces and `_ . -`, never a stack.
const FACE_FAMILY = /^[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}$/;

/// The valid faces in `raw` (the faces key's value), in a stable order.
export function resolveChatFontFaces(raw: unknown): ChatFontFace[] {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return [];
  const faces: ChatFontFace[] = [];
  for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
    if (typeof value !== "string") continue;
    const match = DATA_URL.exec(value);
    if (!match) continue;
    const italic = key.endsWith(":italic");
    const family = (italic ? key.slice(0, -":italic".length) : key).trim();
    if (!FACE_FAMILY.test(family)) continue;
    faces.push({ family, italic, src: value, format: FORMATS[match[1] as keyof typeof FORMATS] });
  }
  return faces.sort((a, b) => a.family.localeCompare(b.family) || Number(a.italic) - Number(b.italic));
}

/// The @font-face rules for `faces`.
export function chatFontFaceCss(faces: readonly ChatFontFace[]): string {
  return faces
    .map(
      (face) =>
        `@font-face{font-family:"${face.family}";src:url("${face.src}") format("${face.format}");` +
        `font-weight:1 1000;font-style:${face.italic ? "italic" : "normal"};font-display:block}`,
    )
    .join("\n");
}

/// The families the current map declares (lower case), and those of them whose faces have loaded.
let declared = new Set<string>();
const loaded = new Set<string>();
/// The map last applied, by its rules, so the same map applies nothing again.
let appliedCss = "";
let generation = 0;

/// Declares `faces` in this document, replacing the pack's previous ones, and calls `ready` once
/// they have loaded (or failed to, which leaves each stack's next face drawing). Returns whether
/// anything changed.
export function applyChatFontFaces(faces: readonly ChatFontFace[], ready: () => void = () => {}): boolean {
  const css = chatFontFaceCss(faces);
  if (css === appliedCss) return false;
  appliedCss = css;
  const run = ++generation;
  declared = new Set(faces.map((face) => face.family.toLowerCase()));
  loaded.clear();
  if (typeof document === "undefined") return true;
  const existing = document.getElementById(CHAT_FONT_FACES_STYLE_ID);
  if (!faces.length) {
    existing?.remove();
    return true;
  }
  const style = existing ?? document.createElement("style");
  style.id = CHAT_FONT_FACES_STYLE_ID;
  style.textContent = css;
  if (!existing) document.head.append(style);
  const fonts = document.fonts;
  const loads = faces.map((face) =>
    (fonts?.load(`${face.italic ? "italic " : ""}400 1em "${face.family}"`) ?? Promise.resolve()).catch(
      () => undefined,
    ),
  );
  void Promise.all(loads).then(() => {
    if (run !== generation) return;
    for (const face of faces) loaded.add(face.family.toLowerCase());
    ready();
  });
  return true;
}

/// The names in a family stack, unquoted.
const names = (stack: string): string[] =>
  stack
    .split(",")
    .map((name) => name.trim().replace(/^["']|["']$/g, ""))
    .filter(Boolean);

/// A stack (`Folio Sans, Georgia, serif`) with each name that has a space quoted, as CSS and a
/// canvas font string read it.
export const quoteFamilyStack = (stack: string): string =>
  names(stack)
    .map((name) => (/\s/.test(name) ? `"${name}"` : name))
    .join(", ");

/// `stack` as the estimator's canvas can draw it now: without the pack's families whose faces have
/// not loaded yet. Empty when none remains.
export function measurableStack(stack: string): string {
  return quoteFamilyStack(
    names(stack)
      .filter((name) => !declared.has(name.toLowerCase()) || loaded.has(name.toLowerCase()))
      .join(", "),
  );
}

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

/// A cheap key of a faces value: its keys, each value's length and ends. A host push brings a new
/// object each time; this tells an unchanged map without validating and joining megabytes again.
/// Whether `stack`'s first family is one the faces map (CHAT_FONT_FACES_KEY) declares: a pack's own
/// face, as opposed to a font installed on the Mac. Reads only the map's keys and each value's
/// prefix, not the data.
export function declaresFirstFamily(raw: unknown, stack: string | null): boolean {
  if (!stack || !raw || typeof raw !== "object" || Array.isArray(raw)) return false;
  const first = stack
    .split(",")[0]
    .trim()
    .replace(/^["']|["']$/g, "")
    .toLowerCase();
  return Object.entries(raw as Record<string, unknown>).some(
    ([key, value]) =>
      typeof value === "string" &&
      value.startsWith("data:font/") &&
      key
        .replace(/:italic$/, "")
        .trim()
        .toLowerCase() === first,
  );
}

export function chatFontFacesKey(raw: unknown): string {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return "";
  return Object.entries(raw as Record<string, unknown>)
    .map(([key, value]) =>
      typeof value === "string" ? `${key}\u0000${value.length}\u0000${value.slice(0, 48)}${value.slice(-48)}` : key,
    )
    .join("\u0001");
}

/// The families the current map declares (lower case), and those of them whose faces have loaded.
let declared = new Set<string>();
const loaded = new Set<string>();
/// The map last applied, by its rules, so the same map applies nothing again.
let appliedCss = "";
let generation = 0;
/// Counts every change to what the pack's families draw as (a new map, a load). The estimator's
/// caches (pretext's own included) are keyed by the canvas font string, and a map replaced or
/// emptied can bring a family's string back to one measured under another face: the epoch, a family
/// no canvas has, keeps each face's measurements apart (measurableStack).
let epoch = 0;

/// Declares `faces` in this document, replacing the pack's previous ones, and calls `ready` once
/// they have loaded (or failed to, which leaves each stack's next face drawing). Returns whether
/// anything changed.
export function applyChatFontFaces(faces: readonly ChatFontFace[], ready: () => void = () => {}): boolean {
  const css = chatFontFaceCss(faces);
  if (css === appliedCss) return false;
  appliedCss = css;
  const run = ++generation;
  epoch += 1;
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
    epoch += 1;
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

/// The names CSS and a canvas read as keywords, never quoted.
const KEYWORDS =
  /^(serif|sans-serif|monospace|cursive|fantasy|math|emoji|fangsong|system-ui|ui-[a-z-]+|-apple-system|BlinkMacSystemFont)$/i;

/// A stack (`Folio Sans, Georgia, serif`) as CSS and a canvas font string read it: every name but a
/// generic keyword quoted, so a name such as `1942` or `Foo's` cannot invalidate the whole stack.
export const quoteFamilyStack = (stack: string): string =>
  names(stack)
    .map((name) => (KEYWORDS.test(name) ? name : `"${name}"`))
    .join(", ");

/// `stack` as the estimator's canvas can draw it now: without the pack's families whose faces have
/// not loaded yet, and once any map was applied, the faces' epoch (a name no canvas has) after them.
/// Empty when none remains.
export function measurableStack(stack: string): string {
  const kept = names(stack).filter((name) => !declared.has(name.toLowerCase()) || loaded.has(name.toLowerCase()));
  if (!kept.length) return "";
  return quoteFamilyStack([...kept, ...(epoch ? [`cmux-pack-${epoch}`] : [])].join(", "));
}

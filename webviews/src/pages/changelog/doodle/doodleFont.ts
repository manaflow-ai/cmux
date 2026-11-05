// The doodle's handwriting: Caveat (SIL Open Font License 1.1, Caveat-OFL.txt), weight 600, subset to
// Latin, Latin Extended, Vietnamese and Cyrillic. Inlined as a data URL (pages allow `font-src data:`)
// in a module the card imports only while the doodle shows, so no other page loads its bytes. The
// doodle's words sit in fixed boxes: the card's height never waits for the face.
import caveat from "./caveat.woff2?inline";

export const DOODLE_FONT_FAMILY = "cmux-doodle";

let loading: Promise<void> | null = null;

/** Adds the face to the document once; resolves when it is ready (or could not load: the
 *  fallback script face draws the words). */
export function loadDoodleFont(): Promise<void> {
  loading ??= (async () => {
    if (typeof FontFace === "undefined" || !globalThis.document?.fonts) return;
    try {
      const face = new FontFace(DOODLE_FONT_FAMILY, `url(${caveat}) format("woff2")`, { weight: "400 700" });
      document.fonts.add(await face.load());
    } catch {
      // The fallback face draws the words.
    }
  })();
  return loading;
}

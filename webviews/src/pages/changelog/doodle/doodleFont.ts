// The doodle's handwriting: Caveat (SIL Open Font License 1.1, Caveat-OFL.txt), weight 600, subset to
// Latin, Latin Extended, Vietnamese and Cyrillic. The app's page bundle inlines it as a data URL
// (bundle.mjs's `.woff2` loader; pages allow `font-src data:`), the gallery serves it as a file; the
// card imports this module only while the doodle shows. The doodle's words sit in fixed boxes: the
// card's height never waits for the face.
import caveat from "./caveat.woff2";

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

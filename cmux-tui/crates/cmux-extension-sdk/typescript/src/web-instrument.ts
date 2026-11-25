// cmux-extension-sdk/web/instrument: the app's own component kit, Instrument, for a web pane
// (cmux-extension-sdk/web). `adoptInstrument()` gives the page the kit's design tokens, read from
// the `--cmux-*` theme variables cmux keeps current on the page, and its `kit-*` classes
// (`<span class="kit-pill" data-tone="accent">`), as a constructed stylesheet, which the page's
// CSP allows. `INSTRUMENT_VERSION` is the kit version the sheet is (webviews/src/kit/version.ts).
//
// The sheet is made from the kit's sources at build time, never committed: run
// `bun cmux-tui/crates/cmux-extension-sdk/typescript/tools/gen-instrument.ts` before the page's
// build (it writes src/generated/instrument.ts).
//
//     import { adoptInstrument } from "cmux-extension-sdk/web/instrument"
//     adoptInstrument()
//     document.body.innerHTML = `<span class="kit-pill" data-tone="success">Live</span>`
import { INSTRUMENT_CSS, INSTRUMENT_VERSION } from "./generated/instrument"

export { INSTRUMENT_CSS, INSTRUMENT_VERSION }

const INSTRUMENT_SHEET = Symbol.for("cmux.instrument.sheet")

/**
 * Adds the Instrument kit's sheet (`INSTRUMENT_CSS`) to `doc` as a constructed stylesheet, once;
 * returns that sheet. Its colors follow cmux's theme as the page's `--cmux-*` variables do.
 */
export function adoptInstrument(doc: Document = document): CSSStyleSheet {
  const owner = doc as Document & { [INSTRUMENT_SHEET]?: CSSStyleSheet }
  const existing = owner[INSTRUMENT_SHEET]
  if (existing) return existing
  const View = doc.defaultView ?? globalThis
  const sheet = new (View as typeof globalThis).CSSStyleSheet()
  sheet.replaceSync(INSTRUMENT_CSS)
  doc.adoptedStyleSheets = [...doc.adoptedStyleSheets, sheet]
  owner[INSTRUMENT_SHEET] = sheet
  return sheet
}

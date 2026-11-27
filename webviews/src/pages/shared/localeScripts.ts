// The per-locale string scripts a page whose shipped build splits its table (split-strings.mjs:
// `locales/<code>.js` beside index.html, the Settings page and the agent pane) loads after its
// <head>: one loader for the agent pane's recovery (acpmux/i18n.ts `recoverStrings`) and for a
// live language switch (appLanguage.ts).

/** The `locales/en.js` script tags the head loads, as written there (`locales/en.js`, or a page's
 *  own prefix such as `/g/locales/en.js`). */
const ENGLISH_SCRIPT = /(^|\/)locales\/en\.js(\?.*)?$/;
/** An Apple localization code, the only text that goes into a script path. */
export const LANGUAGE_CODE = /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$/;
/** Retry delays after a failed load; the third failure gives up. */
const RETRY_MS = [250, 1000];

/** The source of every English strings script in `doc`'s head, in document order. */
export function englishScriptSources(doc: Document): string[] {
  return Array.from(doc.querySelectorAll<HTMLScriptElement>("script[src]"))
    .map((script) => script.getAttribute("src") ?? "")
    .filter((src) => ENGLISH_SCRIPT.test(src));
}

/** The script beside `english` (`locales/en.js`) that holds `language`'s table. */
export function localeScriptSource(english: string, language: string): string {
  return english.replace(/en\.js(\?.*)?$/, `${language}.js$1`);
}

/** Whether `doc` already has a script tag for `src` (the head loader's, or an earlier load). */
export function hasScript(doc: Document, src: string): boolean {
  return Array.from(doc.querySelectorAll<HTMLScriptElement>("script[src]")).some(
    (script) => script.getAttribute("src") === src,
  );
}

/** Appends a script for `src`, retrying a failed load twice; `done(ok)` runs once, when it loaded
 *  or after the last failure. */
export function loadScript(doc: Document, src: string, done: (ok: boolean) => void): void {
  const load = (attempt: number) => {
    const script = doc.createElement("script");
    script.src = src;
    script.addEventListener("load", () => done(true));
    script.addEventListener("error", () => {
      script.remove();
      const delay = RETRY_MS[attempt];
      if (delay === undefined) {
        done(false);
        return;
      }
      (doc.defaultView ?? globalThis).setTimeout(() => load(attempt + 1), delay);
    });
    doc.head.appendChild(script);
  };
  load(0);
}

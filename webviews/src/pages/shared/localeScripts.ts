// The per-locale string scripts a page whose shipped build splits its table (split-strings.mjs:
// `locales/<code>.js` beside index.html, the Settings page, Home and the agent pane; Home's subset of
// the agent pane's table in `pane-locales/<code>.js`) loads after its <head>: one loader for the
// recovery of a table the head failed to load (acpmux/i18n.ts `recoverStrings`, `reloadLocaleScripts`)
// and for a live language switch (appLanguage.ts).

declare global {
  /** `true` in the shipped pages build: scripts/pages/bundle.mjs defines it, so a branch only the
   *  dev server, the gallery and tests take (a page's whole 21-locale table) is not in the app.
   *  Undefined everywhere else. */
  // eslint-disable-next-line no-var
  var __cmuxShippedPages: boolean | undefined;
}

/** A shipped page's per-locale string folders. */
export type LocaleFolder = "locales" | "pane-locales";

/** The `locales/en.js` and `pane-locales/en.js` script tags the head loads, as written there
 *  (`locales/en.js`, or a page's own prefix such as `/g/locales/en.js`). */
const ENGLISH_SCRIPT = /(^|\/)((?:pane-)?locales)\/en\.js(\?.*)?$/;
/** An Apple localization code, the only text that goes into a script path. */
export const LANGUAGE_CODE = /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$/;
/** Retry delays after a failed load; the third failure gives up. */
const RETRY_MS = [250, 1000];

/** The source of every English strings script in `doc`'s head, in document order; only `folder`'s
 *  when given. */
export function englishScriptSources(doc: Document, folder?: LocaleFolder): string[] {
  return Array.from(doc.querySelectorAll<HTMLScriptElement>("script[src]"))
    .map((script) => script.getAttribute("src") ?? "")
    .filter((src) => {
      const match = ENGLISH_SCRIPT.exec(src);
      return match !== null && (folder === undefined || match[2] === folder);
    });
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

/**
 * A shipped page whose head did not install a table (its `folder/en.js` failed to load): loads
 * `folder/en.js` again, plus the locale the head's loader chose (`<html lang>`), by the path the
 * head names, each retried as `loadScript` does. Resolves once every load settled, loaded or not
 * (then the page shows English, or raw keys). With no such head tag (not a shipped page) it
 * resolves at once. The shipped build keeps no second, inline copy of the table for this.
 */
export function reloadLocaleScripts(
  folder: LocaleFolder,
  doc: Document | undefined = globalThis.document,
): Promise<void> {
  const english = doc?.head ? englishScriptSources(doc, folder)[0] : undefined;
  if (!doc || !english) return Promise.resolve();
  const sources = [english];
  const language = doc.documentElement.lang;
  if (language && language !== "en" && LANGUAGE_CODE.test(language))
    sources.push(localeScriptSource(english, language));
  return Promise.all(sources.map((src) => new Promise<void>((done) => loadScript(doc, src, () => done())))).then(
    () => undefined,
  );
}

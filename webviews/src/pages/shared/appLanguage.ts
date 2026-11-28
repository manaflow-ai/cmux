// The app's language for every web surface (Settings > General > Language, `app.language`). The
// host calls `window.__cmuxSetAppLanguage(code)` in every page, on load and whenever the setting
// changes: `code` is a shipped Apple code ("ja", "pt-BR") or null for System, which follows
// `navigator.languages` (WebKit fixes those at app launch from the app's preferred localizations).
// A host that runs before this module may set `window.__cmuxAppLanguage` instead.
//
// A change loads the target locale's strings scripts on a page whose shipped build splits its
// table per locale (localeScripts.ts), then dispatches `languagechange` on the window, so every
// existing listener (shared/i18n.ts, the agent pane's store, the Settings page) resolves again
// through `appLanguages()`. Resolution stays shared/i18n.ts `resolveLanguage`.
import { resolveLanguage } from "./i18n";
import { englishScriptSources, hasScript, LANGUAGE_CODE, loadScript, localeScriptSource } from "./localeScripts";

declare global {
  // eslint-disable-next-line no-var
  var __cmuxAppLanguage: string | null | undefined;
  // eslint-disable-next-line no-var
  var __cmuxSetAppLanguage: ((code: string | null, refresh?: boolean) => void) | undefined;
  /** The locales a split strings table ships (split-strings.mjs's head loader writes it). */
  // eslint-disable-next-line no-var
  var __cmuxStringLocales: readonly string[] | undefined;
}

/** A shipped code, or null for System (null, "system", or anything that is not a language code). */
function normalize(code: unknown): string | null {
  if (typeof code !== "string") return null;
  const trimmed = code.trim();
  if (!trimmed || trimmed === "system" || !LANGUAGE_CODE.test(trimmed)) return null;
  return trimmed;
}

let override: string | null = normalize(globalThis.__cmuxAppLanguage);
let generation = 0;

/** The language the setting picked, or null when it is System. */
export function appLanguageOverride(): string | null {
  return override;
}

/** The app's preferred localizations as WebKit reports them (fixed at launch): what System means,
 *  and the language the app's native menus use. */
export function navigatorLanguages(): readonly string[] {
  const nav = globalThis.document?.defaultView?.navigator ?? globalThis.navigator;
  return nav?.languages?.length ? nav.languages : [nav?.language ?? "en"];
}

/** The languages every web surface resolves its strings against: the setting's, else System's. */
export function appLanguages(): readonly string[] {
  return override ? [override] : navigatorLanguages();
}

function currentWindow(): Window | undefined {
  return globalThis.document?.defaultView ?? (globalThis.window as Window | undefined);
}

/** Loads `language`'s strings scripts beside every split table's English script that lacks them. */
function loadLocale(language: string, refresh = false): Promise<void> | null {
  const doc = globalThis.document;
  if (!doc?.head || language === "en" || !LANGUAGE_CODE.test(language)) return null;
  const sources = englishScriptSources(doc).map((english) => localeScriptSource(english, language));
  if (refresh) {
    for (const src of sources) {
      for (const script of Array.from(doc.querySelectorAll<HTMLScriptElement>("script[src]"))) {
        if (script.getAttribute("src") === src) script.remove();
      }
    }
  }
  const missing = sources.filter((src) => !hasScript(doc, src));
  if (missing.length === 0) return null;
  return Promise.all(missing.map((src) => new Promise<void>((done) => loadScript(doc, src, () => done())))).then(
    () => undefined,
  );
}

/** The locale a split page should hold for the app's languages now. */
function targetLocale(): string {
  return resolveLanguage(appLanguages(), globalThis.__cmuxStringLocales ?? ["en"]);
}

function announce(): void {
  const view = currentWindow();
  // The window's own Event class (a test's jsdom window refuses another realm's events).
  const WindowEvent = (view as unknown as { Event?: typeof Event } | undefined)?.Event ?? Event;
  view?.dispatchEvent(new WindowEvent("languagechange"));
}

/**
 * Sets the app's language (null or "system": System) and re-renders every surface in it once its
 * strings are in. Idempotent: the same value again does nothing. Resolves when the change is out.
 */
export function setAppLanguage(code: string | null | undefined, refresh = false): Promise<void> {
  const next = normalize(code);
  const view = currentWindow() as (Window & typeof globalThis) | undefined;
  if (view) view.__cmuxAppLanguage = next;
  if (next === override && !refresh) return Promise.resolve();
  override = next;
  const mine = ++generation;
  const loading = loadLocale(next ?? targetLocale(), refresh);
  if (!loading) {
    announce();
    return Promise.resolve();
  }
  // A newer call announces its own language; this one's strings stay loaded for a later switch.
  return loading.then(() => {
    if (mine === generation) announce();
  });
}

/**
 * Installs the host's hook, `window.__cmuxSetAppLanguage`, once per page window: page entries call
 * it (createPageClient, the agent pane's mount), never a module load, so importing the strings stays
 * free of globals. It goes on the page's window, the way busyWatchdog.ts does: in WebKit that is
 * the page's global, so the host's call reaches it; a test's jsdom window takes it away with it, so
 * no test file leaves it behind (test/support/leakDetector.ts). No window: no host can call it.
 * A language the host set before the page ran may lack its tables (the head loader ran first):
 * once they are in, every surface resolves again.
 */
export function installAppLanguage(win: (Window & typeof globalThis) | undefined = globalThis.window): void {
  if (!win || win.__cmuxSetAppLanguage) return;
  win.__cmuxSetAppLanguage = (code, refresh = false) => void setAppLanguage(code, refresh);
  const pending = normalize(win.__cmuxAppLanguage);
  if (pending && pending !== override) {
    void setAppLanguage(pending);
  } else if (override) {
    void loadLocale(override)?.then(() => announce());
  }
}

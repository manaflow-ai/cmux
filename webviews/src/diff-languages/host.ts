// How a host hands the diff viewer its user languages (`<config dir>/diff/languages/`, see
// pack.ts for the folder format). Two entry points, one shape (`DiffLanguagePack`):
//   - at load: `payload.languages` in the page config;
//   - on change: `window.cmuxDiffViewerLanguages.apply(pack)`, which replaces the previous pack,
//     re-detects every open file and returns `{languages, warnings}`.
// Swift calls `apply` through evaluateJavaScript; the pane protocol will deliver the same object
// as an event. New languages and overrides apply at once; when an already loaded grammar
// changed, the report says `reloadRequired` and the host reloads the page.
import type { DiffLanguagePack } from "./pack";
import { diffLanguages, type DiffLanguageReport } from "./registry";

export type DiffLanguageHostAPI = {
  apply(pack: DiffLanguagePack): DiffLanguageReport;
  /// The last report, for the debug socket (`browser eval`).
  report(): DiffLanguageReport;
};

declare global {
  interface Window {
    cmuxDiffViewerLanguages?: DiffLanguageHostAPI;
  }
}

export function installDiffLanguageHostAPI(initialPack: unknown, target: Window | undefined = globalThis.window) {
  let last: DiffLanguageReport = { languages: [], warnings: [] };
  const apply = (pack: unknown) => {
    last = diffLanguages.install(pack);
    if (typeof document !== "undefined") {
      document.documentElement.dataset.cmuxDiffUserLanguages = String(last.languages.length);
      document.documentElement.dataset.cmuxDiffLanguageWarnings = String(last.warnings.length);
    }
    return last;
  };
  if (initialPack != null) apply(initialPack);
  const api: DiffLanguageHostAPI = { apply, report: () => last };
  if (target) target.cmuxDiffViewerLanguages = api;
  return api;
}

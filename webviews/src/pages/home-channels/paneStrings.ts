// The agent pane's rows that agent runs reuse (tool calls, shell blocks, diffs) read their strings
// from the pane's table (agent-session/acpmux/i18n.ts), which the pane's own page loads into
// `__cmuxPaneStrings`. This page uses only the keys those rows use
// (generated/pane-strings.json, scripts/pages/gen-strings.mjs `home-channels-pane`), then picks
// the pane language again now that the table has languages.
// As shipped (build-pages-web.sh SPLIT_PANE_STRINGS), the head's pane-locales/<locale>.js scripts
// have already installed English and the app's language, so the 21-locale subset (about 430 KB) is
// not in the startup JS. The dev server, the gallery and a shipped page whose locale script failed
// load the whole subset, as a chunk of its own.
import { paneLanguage, setPaneLanguage } from "../../agent-session/acpmux/i18n";

if (!globalThis.__cmuxPaneStrings?.en) {
  const subset = (await import("./generated/pane-strings.json")).default;
  globalThis.__cmuxPaneStrings = { ...subset, ...globalThis.__cmuxPaneStrings };
}
setPaneLanguage(paneLanguage());

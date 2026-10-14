// The agent pane's rows that agent runs reuse (tool calls, shell blocks, diffs) read their strings
// from the pane's table (agent-session/acpmux/i18n.ts), which the pane's own page loads into
// `__cmuxPaneStrings`. This page installs only the keys those rows use
// (generated/pane-strings.json, scripts/pages/gen-strings.mjs `home-channels-pane`), then picks
// the pane language again now that the table has languages.
import { paneLanguage, setPaneLanguage } from "../../agent-session/acpmux/i18n";
import table from "./generated/pane-strings.json";

globalThis.__cmuxPaneStrings ??= table;
setPaneLanguage(paneLanguage());

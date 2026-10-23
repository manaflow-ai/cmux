// The pull request chips' hover card (ChangePullRequest.tsx) is the agent pane's, and reads its
// strings from the pane's table (agent-session/acpmux/i18n.ts). This page installs only the keys
// the card uses (generated/pane-strings.json, scripts/pages/gen-strings.mjs `changelog-pane`), then
// picks the pane language again now that the table has languages.
import { paneLanguage, setPaneLanguage } from "../../agent-session/acpmux/i18n";
import table from "./generated/pane-strings.json";

globalThis.__cmuxPaneStrings ??= table;
setPaneLanguage(paneLanguage());

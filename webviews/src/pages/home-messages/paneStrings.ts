// The agent pane's rows and parts this page reuses read their strings from the pane's table
// (agent-session/acpmux/i18n.ts). Like the Channels page (home-channels/paneStrings.ts), this
// installs only the keys they use: the Channels rows' (agent runs), the composer's mic and the
// link chips' hover card (generated/pane-strings.json, gen-strings.mjs `home-messages-pane`, a
// superset of `home-channels-pane`), then picks the pane language again.
import { paneLanguage, setPaneLanguage } from "../../agent-session/acpmux/i18n";
import table from "./generated/pane-strings.json";

globalThis.__cmuxPaneStrings ??= table;
setPaneLanguage(paneLanguage());

// Settings > Agents > Harnesses draws the agent pane's plan usage card under each account
// (components/ProviderAccounts.tsx), and the card reads its strings from the pane's table
// (agent-session/acpmux/i18n.ts). This page installs only the card's keys (generated/pane-strings.json,
// scripts/pages/gen-strings.mjs `settings-pane`), then picks the pane language again now that the
// table has languages. Without it the shipped page showed the raw keys (`planUsage.window.session`).
import { paneLanguage, setPaneLanguage } from "../../agent-session/acpmux/i18n";
import table from "./generated/pane-strings.json";

globalThis.__cmuxPaneStrings ??= table;
setPaneLanguage(paneLanguage());

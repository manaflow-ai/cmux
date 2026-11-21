// The scene's failure row (apps/scene/SceneFailure.tsx) reads its strings from the agent pane's table
// (agent-session/acpmux/i18n.ts). This page installs only the keys it uses (generated/strings.json,
// gen-strings.mjs `app-scene`: the app platform's `apps.failure.` and Reload keys), then picks the
// pane language again, as the Messages page does (home-messages/paneStrings.ts).
import { paneLanguage, setPaneLanguage } from "../../agent-session/acpmux/i18n";
import table from "./generated/strings.json";

globalThis.__cmuxPaneStrings ??= table;
setPaneLanguage(paneLanguage());

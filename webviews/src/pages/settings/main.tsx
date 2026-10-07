// Boots the Settings page (`cmux-page://cmux.settings/`). In the app the host installs the
// `cmuxPage` bridge (pageClient.ts); in the browser dev loop (vite.config.settings-page.mjs, or
// `?mock`) the in-memory mock provider stands in for the app.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import "../../ui/ui.css";
import { createPageClient } from "../shared/pageClient";
import { createMockClient } from "./mockProvider";
import { mountSettingsPage } from "./mount";
import "./styles.css";
import "./layout.css";
import { installCatalog } from "./strings";

// The dev server has no locales/*.js: install the full table there. The production bundle drops
// this branch (NODE_ENV is defined as production), so the 21-locale table never ships inline.
if (process.env.NODE_ENV !== "production" && !globalThis.__cmuxStrings) {
  installCatalog((await import("./generated/strings.json")).default as Record<string, Record<string, string>>);
}

const bridge = new URLSearchParams(location.search).has("mock") ? null : createPageClient();
void mountSettingsPage(document.getElementById("root")!, bridge ?? createMockClient().client);

// Boots the Settings page (`cmux-page://cmux.settings/`). In the app the host installs the
// `cmuxPage` bridge (pageClient.ts); in the browser dev loop (vite.config.settings-page.mjs, or
// `?mock`) the in-memory mock provider stands in for the app.
import { createPageClient } from "../shared/pageClient";
import { createMockClient } from "./mockProvider";
import { mountSettingsPage } from "./mount";
import "./styles.css";

const bridge = new URLSearchParams(location.search).has("mock") ? null : createPageClient();
void mountSettingsPage(document.getElementById("root")!, bridge ?? createMockClient().client);

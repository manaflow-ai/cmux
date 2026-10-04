// Dev entry of the Settings page (vite.config.settings-page.mjs): the page on the mock
// `cmux.settings` provider. In the app the shared page shell mounts the page with the page
// client (webviews/src/pages/shared/pageClient.ts) through `mountSettingsPage`.
import { createMockClient } from "./mockProvider";
import { mountSettingsPage } from "./mount";

void mountSettingsPage(document.getElementById("root")!, createMockClient().client);

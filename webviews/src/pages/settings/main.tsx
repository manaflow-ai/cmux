// Boots the Settings page (`cmux-page://cmux.settings/`). In the app the host installs the
// `cmuxPage` bridge (pageClient.ts); in the browser dev loop (vite.config.settings-page.mjs, or
// `?mock`) the in-memory mock provider stands in for the app.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import "../../ui/ui.css";
import { createPageClient } from "../shared/pageClient";
import { openPageState } from "../shared/pageState";
import { createMockClient } from "./mockProvider";
import { SETTINGS_PAGE, mountSettingsPage } from "./mount";
import "./page.css";
import "./tailwind.css";
import { installCatalog } from "./strings";

// The dev server has no locales/*.js: install the full table there. The production bundle drops
// this branch (NODE_ENV is defined as production), so the 21-locale table never ships inline.
if (process.env.NODE_ENV !== "production" && !globalThis.__cmuxStrings) {
  installCatalog((await import("./generated/strings.json")).default as Record<string, Record<string, string>>);
}

const search = new URLSearchParams(location.search);
const bridge = search.has("mock") ? null : createPageClient();
// Before the router reads the fragment: a restored document shows the section, search and focus it
// had moved on to. They are all the route's, and a form with typed values keeps its tab from being
// discarded at all (useUnsavedForm), so the page saves only its route and scroll.
openPageState(bridge, SETTINGS_PAGE).keep(() => null);
let mock = bridge ? undefined : createMockClient().client;
// The dev server and tests can give the mock the app's timing (mockTiming.ts); production drops this.
if (mock && process.env.NODE_ENV !== "production") mock = (await import("./mockTiming")).withMockTiming(mock, search);
void mountSettingsPage(document.getElementById("root")!, bridge ?? mock!);

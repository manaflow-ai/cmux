// Latency harness page for Settings (src/pages/settings): the shipped page over the in-memory mock
// provider, every call answering after the host delay (`?hostDelay=`, default 40 ms; mockTiming.ts),
// as the app's bridge does. The route is the fragment (`#/settings/general`).
import "../../src/pages/shared/desktop";
import "../../src/ui/ui.css";
import "../../src/pages/settings/page.css";
import "../../src/pages/settings/tailwind.css";
import strings from "../../src/pages/settings/generated/strings.json";
import { createMockClient } from "../../src/pages/settings/mockProvider";
import { withMockTiming } from "../../src/pages/settings/mockTiming";
import { mountSettingsPage } from "../../src/pages/settings/mount";
import { installCatalog } from "../../src/pages/settings/strings";
import { hostDelay } from "./mock-host";

installCatalog(strings as Record<string, Record<string, string>>);
const client = withMockTiming(createMockClient().client, new URLSearchParams({ latency: String(hostDelay()) }));
void mountSettingsPage(document.getElementById("root")!, client);

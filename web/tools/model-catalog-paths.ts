import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const webDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
/** What /api/models/v1 serves before its first live fetch and during an outage. */
export const SNAPSHOT_PATH = resolve(webDir, "data/model-catalog/snapshot.json");
/** The identical copy acpmux bundles as its offline and first-run catalog. */
export const BUNDLED_CATALOG_PATH = resolve(webDir, "../cmux-tui/crates/acpmux/catalog/models-v1.json");
/** The agent pane's copy. Decision: one snapshot only; the pane must import SNAPSHOT_PATH instead. */
export const WEBVIEW_CATALOG_COPY_PATH = resolve(webDir, "../webviews/src/agent-session/acpmux/generated/model-catalog-snapshot.json");

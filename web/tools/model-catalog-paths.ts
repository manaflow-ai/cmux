import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const webDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
/** What /api/models/v1 serves before its first live fetch and during an outage. */
export const SNAPSHOT_PATH = resolve(webDir, "data/model-catalog/snapshot.json");
/** The identical copy acpmux bundles as its offline and first-run catalog. */
export const BUNDLED_CATALOG_PATH = resolve(webDir, "../cmux-tui/crates/acpmux/catalog/models-v1.json");

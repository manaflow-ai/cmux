// Dev server only (/diff/, dev-server/plugins.ts): stands in for the page the `cmux diff` CLI writes.
// The dev server answers /__cmux-diff/config with a payload whose transport is `fetch` to its own
// /__cmux-diff/rpc, which runs the real cmux-diff-sidecar over stdio the way the app's `cmuxDiff`
// handler does. The stylesheet is imported normally (the dev config stubs the shipped `?inline`
// copy) so CSS edits hot-update. Query parameters pick the source: `?source=branch&base=HEAD~5`
// (default), `?source=unstaged`, `?source=staged`; `&layout=unified` switches the layout.
import "../styles.css";
import { DEFAULT_DIFF_VIEWER_LABELS } from "../labels";
import type { DiffViewerConfig } from "../types";

const response = await fetch(`/__cmux-diff/config${location.search}`, { cache: "no-store" });
if (!response.ok) throw new Error(`cmux diff dev config failed (${response.status}): ${await response.text()}`);
const config = (await response.json()) as DiffViewerConfig;
config.payload = { ...config.payload, labels: { ...DEFAULT_DIFF_VIEWER_LABELS, ...config.payload?.labels } };
const element = document.createElement("script");
element.type = "application/json";
element.id = "cmux-diff-viewer-config";
element.textContent = JSON.stringify(config);
document.head.append(element);
// main.tsx is a script (no exports); import the surface it would pick.
const { mountDiffSurface } = await import("../surfaces/diffSurface");
const root = document.getElementById("root");
if (!root) throw new Error("Missing cmux webview root");
mountDiffSurface(root);
// The dev server pushes the languages folder again whenever a file in it changes.
import.meta.hot?.on("cmux-diff-languages", (pack) => {
  const report = window.cmuxDiffViewerLanguages?.apply(pack);
  console.info("cmux diff languages applied", JSON.stringify(report));
  if (report?.reloadRequired) location.reload();
});

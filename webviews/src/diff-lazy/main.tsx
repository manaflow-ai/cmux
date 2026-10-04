// Prototype entry (bench/perf/lazy/index.html on the dev server, the prototype's flag):
// summary first, then the viewer; the hunks load as the virtualizer renders each file.
import "../styles.css";
import { createRoot } from "react-dom/client";
import { fetchRpc, type LazyFile } from "./lazy-model";
import { LazyViewer, type LazyMetrics, type LazyStats } from "./LazyViewer";

const metrics: LazyMetrics = { patchCalls: 0, patchedFiles: 0, rustMs: [] };
(window as any).__lazyMetrics = metrics;
const response = await fetch(`/__cmux-diff/config${location.search}`, { cache: "no-store" });
const config = await response.json();
const payload = config.payload;
const repoRoot = payload.sessionSource.repoRoot as string;
const baseRef = (payload.sessionSource.baseRef as string) ?? "HEAD~1";
const rpc = fetchRpc(payload.transport.endpoint, payload.capabilityToken, repoRoot);
const summary = await rpc<{ base: string; files: LazyFile[]; rustMs: number }>("lazySummary", { baseRef });
metrics.summaryMs = performance.now();
metrics.rustMs.push(summary.rustMs);
document.body.dataset.streamFileCount = String(summary.files.length);
// Stats read every blob, so they stream after the list and never block it.
void rpc<{ stats: LazyStats; rustMs: number }>("lazyStats", { base: summary.base }).then((result) => {
  metrics.statsMs = performance.now();
  metrics.rustMs.push(result.rustMs);
});
const root = document.getElementById("root")!;
createRoot(root).render(
  <LazyViewer
    rpc={rpc}
    base={summary.base}
    files={summary.files}
    appearancePayload={payload.appearance}
    metrics={metrics}
  />,
);

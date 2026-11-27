// l10n-allow-file: bench fixture rows, not shipped UI.
// The real Task Manager page over N processes (`#n=2000`), for bench/task-manager-rows.bench.ts.
// `benchMountMs` is the time from render() to the first painted frame; `benchStore` is the page's
// store, so the bench can push a sample (every row's numbers change) or sort a column.
import "../../src/pages/shared/desktop";
import "../../src/pages/shared/pageBase.css";
import "../../src/pages/task-manager/styles.css";
import { createRoot } from "react-dom/client";
import { createStrings } from "../../src/pages/shared/i18n";
import table from "../../src/pages/task-manager/generated/strings.json";
import { TaskManagerRoot } from "../../src/pages/task-manager/TaskManagerPage";
import { TaskManagerStore } from "../../src/pages/task-manager/store";
import type { TaskManagerRow, TaskManagerSnapshot } from "../../src/pages/task-manager/types";
import { UiProvider } from "../../src/ui/UiProvider";

declare global {
  interface Window {
    benchReady: boolean;
    benchMountMs: number;
    benchStore: TaskManagerStore;
    benchSample: (revision: number) => TaskManagerSnapshot;
  }
}

const params = new URLSearchParams(location.hash.slice(1));
const n = Number(params.get("n") ?? 2000);
const row = (index: number, revision: number): TaskManagerRow => {
  const cpu = ((index * 37 + revision * 11) % 997) / 10;
  const memoryBytes = (index * 7919 + revision * 104729) % 2_000_000_000;
  return {
    id: `local:${10_000 + index}`,
    host: "local",
    pid: 10_000 + index,
    task: `Terminal tab ${index} · zsh`,
    name: index % 3 ? "zsh" : "node",
    cpu,
    cpuText: `${cpu.toFixed(1)}%`,
    memoryBytes,
    memoryText: `${(memoryBytes / 1_048_576).toFixed(1)} MB`,
    refusal: index % 5 ? null : "A daemon",
  };
};
window.benchSample = (revision) => ({
  revision,
  rows: Array.from({ length: n }, (_, index) => row(index, revision)),
  total: `CPU ${revision}% · Memory 1.2 GB`,
});
const root = document.getElementById("root")!;
const strings = createStrings(table, ["en"]);
const store = new TaskManagerStore(null, { snapshot: window.benchSample(1) });
window.benchStore = store;
const started = performance.now();
createRoot(root).render(
  <UiProvider container={root}>
    <TaskManagerRoot store={store} strings={strings} />
  </UiProvider>,
);
requestAnimationFrame(() =>
  setTimeout(() => {
    window.benchMountMs = performance.now() - started;
    window.benchReady = true;
  }, 0),
);

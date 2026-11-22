// The dev server's first script on every page it serves (dev-server/plugins.ts perfBudgetsDevEntry):
// starts the runtime perf budgets (perfBudgets.ts) before React loads, so its devtools hook sees
// every root. Production bundles never include this file.
//
// The mode, first match wins: `window.__cmuxPerfBudgets = { mode }` set before the page loads (a
// test's init script), `?perf-budgets=warn|collect|throw|off` in the page URL, then
// `localStorage["cmux.perfBudgets"]`; `warn` otherwise. The handle is
// `window.__cmuxPerfBudgetsHandle` (its `violations` in collect mode).
import { startPerfBudgets, type PerfBudgetMode, type PerfBudgetsHandle, type PerfBudgetsOptions } from "./perfBudgets";

type DevWindow = Window & {
  __cmuxPerfBudgets?: PerfBudgetsOptions;
  __cmuxPerfBudgetsHandle?: PerfBudgetsHandle;
};

const MODES: readonly PerfBudgetMode[] = ["warn", "collect", "throw", "off"];
const asMode = (value: unknown): PerfBudgetMode | undefined =>
  MODES.includes(value as PerfBudgetMode) ? (value as PerfBudgetMode) : undefined;

function storedMode(): PerfBudgetMode | undefined {
  try {
    return asMode(window.localStorage?.getItem("cmux.perfBudgets"));
  } catch {
    return undefined;
  }
}

if (import.meta.env.DEV) {
  const win = window as DevWindow;
  if (!win.__cmuxPerfBudgetsHandle) {
    const options = win.__cmuxPerfBudgets ?? {};
    const mode =
      asMode(options.mode) ??
      asMode(new URLSearchParams(location.search).get("perf-budgets")) ??
      storedMode() ??
      "warn";
    try {
      win.__cmuxPerfBudgetsHandle = startPerfBudgets(win, { ...options, mode });
    } catch (error) {
      // A budget that cannot start never stops the page from loading.
      console.warn("[cmux perf budget] did not start:", error);
    }
    // A hot update rebuilds part of the page at once: not a frame, commit or shift to budget.
    import.meta.hot?.on("vite:beforeUpdate", () => win.__cmuxPerfBudgetsHandle?.settle());
  }
}

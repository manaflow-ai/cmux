// The browser test gate's script, first in every document of every page Playwright opens
// (support/perfBudgetGate.ts adds it to each context): the perf budgets that count rather than time
// (GATED_CLASSES), in collect mode, beside any instance the dev server starts (that one keeps its
// own mode and warnings). Each hit goes to the test through the context's binding as it is found,
// so a page that navigates or closes has already reported; `flush()` runs the checks that wait and
// returns every hit, for the test's checkpoints.
import { startPerfBudgets } from "../../src/devkit/perfBudgets";
import { GATED_CLASSES, type GateHit, type GatedClass } from "./perfBudgetBaseline";

type GateWindow = Window & {
  __cmuxPerfBudgetGate?: (hit: GateHit) => Promise<unknown> | undefined;
  __cmuxPerfBudgetGateHandle?: { flush(): GateHit[] };
};

const win = window as GateWindow;
if (!win.__cmuxPerfBudgetGateHandle) {
  const doc = Math.random().toString(36).slice(2, 10);
  const hits: GateHit[] = [];
  const handle = startPerfBudgets(win, {
    mode: "collect",
    classes: GATED_CLASSES,
    onViolation(violation) {
      const hit: GateHit = {
        id: `${doc}:${hits.length}`,
        kind: violation.kind as GatedClass,
        site: violation.site,
        message: violation.message,
        url: location.href,
      };
      hits.push(hit);
      try {
        // The binding's promise rejects when the page closes first; flush() already holds the hit.
        win.__cmuxPerfBudgetGate?.(hit)?.catch(() => {});
      } catch {
        // No binding (a page from before the gate): flush() still returns the hit.
      }
    },
  });
  Object.defineProperty(win, "__cmuxPerfBudgetGateHandle", {
    value: {
      flush() {
        handle.flush();
        return hits;
      },
    },
    enumerable: false,
  });
}

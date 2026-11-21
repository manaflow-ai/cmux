// An app scene's LazyVStack of N Rows (`#n=4000`) in a scroller the page owns, as New Tab draws an
// extension's page (`.nt-app-page`), for bench/scene-lazy-stack-visible-only.bench.ts. The store is the
// real one the host's scene stream feeds. `benchRowRenders` counts the rows that rendered since its last
// mark, read from each mounted row's fiber (test/support/mountedRowRenders.ts), so the page carries no counter.
import { createRoot } from "react-dom/client";
import "../../src/pages/shared/desktop";
import "../../src/pages/shared/pageBase.css";
import "../../src/agent-session/acpmux/newtab/appPage.css";
import { SceneRenderer } from "../../src/apps/scene/SceneRenderer";
import { SceneStore, type SceneOp } from "../../src/apps/scene/store";
import { mountedRowRenders } from "../support/mountedRowRenders";

declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    /** Retitles the `index`th row: one `update` op from the host. */
    benchChangeOne(index: number): void;
  }
}

const n = Number(new URLSearchParams(location.hash.slice(1)).get("n") ?? 1000);
const style = document.createElement("style");
style.textContent = "html, body, #root { height: 100%; margin: 0; } #root { display: flex; flex-direction: column; }";
document.head.append(style);

const store = new SceneStore();
const rows = Array.from({ length: n }, (_, index) => `r${index}`);
const ops: SceneOp[] = [{ op: "create", id: "list", type: "LazyVStack", props: { spacing: 2 } }];
for (const [index, id] of rows.entries())
  ops.push({
    op: "create",
    id,
    type: "Row",
    props: { title: `Pull request ${index}`, subtitle: `branch-${index}`, symbol: "arrow.triangle.pull", onTap: true },
  });
ops.push({ op: "children", id: "list", children: rows }, { op: "root", id: "list" });
store.apply(ops, true);

const page = document.createElement("div");
page.className = "nt-app-page";
const body = document.createElement("div");
body.className = "nt-app-page-body";
page.append(body);
document.getElementById("root")!.append(page);
createRoot(body).render(<SceneRenderer store={store} dispatch={() => {}} />);

window.benchRowRenders = mountedRowRenders(() => document.querySelectorAll(".cmux-app-scene-row-title"));
let revision = 0;
window.benchChangeOne = (index) =>
  store.apply([{ op: "update", id: `r${index}`, props: { title: `Changed ${++revision}` } }]);
const settle = () =>
  document.querySelector("[data-app-type=Row]") ? (window.benchReady = true) : requestAnimationFrame(settle);
requestAnimationFrame(settle);

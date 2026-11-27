// An app scene's LazyVStack of N Rows (`#n=4000`) in a scroller the page owns, as New Tab draws an
// extension's page (`.nt-app-page`), for bench/scene-lazy-stack-visible-only.bench.ts. The store is the
// real one the host's scene stream feeds. `benchRowRenders` counts the rows that rendered since its last
// mark, read from each mounted row's fiber (test/support/mountedRowRenders.ts), so the page carries no counter.
// `#groups=1` makes every third child a styled Group (a background, padding and a border, which its
// `display: contents` box does not draw) of two Rows; `#stack=VStack` draws the same children whole, as the
// layout a LazyVStack must keep. `#menus=1` gives each grouped Row a context menu (its open anchor and the
// popup's focus guards are fixed elements inside the Group).
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
    benchChangeOne(index?: number): void | Promise<void>;
  }
}

const hash = new URLSearchParams(location.hash.slice(1));
const n = Number(hash.get("n") ?? 1000);
const groups = hash.get("groups") === "1";
const menus = hash.get("menus") === "1";
const stackType = hash.get("stack") === "VStack" ? "VStack" : "LazyVStack";
const style = document.createElement("style");
style.textContent = "html, body, #root { height: 100%; margin: 0; } #root { display: flex; flex-direction: column; }";
document.head.append(style);

const store = new SceneStore();
const rows = Array.from({ length: n }, (_, index) => `r${index}`);
const ops: SceneOp[] = [{ op: "create", id: "list", type: stackType, props: { spacing: 2 } }];
for (const [index, id] of rows.entries())
  ops.push({
    op: "create",
    id,
    type: "Row",
    props: { title: `Pull request ${index}`, subtitle: `branch-${index}`, symbol: "arrow.triangle.pull", onTap: true },
  });
const children = groups
  ? rows.map((id, index) => {
      if (index % 3 !== 2) return id;
      const pair = [`${id}a`, `${id}b`];
      for (const [at, child] of pair.entries())
        ops.push({
          op: "create",
          id: child,
          type: "Row",
          props: {
            title: `Grouped ${index}.${at}`,
            onTap: true,
            ...(menus && { menu: [{ title: "Open" }, { title: "Copy" }] }),
          },
        });
      ops.push(
        {
          op: "create",
          id: `g${index}`,
          type: "Group",
          props: { background: "secondary", padding: 6, cornerRadius: 6, borderColor: "separator" },
        },
        { op: "children", id: `g${index}`, children: pair },
      );
      return `g${index}`;
    })
  : rows;
ops.push({ op: "children", id: "list", children }, { op: "root", id: "list" });
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
window.benchChangeOne = ((index: number) =>
  store.apply([{ op: "update", id: `r${index}`, props: { title: `Changed ${++revision}` } }])) as typeof window.benchChangeOne;
const settle = () =>
  document.querySelector("[data-app-type=Row]") ? (window.benchReady = true) : requestAnimationFrame(settle);
requestAnimationFrame(settle);

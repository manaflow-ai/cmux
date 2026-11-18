// Browser harness for the visible-only list tests (test/support/visibleLists.ts): `?case=NAME&n=N`
// mounts the case's list with N items and exposes its controls and the render counts as
// `window.__visibleList`, with the row renders of mounting it (through two frames after, as
// `mountCounts`). Each case is a `visible-lists/*.case.tsx` file whose default export is a
// VisibleListCase, so a list adds a file here instead of editing a shared registry.
import { renderCounts } from "./visibleListsHook";
import "../../src/pages/shared/desktop.css";
import "../../src/styles.css";
import "../../src/ui/ui.css";
import type { VisibleListCase } from "./visible-lists/case";

const cases = import.meta.glob<{ default: VisibleListCase }>("./visible-lists/*.case.tsx");

const params = new URLSearchParams(location.search);
const name = params.get("case") ?? "";
const n = Number(params.get("n") ?? "1000");
const load = cases[`./visible-lists/${name}.case.tsx`];
const root = document.getElementById("root")!;

(window as unknown as { __visibleList: unknown }).__visibleList = {
  renderCounts,
  ready: (async () => {
    if (!load) throw new Error(`no visible-lists case "${name}"`);
    const listCase = (await load()).default;
    renderCounts.start();
    const controls = await listCase.mount(root, n);
    await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
    renderCounts.stop();
    (window as unknown as { __visibleListControls: unknown }).__visibleListControls = controls;
    return {
      rowSelector: controls.rowSelector,
      rowComponents: controls.rowComponents,
      mountCounts: renderCounts.read(controls.rowComponents),
    };
  })(),
};

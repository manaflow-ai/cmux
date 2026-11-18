// A list whose rowSelector names no row: its rows carry no role, so `[role="option"]` matches
// nothing, and `open` must fail rather than count 0 renders. `&missing=1` leaves rowSelector out.
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { caseItems, type VisibleListCase, type VisibleListControls } from "./case";

function UnnamedRowsList({ n }: { n: number }) {
  return (
    <div className="case-list">
      {caseItems(Math.min(n, 40)).map((item) => (
        <div key={item.id}>{item.label}</div>
      ))}
    </div>
  );
}

const unnamedRowsCase: VisibleListCase = {
  mount(root, n) {
    flushSync(() => createRoot(root).render(<UnnamedRowsList n={n} />));
    const list = () => root.querySelector<HTMLElement>(".case-list")!;
    const controls: VisibleListControls = { rowSelector: '[role="option"]', rowComponents: [], scroller: list, list };
    if (new URLSearchParams(location.search).get("missing") === "1")
      return { ...controls, rowSelector: undefined } as unknown as VisibleListControls;
    return controls;
  },
};
export default unnamedRowsCase;

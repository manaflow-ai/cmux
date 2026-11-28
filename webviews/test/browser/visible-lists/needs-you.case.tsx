// l10n-allow-file: test fixture asks and chat names, not shipped UI.
// The header's Needs you list (needsYou/NeedsYou.tsx NeedsYouPanel) with N approvals, in a frame the
// size of its popover (360 by 520 px), with its own styles.
import { useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { NeedsYouPanel } from "../../../src/agent-session/acpmux/needsYou/NeedsYou";
import type { NeedsYouItem } from "../../../src/agent-session/acpmux/needsYou/model";
import type { NeedsYouActions } from "../../../src/agent-session/acpmux/needsYou/needsYouModel";
import type { VisibleListCase } from "./case";

const ASKED = Date.UTC(2026, 10, 18, 9, 0, 0);

const asks = (n: number): NeedsYouItem[] =>
  Array.from({ length: n }, (_, index) => ({
    id: `acpmux:p${index}`,
    kind: "approval" as const,
    sessionId: `s${index}`,
    ask: `Run step ${index}`,
    detail: index % 3 === 0 ? `bun test test/step-${index}.test.ts` : undefined,
    command: index % 3 === 0,
    who: { name: `Chat ${index}`, harness: "claude", chief: false },
    at: ASKED - index * 60_000,
    answers: [
      { id: `p${index}-yes`, label: "Allow", tone: "allow" as const },
      { id: `p${index}-no`, label: "Deny", tone: "deny" as const },
    ],
    permissionId: `p${index}`,
  }));

const actions: NeedsYouActions = {
  answer: () => new Promise(() => {}),
  goTo: () => {},
  ask: async () => undefined,
};

let changeOne = () => {};

function CaseNeedsYou({ n }: { n: number }) {
  const [items, setItems] = useState(() => asks(n));
  // In an effect, not at render, so the compiler keeps the component.
  useEffect(() => {
    changeOne = () =>
      setItems((previous) => previous.map((item, index) => (index === 2 ? { ...item, ask: `${item.ask}!` } : item)));
  }, []);
  return (
    <div className="acpmux-needs-you case-needs-you">
      <NeedsYouPanel items={items} actions={actions} />
    </div>
  );
}

const needsYouCase: VisibleListCase = {
  mount(root, n) {
    const style = document.createElement("style");
    style.textContent = ".case-needs-you { height: 520px; max-height: 520px; }";
    document.head.append(style);
    flushSync(() => createRoot(root).render(<CaseNeedsYou n={n} />));
    const list = () => root.querySelector<HTMLElement>(".acpmux-needs-you-list")!;
    return {
      rowSelector: ".acpmux-needs-you-item",
      rowComponents: ["NeedsYouRow"],
      scroller: list,
      list,
      changeOne: () => changeOne(),
    };
  },
};
export default needsYouCase;

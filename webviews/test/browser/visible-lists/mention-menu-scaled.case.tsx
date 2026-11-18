// The composer's @ picker (acpmux/MentionMenu.tsx) with N files, its rows `--ui-row-height` tall:
// at an interface scale of 1.1 that is 30.8 px a row.
import { useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { MentionMenu } from "../../../src/agent-session/acpmux/MentionMenu";
import type { MentionItem } from "../../../src/agent-session/acpmux/mentionItems";
import "../../../src/agent-session/acpmux/styles.css";
import { caseItems, type VisibleListCase } from "./case";
import { applyCaseScale } from "./scale";

function CaseMentionMenu({ n }: { n: number }) {
  const [items] = useState(() =>
    caseItems(n).map((item): MentionItem => ({
      kind: "file",
      key: item.id,
      path: `src/${item.label}.ts`,
      name: [{ text: `${item.label}.ts`, matched: false }],
      dir: [{ text: "src", matched: false }],
    })),
  );
  const [active, setActive] = useState(0);
  return (
    <MentionMenu
      state={{ kind: "done", results: [] }}
      items={items}
      active={active}
      onHover={setActive}
      onPick={(item) => (window as unknown as { __submitted: string[] }).__submitted.push(item.key)}
    />
  );
}

const mentionMenuCase: VisibleListCase = {
  mount(root, n) {
    (window as unknown as { __submitted: string[] }).__submitted = [];
    applyCaseScale();
    // The menu stands above the composer's box: the box sits low on the page.
    root.className = "acpmux-shell";
    root.style.cssText = "position: relative; margin-top: 360px; width: 520px; height: 40px;";
    flushSync(() => createRoot(root).render(<CaseMentionMenu n={n} />));
    const list = () => root.querySelector<HTMLElement>("[role='listbox']")!;
    return { rowSelector: '[role="option"]', rowComponents: ["ListboxRow"], scroller: list, list };
  },
};
export default mentionMenuCase;

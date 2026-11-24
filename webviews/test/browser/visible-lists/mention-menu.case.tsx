// acpmux/MentionMenu over ui/Listbox with N file rows, the composer owning the highlight as
// Composer.tsx does. Its cap is the sum of mentionItems.ts's parts (5 chats, 8 harnesses, 3 folders,
// 12 recent paths, FILE_SEARCH_LIMIT files): 78.
import { useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { MentionMenu } from "../../../src/agent-session/acpmux/MentionMenu";
import type { MentionItem } from "../../../src/agent-session/acpmux/mentionItems";
import { caseItems, type VisibleListCase } from "./case";

const itemsOf = (n: number): MentionItem[] =>
  caseItems(n).map((item) => ({
    kind: "file",
    key: `file:${item.id}`,
    path: `src/${item.id}.ts`,
    name: [{ text: item.label, matched: false }],
    dir: [{ text: "src", matched: false }],
  }));

let changeOne = () => {};

function CaseMentionMenu({ n }: { n: number }) {
  const [items, setItems] = useState(() => itemsOf(n));
  const [active, setActive] = useState(0);
  // In an effect, not at render: a component that writes outside itself at render is one the
  // compiler leaves uncompiled, and its callbacks would change every render.
  useEffect(() => {
    changeOne = () =>
      setItems((previous) =>
        previous.map((item, index) =>
          index === 2 && item.kind === "file" ? { ...item, name: [{ text: `${item.path}!`, matched: false }] } : item,
        ),
      );
  }, []);
  return (
    <MentionMenu
      state={{ kind: "done" } as never}
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
    const style = document.createElement("style");
    style.textContent =
      "#acpmux-mention-menu { height: 320px; overflow: auto; } .acpmux-mention-row { height: 28px; box-sizing: border-box; }";
    document.head.append(style);
    flushSync(() => createRoot(root).render(<CaseMentionMenu n={n} />));
    const list = () => root.querySelector<HTMLElement>("#acpmux-mention-menu")!;
    return {
      rowSelector: '[role="option"]',
      // The row wrapper is ui/Listbox's ListboxRow; the content is drawn inline in renderItem.
      rowComponents: ["ListboxRow", "Icon"],
      scroller: list,
      list,
      changeOne: () => changeOne(),
    };
  },
};
export default mentionMenuCase;

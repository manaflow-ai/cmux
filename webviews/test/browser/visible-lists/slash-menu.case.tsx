// acpmux/SlashMenu (the new tab's slash menu) over ui/Listbox, with N commands, the field owning the
// highlight as NewTabScreen.tsx does.
import { useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { SlashMenu } from "../../../src/agent-session/acpmux/SlashMenu";
import type { SlashMatch } from "../../../src/agent-session/acpmux/slashCommands";
import { caseItems, type VisibleListCase } from "./case";

const matchesOf = (n: number): SlashMatch[] =>
  caseItems(n).map((item) => ({
    command: { name: item.id, description: item.label, source: "agent" },
    ranges: [[0, 1]],
  }));

let changeOne = () => {};

function CaseSlashMenu({ n }: { n: number }) {
  const [matches, setMatches] = useState(() => matchesOf(n));
  const [active, setActive] = useState(0);
  // In an effect, not at render: a component that writes outside itself at render is one the
  // compiler leaves uncompiled, and its callbacks would change every render.
  useEffect(() => {
    changeOne = () =>
      setMatches((previous) =>
        previous.map((match, index) =>
          index === 2
            ? { ...match, command: { ...match.command, description: `${match.command.description}!` } }
            : match,
        ),
      );
  }, []);
  return (
    <SlashMenu
      matches={matches}
      active={active}
      empty="No commands"
      onHover={setActive}
      onPick={(command) => (window as unknown as { __submitted: string[] }).__submitted.push(command.name)}
    />
  );
}

const slashMenuCase: VisibleListCase = {
  mount(root, n) {
    (window as unknown as { __submitted: string[] }).__submitted = [];
    const style = document.createElement("style");
    style.textContent =
      "#acpmux-slash-menu { height: 320px; overflow: auto; } .acpmux-slash-row { height: 28px; box-sizing: border-box; }";
    document.head.append(style);
    flushSync(() => createRoot(root).render(<CaseSlashMenu n={n} />));
    const list = () => root.querySelector<HTMLElement>("#acpmux-slash-menu")!;
    return {
      rowSelector: '[role="option"]',
      // The row wrapper is ui/Listbox's ListboxRow; the content is drawn inline in renderItem.
      rowComponents: ["ListboxRow", "Highlighted"],
      scroller: list,
      list,
      changeOne: () => changeOne(),
    };
  },
};
export default slashMenuCase;

// The composer's + menu (Picker in ComposerPickers.tsx), the real ComposerPlusMenu with its own rows
// and N rows from the host's catalog (nativeComposerExtensions, which bounds neither), opened.
import { useMemo, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { ComposerPlusMenu } from "../../../src/agent-session/acpmux/ComposerPlusMenu";
import { PLUS_PICKER } from "../../../src/agent-session/acpmux/composerSelectors";
import { composerPlusRegistry, nativeComposerExtensions } from "../../../src/agent-session/acpmux/composerPlusRegistry";
import { openPicker } from "../../../src/agent-session/acpmux/pickerOpeners";
import { caseItems, type VisibleListCase } from "./case";
// The agent pane's sheets for the composer's menus (their height bounds among them), as its galleries load them.
import "../../../src/ui/popupSurface.css";
import "../../../src/agent-session/acpmux/styles.css";
import "../../../src/agent-session/acpmux/composerLocation.css";

let changeOne = () => {};
const sections = ["tools", "apps", "sessions", "tabs"];

function CasePlusMenu({ n }: { n: number }) {
  const [rows, setRows] = useState(() =>
    caseItems(n).map((item, index) => ({
      id: item.id,
      section: sections[Math.floor((index * sections.length) / n)],
      name: item.label,
      description: `open ${item.id}`,
    })),
  );
  changeOne = () => setRows((old) => old.map((row, index) => (index === 2 ? { ...row, name: `${row.name}!` } : row)));
  const entries = useMemo(() => composerPlusRegistry({ extensions: nativeComposerExtensions(rows) }), [rows]);
  return (
    <ComposerPlusMenu
      entries={entries}
      onCommand={() => undefined}
      onExtension={() => undefined}
      onSlash={() => undefined}
    />
  );
}

const composerPlusCase: VisibleListCase = {
  async mount(root, n) {
    root.style.cssText = "position: fixed; left: 16px; bottom: 16px; width: 420px;";
    flushSync(() => createRoot(root).render(<CasePlusMenu n={n} />));
    const trigger = root.querySelector<HTMLElement>(PLUS_PICKER)!;
    flushSync(() => openPicker(trigger.getAttribute("aria-label") ?? "Add"));
    const popup = () => document.querySelector<HTMLElement>(".ui-popup.acpmux-composer-plus")!;
    for (let tries = 0; !document.querySelector(".ui-popup.acpmux-composer-plus [role='menuitem']"); tries++) {
      if (tries > 200) throw new Error("the + menu did not open");
      await new Promise((done) => requestAnimationFrame(done));
    }
    return {
      rowSelector: '[role="menuitem"]',
      rowComponents: ["PickerMenuItem"],
      scroller: () => popup().querySelector<HTMLElement>(".ui-popup-scroll")!,
      list: popup,
      changeOne: () => changeOne(),
    };
  },
};
export default composerPlusCase;

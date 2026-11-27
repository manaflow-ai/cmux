// The composer's mode (access) menu, the real ComposerPickers, for a chat whose agent reports N modes
// (a harness without a mode menu of its own, so its modes are listed as it reports them), opened.
import { useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { ComposerPickers } from "../../../src/agent-session/acpmux/ComposerPickers";
import type { AcpmuxSnapshot } from "../../../src/agent-session/acpmux/model";
import { openPicker } from "../../../src/agent-session/acpmux/pickerOpeners";
import { caseItems, type VisibleListCase } from "./case";
// The agent pane's sheets for the composer's menus (their height bounds among them), as its galleries load them.
import "../../../src/ui/popupSurface.css";
import "../../../src/agent-session/acpmux/styles.css";
import "../../../src/agent-session/acpmux/composerLocation.css";

let changeOne = () => {};

function snapshotWith(modes: { id: string; name: string; description?: string }[]): AcpmuxSnapshot {
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "visible-lists",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog: [{ id: "case-agent", name: "Case agent", models: [{ id: "case-model", name: "Case model" }] }],
    summary: {
      sessionId: "visible-lists-mode",
      harness: "case-agent",
      model: "case-model",
      turnCount: 1,
      modes: { availableModes: modes, currentModeId: modes[Math.floor(modes.length / 2)]?.id },
    },
  };
}

function CaseModeMenu({ n }: { n: number }) {
  const [modes, setModes] = useState(() =>
    caseItems(n).map((item) => ({
      id: item.id,
      name: item.label,
      description: `what ${item.label} allows`,
    })),
  );
  // The row after the current one, which is in view (the menu opens at its current mode).
  changeOne = () =>
    setModes((old) =>
      old.map((mode, index) => (index === Math.floor(n / 2) + 1 ? { ...mode, name: `${mode.name}!` } : mode)),
    );
  return (
    <ComposerPickers
      snapshot={snapshotWith(modes)}
      harnessesListed
      onModel={() => undefined}
      onMode={() => undefined}
      onEffort={() => undefined}
      showPlan={false}
    />
  );
}

const composerModeCase: VisibleListCase = {
  async mount(root, n) {
    // The composer's chip row sits at the window's foot; the menu opens above it.
    root.style.cssText = "position: fixed; left: 16px; bottom: 16px; width: 420px;";
    flushSync(() => createRoot(root).render(<CaseModeMenu n={n} />));
    const trigger = root.querySelector<HTMLElement>(".acpmux-access-trigger")!;
    flushSync(() => openPicker(trigger.getAttribute("aria-label") ?? "Mode"));
    const popup = () => document.querySelector<HTMLElement>(".ui-popup.acpmux-access-menu")!;
    for (let tries = 0; !document.querySelector(".ui-popup.acpmux-access-menu [role='menuitemradio']"); tries++) {
      if (tries > 200) throw new Error("the mode menu did not open");
      await new Promise((done) => requestAnimationFrame(done));
    }
    return {
      rowSelector: '[role="menuitemradio"]',
      // A mode row's render: AccessModeRow, or before it (rows drawn inline) the ModeIcon each row drew.
      rowComponents: ["AccessModeRow", "ModeIcon"],
      scroller: () => popup().querySelector<HTMLElement>(".ui-popup-scroll")!,
      list: popup,
      changeOne: () => changeOne(),
    };
  },
};
export default composerModeCase;

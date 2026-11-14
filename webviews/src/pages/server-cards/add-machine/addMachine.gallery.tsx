// l10n-allow-file: gallery fixtures (sample host names), not shipped UI.
// The Add Machine card (`cmux-page://cmux.server-cards/#/add-machine`) over the dev loop's stand-in
// host: the field with the tailnet's machines, a run going well, ready, failed, and Check Machine with
// Fix. The running variants show the three ways a run's steps can draw (design/server-cards.md
// "Add Machine"); `progress` ships.
import { useEffect, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { createStrings } from "../../shared/i18n";
import table from "../generated/strings.json";
import { AddMachineCard, CHECKLIST_PICK, type ChecklistVariant } from "./AddMachineCard";
import { fixtures, MockAddMachineHost, mockCandidates } from "./mock";
import { AddMachineStore } from "./store";
import type { AddMachineStatus } from "./types";

type Props = {
  state: keyof typeof fixtures;
  destination?: string;
  noTailscale?: boolean;
  checklist?: ChecklistVariant;
};

function AddMachineGallery({ state, destination, noTailscale, checklist = CHECKLIST_PICK }: Props) {
  const [strings] = useState(() => createStrings(table));
  const [store] = useState(() => {
    const listeners = new Set<() => void>();
    const status: AddMachineStatus = state === "pick" ? fixtures.pick(destination) : fixtures[state]();
    const host = new MockAddMachineHost(
      () => listeners.forEach((listener) => listener()),
      status,
      noTailscale ? null : mockCandidates,
    );
    return new AddMachineStore({
      call: async <T,>(op: string, params?: unknown) => host.call(op, params) as T,
      subscribe: async (_stream: string, onEvent: (event: unknown) => void) => {
        const listener = () => onEvent({});
        listeners.add(listener);
        return () => void listeners.delete(listener);
      },
    });
  });
  useEffect(() => {
    void store.start();
    return () => store.stop();
  }, [store]);
  return (
    <div className="server-card-frame">
      <AddMachineCard store={store} strings={strings} variant={checklist} />
    </div>
  );
}

export default componentEntry<Props>({
  id: "pages.server-cards.add-machine",
  title: "Add Machine",
  area: "Pages",
  height: 520,
  covers: ["pages/server-cards/add-machine/AddMachineCard.tsx"],
  keywords: ["add machine", "check machine", "ssh", "tailnet", "enroll", "doctor"],
  load: async () => AddMachineGallery,
  styles: async () => {
    await import("../../shared/pageBase.css");
    await import("../../../ui/ui.css");
    await import("../styles.css");
    await import("./addMachine.css");
  },
  variants: {
    pick: {
      note: "The field with a tailnet host typed; the list greys ssh-off and offline machines and marks an agent peer.",
      props: { state: "pick", destination: "dev-box.tail1.ts.net" },
    },
    "no-tailscale": {
      note: "Without Tailscale the list hides and the field stays.",
      props: { state: "pick", destination: "leo@10.0.0.7", noTailscale: true },
    },
    "running-progress": {
      note: "Picked: a run going well is one line (Step 3 of 9) with Show Details.",
      props: { state: "running", checklist: "progress" },
    },
    "running-list": {
      note: "Variant: every step listed from the start.",
      props: { state: "running", checklist: "list" },
    },
    "running-rail": {
      note: "Variant: one glyph per step in a row, the running step named under it.",
      props: { state: "running", checklist: "rail" },
    },
    ready: { note: "Every step healthy: Done and Open Workspace.", props: { state: "ready" } },
    failed: {
      note: "A failed step opens the list with its detail and fix: Copy Details, Change Host, Try Again.",
      props: { state: "failed" },
    },
    check: { note: "Check Machine: the daemon failed; Fix runs doctor --fix.", props: { state: "check" } },
  },
});

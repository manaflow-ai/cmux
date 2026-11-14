// l10n-allow-file: gallery fixtures (sample machine names), not shipped UI.
// The right sidebar's Machines section (cmux-page://cmux.machines/): the same MachinesSection
// main.tsx mounts, over the mock `cmux.machines.*` host. The first three variants are the three
// layouts of `machines.section.style`; the shipped default is `compact` (design/machines-section.md
// says why).
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MachinesSection } from "./MachinesSection";
import { MockMachinesProvider, joinedRows, sampleRows, sampleSnapshot, thisMac } from "./mockProvider";
import { MachinesStore } from "./store";
import type { MachineRow, MachinesSnapshot } from "./types";

type Props = { snapshot?: MachinesSnapshot; asking?: string };

function MachinesGallery({ snapshot = sampleSnapshot, asking }: Props) {
  const [store] = useState(() => new MachinesStore(new MockMachinesProvider(snapshot)));
  const [strings] = useState(() => createStrings(table));
  useEffect(() => {
    void store.start().then(() => asking && store.askRemove(asking));
    return () => store.stop();
  }, [store, asking]);
  return <MachinesSection store={store} strings={strings} />;
}

const many: MachineRow[] = Array.from({ length: 300 }, (_, index) => ({
  id: `cloud-${index}`,
  name: `worker-${String(index + 1).padStart(3, "0")}`,
  kind: index % 3 === 0 ? "ssh" : "cloud",
  isLocal: false,
  isConnected: index % 4 !== 0,
  isConnecting: index % 7 === 0 && index % 4 === 0,
}));

export default componentEntry<Props>({
  id: "pages.machines",
  title: "Machines section",
  area: "Pages",
  height: 520,
  widths: { narrow: 220, normal: 260, wide: 360 },
  covers: ["page:cmux.machines", "pages/machines/MachinesSection.tsx"],
  load: async () => MachinesGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    compact: {
      note: "Shipped default. Grouped, one line per machine: the state shows only when the link is down (a spinner while connecting, Paused or Offline in words).",
      props: {},
    },
    grouped: {
      note: "The same groups, each machine's state on a second line.",
      props: { snapshot: { ...sampleSnapshot, style: "grouped" } },
    },
    flat: {
      note: "One list, state under the name, ready machines first (the layout before the groups).",
      props: { snapshot: { ...sampleSnapshot, style: "flat" } },
    },
    "joined-busy-failed": {
      note: "Joined machines: a Revoke running on gpu-west (spinner in the … place), a failed Rotate on lane-vm-3, studio-mini's menu open.",
      props: {
        snapshot: {
          rows: [thisMac, ...joinedRows],
          style: "compact",
          busy: ["m_gpu"],
          failed: { m_lane: "rotate" },
          openMenu: "m_mini",
        },
      },
    },
    "remove-question": {
      note: "Remove on lane-vm-3 asks first, inside the section: Cancel (Escape) or Remove (Return, danger ink). Remove takes the row out at once; the host revokes it if it still can join and takes it off every machine list.",
      props: {
        snapshot: { rows: [thisMac, ...joinedRows], style: "compact", busy: [], failed: {} },
        asking: "ssh-lane",
      },
    },
    "remove-failed": {
      note: "A Remove the host refused: the row is back and its caption says so.",
      props: { snapshot: { rows: [thisMac, ...joinedRows], style: "compact", busy: [], failed: { m_lane: "remove" } } },
    },
    "long-name": {
      note: "A name too long for its column wraps whole and its row grows; the rows below move down.",
      props: {
        snapshot: {
          ...sampleSnapshot,
          rows: [
            ...sampleRows,
            {
              id: "long",
              name: "an-uncommonly-long-machine-name-from-a-person",
              kind: "cloud",
              isLocal: false,
              isConnected: false,
              isConnecting: false,
              serverState: "paused",
            },
          ],
        },
      },
    },
    "this-mac-only": {
      note: "No remote machine yet: This Mac, then Add Machine….",
      props: { snapshot: { rows: [thisMac], style: "compact", busy: [], failed: {} } },
    },
    many: {
      note: "300 machines: rows past the viewport skip layout and paint; the section scrolls.",
      props: { snapshot: { rows: [thisMac, ...many], style: "compact", busy: [], failed: {} } },
    },
  },
});

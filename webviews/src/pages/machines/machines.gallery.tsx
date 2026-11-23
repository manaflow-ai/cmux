// l10n-allow-file: gallery fixtures (sample machine names), not shipped UI.
// The right sidebar's Machines section (cmux-page://cmux.machines/): the same MachinesSection
// main.tsx mounts, over the mock `cmux.machines.*` host. The first three variants are the three
// layouts of `machines.section.style`; the shipped default is `compact` (design/machines-section.md
// says why).
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MachinesSection, type DialLayout } from "./MachinesSection";
import { MockMachinesProvider, joinedRows, sampleRows, sampleSnapshot, thisMac } from "./mockProvider";
import { MachinesStore } from "./store";
import type { MachineRow, MachinesSnapshot, JoinedDialAnswer } from "./types";

/** `dial`: New Workspace clicked on that joined Mac's row, the host answering `answers` in turn (the
 * last one repeats); `layout`: where the row says how it stands. */
type Props = {
  snapshot?: MachinesSnapshot;
  asking?: string;
  dial?: { row: string; answers: JoinedDialAnswer[]; recheck?: number[] };
  layout?: DialLayout;
};

function MachinesGallery({ snapshot = sampleSnapshot, asking, dial, layout }: Props) {
  const [store] = useState(() => {
    const provider = new MockMachinesProvider(snapshot);
    if (dial) provider.dialAnswers = [...dial.answers];
    return new MachinesStore(provider, { recheck: dial?.recheck ?? [600_000] });
  });
  const [strings] = useState(() => createStrings(table));
  useEffect(() => {
    void store.start().then(() => {
      if (asking) store.askRemove(asking);
      if (dial) store.openJoined(dial.row);
    });
    return () => store.stop();
  }, [store, asking, dial]);
  return <MachinesSection store={store} strings={strings} dialLayout={layout} />;
}

const joinedOnly: MachinesSnapshot = { rows: [thisMac, ...joinedRows], style: "compact", busy: [], failed: {} };
const waiting = { row: "joined:m_mini", answers: [{ state: "consent_required" }] } satisfies Props["dial"];
const declined = { row: "joined:m_mini", answers: [{ state: "consent_declined" }] } satisfies Props["dial"];

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
    "device-glyphs": {
      note: "Each machine draws the device it reported (cmux-device-kind's SF Symbol, in the same 16 px icon box): a Mac mini, a Linux server, a Linux desktop, an offline Mac Studio. Cloud machines keep the cloud.",
      props: {
        snapshot: {
          ...sampleSnapshot,
          rows: sampleRows.map((row) => {
            const symbol = {
              local: "macmini",
              "fixture-ssh-1": "server.rack",
              "fixture-ssh-2": "macstudio",
              "fixture-server-1": "pc",
            }[row.id];
            return symbol ? { ...row, symbol } : row;
          }),
        },
      },
    },
    "dial-caption-waiting": {
      note: "Picked. New Workspace on studio-mini, a Mac signed in to this account: it shows its consent card, and this row says so in its caption's place, with a spinner in New Workspace's slot. No dialog; nothing else on the row or below it moves.",
      props: { snapshot: joinedOnly, dial: waiting, layout: "caption" },
    },
    "dial-caption-declined": {
      note: "Picked. studio-mini said Not now: the caption says so and Retry follows it. Nothing asks again until Retry.",
      props: { snapshot: joinedOnly, dial: declined, layout: "caption" },
    },
    "dial-caption-unanswered": {
      note: "Picked. No answer within about three minutes: the row stops asking and offers Retry.",
      props: {
        snapshot: joinedOnly,
        dial: { row: "joined:m_mini", answers: [{ state: "consent_required" }], recheck: [] },
        layout: "caption",
      },
    },
    "dial-caption-update": {
      note: "Picked. studio-mini's cmux predates the consent (it answers service.unknown): Update cmux on it, with Retry.",
      props: {
        snapshot: joinedOnly,
        dial: { row: "joined:m_mini", answers: [{ state: "unavailable", reason: "service.unknown" }] },
        layout: "caption",
      },
    },
    "dial-trailing-waiting": {
      note: "Variant: the words at the trailing edge, the caption kept. In a 220 px sidebar they cut the name short.",
      props: { snapshot: joinedOnly, dial: waiting, layout: "trailing" },
    },
    "dial-trailing-declined": {
      note: "Variant: trailing words; Retry is the New Workspace button, shown without hover.",
      props: { snapshot: joinedOnly, dial: declined, layout: "trailing" },
    },
    "dial-tinted-waiting": {
      note: "Variant: in the caption's place, waiting in the attention ink.",
      props: { snapshot: joinedOnly, dial: waiting, layout: "tinted" },
    },
    "dial-tinted-declined": {
      note: "Variant: Not now in the danger ink, Retry as the New Workspace button. Reads as an error, which Not now is not.",
      props: { snapshot: joinedOnly, dial: declined, layout: "tinted" },
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

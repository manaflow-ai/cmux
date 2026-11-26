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
import type { JoinedDialAnswer, MachineRow, MachinesSnapshot } from "./types";

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
const linuxBox: MachineRow = {
  id: "joined:m_box",
  name: "lane-box",
  kind: "joined",
  isLocal: false,
  isConnected: false,
  isConnecting: false,
  joined: { id: "m_box", name: "lane-box", state: "online", platform: "linux", mintedBy: "you@example.com" },
};
const linuxJoined: MachinesSnapshot = { ...joinedOnly, rows: [...joinedOnly.rows, linuxBox] };
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
    "dial-caption-waiting": {
      note: "Picked. New Workspace on studio-mini, a Mac signed in to this account: it shows its consent card, and this row says so in its caption's place, with a spinner in New Workspace's slot. No dialog; nothing else on the row or below it moves.",
      props: { snapshot: joinedOnly, dial: waiting, layout: "caption" },
    },
    "dial-caption-declined": {
      // retry-prompt-ok: the kept Retry (a new consent card on the other Mac).
      note: "Picked. studio-mini said Not now: the caption says so and Retry follows it. Nothing asks again until Retry.",
      props: { snapshot: joinedOnly, dial: declined, layout: "caption" },
    },
    "dial-caption-unanswered": {
      // retry-prompt-ok: the kept Retry (a new consent card on the other Mac).
      note: "Picked. No answer within about three minutes: the row stops asking and offers Retry.",
      props: {
        snapshot: joinedOnly,
        dial: { row: "joined:m_mini", answers: [{ state: "consent_required" }], recheck: [] },
        layout: "caption",
      },
    },
    "dial-caption-update": {
      // retry-prompt-ok: the person updates cmux on the other Mac first, then Retry.
      note: "Picked. studio-mini's cmux predates the consent (it answers service.unknown): Update cmux on it, with Retry.",
      props: {
        snapshot: joinedOnly,
        dial: { row: "joined:m_mini", answers: [{ state: "unavailable", reason: "service.unknown" }] },
        layout: "caption",
      },
    },
    "linux-joined-online": {
      note: "Picked. lane-box, a Linux machine joined by a line or pair code, online and reached only through the hub: New Workspace is on, as on a joined Mac. Its join is its consent, so it opens with no card.",
      props: { snapshot: linuxJoined },
    },
    "linux-dial-update": {
      note: "lane-box's acpmux predates its join counting as consent (it still asks, and has no card): Update cmux on lane-box, with Retry.",
      props: {
        snapshot: linuxJoined,
        dial: { row: "joined:m_box", answers: [{ state: "unavailable", reason: "service.outdated" }] },
        layout: "caption",
      },
    },
    "linux-dial-failed": {
      note: "lane-box cannot be reached over the hub (carrier off): Could not reach lane-box, with Retry.",
      props: {
        snapshot: linuxJoined,
        dial: { row: "joined:m_box", answers: [{ state: "unavailable", reason: "carrier.off" }] },
        layout: "caption",
      },
    },
    "dial-trailing-waiting": {
      note: "Variant: the words at the trailing edge, the caption kept. In a 220 px sidebar they cut the name short.",
      props: { snapshot: joinedOnly, dial: waiting, layout: "trailing" },
    },
    "dial-trailing-declined": {
      // retry-prompt-ok: the kept Retry, laid out on the New Workspace button.
      note: "Variant: trailing words; Retry is the New Workspace button, shown without hover.",
      props: { snapshot: joinedOnly, dial: declined, layout: "trailing" },
    },
    "dial-tinted-waiting": {
      note: "Variant: in the caption's place, waiting in the attention ink.",
      props: { snapshot: joinedOnly, dial: waiting, layout: "tinted" },
    },
    "dial-tinted-declined": {
      // retry-prompt-ok: the kept Retry, laid out on the New Workspace button.
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

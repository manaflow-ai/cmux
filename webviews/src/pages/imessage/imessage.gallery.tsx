// l10n-allow-file: gallery fixtures, not shipped UI.
// The Messages mirror page (cmux-page://cmux.imessage/): the same ImessagePage main.tsx mounts,
// over the mock `cmux.imessage.*` provider instead of the host bridge. Synthetic threads only.
import { useEffect, useState } from "react";
import { GALLERY_NOW } from "../../gallery/clock";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { ImessagePage, type BubbleTone } from "./ImessagePage";
import { MockImessageProvider, type MockImessageKind } from "./mockProvider";
import { ImessageStore } from "./store";

type Props = { kind?: MockImessageKind; tone?: BubbleTone; select?: number; long?: boolean };

// UTC at the gallery's fixed now, so every capture reads the same times wherever it runs.
const clock = { now: () => GALLERY_NOW, offsetMinutes: 0 };

function ImessageGallery({ kind = "ready", tone = "messages", select, long }: Props) {
  const [store] = useState(() => new ImessageStore(new MockImessageProvider(kind, GALLERY_NOW, { long })));
  const [strings] = useState(() => createStrings(table));
  useEffect(() => {
    void store.start().then(() => (select === undefined ? undefined : store.select(select)));
    return () => store.stop();
  }, [store, select]);
  return <ImessagePage store={store} strings={strings} clock={clock} tone={tone} />;
}

export default componentEntry<Props>({
  id: "pages.imessage",
  title: "Messages Mirror",
  area: "Pages",
  experimental: true,
  height: 640,
  widths: { narrow: 420, normal: 760, wide: 1040 },
  covers: ["page:cmux.imessage", "pages/imessage/ImessagePage.tsx"],
  load: async () => ImessageGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("../../theme/messages.css");
    await import("./styles.css");
  },
  variants: {
    group: { note: "A group chat open: sender handles over each run, a day line per day, an image chip.", props: {} },
    direct: { note: "A 1:1 conversation with an attachment chip and runs of bubbles.", props: { select: 7 } },
    "tone-accent": {
      note: "Comparison: my bubbles in the theme accent instead of Messages blue (not shipped).",
      props: { tone: "accent" },
    },
    "tone-neutral": {
      note: "Comparison: my bubbles in the foreground tint, no color (not shipped).",
      props: { tone: "neutral" },
    },
    long: { note: "A long thread: scrolling up reads the page before the oldest bubble.", props: { long: true, select: 30 } },
    off: { note: "The setting is off (the default): what the mirror is and where to turn it on.", props: { kind: "off" } },
    "not-permitted": {
      note: "No Full Disk Access: the button opens that pane of System Settings.",
      props: { kind: "not_permitted" },
    },
    missing: { note: "No Messages database on this Mac.", props: { kind: "missing" } },
    empty: { note: "On, with access, and no conversations.", props: { kind: "empty" } },
    error: { note: "The database could not be read.", props: { kind: "error" } },
    "unknown-ops": {
      note: "A daemon that does not know the imessage ops yet: the error state, never a blank page.",
      props: { kind: "unknown" },
    },
  },
});

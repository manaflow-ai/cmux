// l10n-allow-file: gallery fixtures (sample file paths), not shipped UI.
// The kept-changes notice of an Auto chat (AutoSessionBanner.tsx), in the states a click reaches:
// the files listed, and Discard's second step. The whole pane with the notice at rest is
// agent-pane.auto-session's `leftover` variant.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { AutoSession } from "./autoSession";

type Props = { auto: AutoSession; files: string[] };

const FILES = [
  "src/net/upload.ts",
  "src/net/upload.test.ts",
  "src/net/download.ts",
  "src/net/download.test.ts",
  "src/net/progress.ts",
  "src/net/retry.ts",
  "src/net/retry.test.ts",
  "docs/uploads.md",
  "docs/downloads.md",
  "package.json",
  "bun.lock",
];

const kept = (files: number): Props => ({
  auto: { auto: true, state: "local", here: true, keepInCloud: false, leftover: { files } },
  files: FILES.slice(0, files),
});

const press =
  (name: string, settled: string): Play =>
  async (ctx) => {
    await ctx.click({ role: "button", name });
    await ctx.waitFor(() => ctx.document.querySelector(settled));
  };

export default componentEntry<Props>({
  id: "agent-pane.auto-leftover",
  title: "Auto: changes kept aside",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 320, normal: 720, wide: 900 },
  covers: ["agent-session/acpmux/autoSession/AutoSessionBanner.tsx"],
  load: async () => {
    const { AutoSessionBanner } = await import("./AutoSessionBanner");
    return function GalleryAutoLeftover({ auto, files }: Props) {
      return (
        <div className="acpmux-shell">
          <AutoSessionBanner
            auto={auto}
            sending={false}
            noteDelayMs={0}
            onSetUpCloud={() => undefined}
            onLeftover={(action) => Promise.resolve(action === "show" ? { files } : undefined)}
            onFailed={() => undefined}
          />
        </div>
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("../../../ui/popupSurface.css")]),
  variants: {
    rest: { note: "At rest: what happened, then Show, Apply and Discard.", props: kept(3) },
    shown: {
      note: "Show lists the files the kept changes touch; the button reads Hide.",
      props: kept(3),
      play: press("Show", "[data-auto-files]"),
    },
    "shown-many": {
      note: "More than eight files: the first eight, then how many more.",
      props: kept(FILES.length),
      play: press("Show", "[data-auto-files]"),
    },
    "discard-ask": {
      note: "Discard asks once more in place, with Keep to back out.",
      props: kept(3),
      play: press("Discard", '[data-auto="leftover"] [role="group"]'),
    },
  },
});

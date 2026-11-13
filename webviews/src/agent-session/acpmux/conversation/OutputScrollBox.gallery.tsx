// l10n-allow-file: gallery fixtures (sample commands and output, and the old row's words drawn for
// the before look), not shipped UI.
// Output and code cards in the agent chat draw whole up to OUTPUT_BOX_LINES lines and scroll inside
// a box that tall past them, never behind a Show all button. Leo,
// 2026-11-12, on a Shell card that showed seven lines and "Show all 9 lines": "this is a really
// useless show all 9 lines. i think [another chat app] just lets you scroll, straight up?"
// Each size (9 lines, his case; 24, the box's own height; 120, a long run) has a before look (the
// old seven-line cut with its row, drawn here only) and the shipped one, on a Shell block, a call's
// output and a file read.
import type { ReactNode } from "react";
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { OUTPUT_BOX_LINES } from "./blockPartsModel";
import { FileResultCard } from "./FileResultCard";
import { ShellBlock } from "./ShellBlock";
import { ToolOutput } from "./ToolOutputBody";

type Size = "short" | "cap" | "long";
type Look = "before" | "after";
type Props = { size: Size; look: Look };

const LINES: Record<Size, number> = { short: 9, cap: OUTPUT_BOX_LINES, long: 120 };

/// Nine lines like the ones in Leo's screenshot: a commit's stat and its push.
const NINE = [
  " src/net/retryPolicy.ts       | 12 ++++++++----",
  " src/net/retryPolicyStore.ts  |  2 +-",
  " src/net/backoff.ts           | 26 +++++++++++++++++---------",
  " src/net/standby.ts           |  5 +++--",
  " 4 files changed, 30 insertions(+), 15 deletions(-)",
  "   6679efbb..3a4a999b  HEAD -> lane--retry-backoff",
  "3a4a999b8b5b15b0a9121994c0c7d5847a6deeb2",
  "Everything up-to-date",
  "done",
].join("\n");

const output = (size: Size) =>
  size === "short"
    ? NINE
    : Array.from(
        { length: LINES[size] },
        (_, index) => `(pass) retry backoff case ${index + 1} [0.${index % 10}ms]`,
      ).join("\n");

const code = (size: Size) =>
  Array.from(
    { length: LINES[size] },
    (_, index) => `export const step${index} = (attempt: number) => Math.min(30_000, 250 * 2 ** attempt);`,
  ).join("\n");

/// The old cut, for the before look only: seven lines, then a row with the words the old button said.
function Before({ lines, children }: { lines: number; children: ReactNode }) {
  return (
    <div className="output-scroll-box-gallery__before">
      {children}
      {lines > 7 && (
        <div className="cv-expand-row output-scroll-box-gallery__old-row" aria-hidden="true">
          <span className="cv-expand-row__label">{`Show all ${lines} lines`}</span>
        </div>
      )}
    </div>
  );
}

function OutputScrollBoxGallery({ size, look }: Props) {
  const lines = LINES[size];
  const wrap = (node: ReactNode) => (look === "before" ? <Before lines={lines}>{node}</Before> : node);
  return (
    <div className="acpmux-shell output-scroll-box-gallery" data-look={look} data-size={size}>
      <div data-gallery-block="shell">
        {wrap(
          <ShellBlock command="git commit -qam 'Retry with backoff' && git push" output={output(size)} exitCode={0} />,
        )}
      </div>
      <div data-gallery-block="output">{wrap(<ToolOutput result={{ text: output(size), lang: "text" }} />)}</div>
      <div data-gallery-block="read">
        {wrap(
          <FileResultCard
            id={`output-scroll-box-read-${size}-${look}`}
            card={{ kind: "read", read: { path: "src/net/retry.ts", start: 1, end: lines, code: code(size) } }}
          />,
        )}
      </div>
    </div>
  );
}

const ready: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelectorAll("[data-gallery-block] .cv-scroll-box").length === 3);
};

/// The long Shell box scrolled halfway: its edge still fades, and the transcript under it has not moved.
const scrolledHalfway: Play = async (ctx) => {
  await ready(ctx);
  const box = ctx.document.querySelector<HTMLElement>('[data-gallery-block="shell"] .cv-scroll-box')!;
  box.scrollTop = (box.scrollHeight - box.clientHeight) / 2;
  box.dispatchEvent(new Event("scroll"));
  await ctx.waitFor(() => box.hasAttribute("data-scrolls") && box.hasAttribute("data-more-below"));
};

const NOTES: Record<Size, Record<Look, string>> = {
  short: {
    before: "Before: nine lines, seven shown and a Show all 9 lines row that reveals two more (Leo's screenshot).",
    after: "Shipped: all nine lines, whole. No row, no scroll.",
  },
  cap: {
    before: `Before: ${OUTPUT_BOX_LINES} lines, seven shown and a Show all row.`,
    after: `Shipped: exactly ${OUTPUT_BOX_LINES} lines, the box's own height: whole, no scroll, no fade.`,
  },
  long: {
    before: "Before: 120 lines, seven shown and a Show all row.",
    after: `Shipped: 120 lines in a ${OUTPUT_BOX_LINES}-line box that scrolls inside, its bottom fading while more lies under it; at its edge the wheel goes on to the transcript.`,
  },
};

const variants: Record<string, ComponentVariant<Props>> = {};
for (const size of ["short", "cap", "long"] as Size[])
  for (const look of ["before", "after"] as Look[])
    variants[`${size}-${look}`] = { note: NOTES[size][look], props: { size, look }, play: ready };
variants["long-after-scrolled"] = {
  note: "Shipped, the long Shell box scrolled halfway: it scrolls inside, the card and the transcript stay put.",
  props: { size: "long", look: "after" },
  play: scrolledHalfway,
};

export default componentEntry<Props>({
  id: "agent-pane.output-scroll-box",
  title: "Output cards scroll, never Show all",
  area: "Agent pane",
  pane: true,
  height: 1600,
  widths: { narrow: 420, normal: 640, wide: 900 },
  anchors: [{ selector: ".output-scroll-box-gallery" }],
  covers: [
    "agent-session/acpmux/conversation/outputScrollBox.css",
    "agent-session/acpmux/conversation/ShellBlock.tsx#ShellBlock",
    "agent-session/acpmux/conversation/ToolOutputBody.tsx#ToolOutput",
    "agent-session/acpmux/conversation/FileResultCard.tsx#FileResultCard",
  ],
  load: async () => OutputScrollBoxGallery,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("./FileResultCard.css"),
      import("./outputScrollBox.css"),
      import("./OutputScrollBox.gallery.css"),
    ]),
  keywords: ["scroll", "output", "shell", "show all", "lines", "overflow"],
  variants,
});

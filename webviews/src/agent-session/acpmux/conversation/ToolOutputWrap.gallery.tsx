// l10n-allow-file: gallery fixtures (sample commands and output), not shipped copy.
// A tool call's output wraps down instead of running off the right edge. Leo, 2026-11-11, on an
// opened Shell card whose output line ran past the card: "shouldn't this be... not horizontally
// scrolled? as in, it goes down instead of to the right?" Each look shows his line (a background
// command's notice with a long path), a 300-character unbroken token, a `ps` table and a non-shell
// call's output with a long path, in one pane-wide column, and one 10,000-character line, cut to
// eight rows with Show all like any long output:
// - by-shape (shipped, blockWrap.ts `outputWraps`): every output wraps, its long lines hanging under
//   their start, but a table keeps its rows whole and aligned (Leo, 2026-11-04, on a folded `ps`
//   table: "why isn't this just prettified by default?").
// - always: every output wraps, the table too.
// - flush: by shape, a wrapped line's next rows start at its own start, with no hanging indent.
// The Wrap lines button still flips every output block, in every look.
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { ShellBlock } from "./ShellBlock";
import { ToolOutput } from "./ToolOutputBody";

type Look = "by-shape" | "always" | "flush";
type Props = { look: Look };

export const LEO_COMMAND =
  "cd ~/Projects/cmux && bun run --cwd webviews test test/transcript-block-overflow.test.tsx --reporter=spec";
export const LEO_LINE =
  "Command running in background with ID: baimgy381. Output is being written to: /private/tmp/claude-501/-Users-leoli-Projects/01a18a35-b23b-7b61-9798-dba14474a974/tasks/baimgy381.output";
/// 300 characters with no break opportunity: a hash, a token or a path with no separators.
export const UNBROKEN = "a1b2c3d4e5".repeat(30);
/// One printed line of 10,000 characters: wrapped, it is cut to eight rows with Show all.
export const HUGE = "f0e1d2c3b4 ".repeat(909) + "end";
const PS = [
  "  PID TTY           TIME CMD",
  " 4821 ttys001    0:00.12 -zsh",
  " 5120 ttys002    0:03.40 node /usr/local/bin/vite --port 5173 --host 127.0.0.1 --strictPort --config webviews/vite.config.gallery-dev.ts",
  " 5188 ttys002    0:00.02 bun test test/transcript-block-overflow.test.tsx --reporter=spec --timeout 120000",
].join("\n");
const FETCHED = `Saved the report to /Users/sample/Projects/atlas/reports/2026-11-11/network-map/retry-policy-and-backoff-summary-${"x".repeat(60)}.md\nIt lists 14 services and 3 retry policies.`;

function ToolOutputWrapGallery({ look }: Props) {
  return (
    <div className="acpmux-shell tool-output-wrap-gallery" data-wrap-look={look}>
      <div data-gallery-block="leo">
        <ShellBlock command={LEO_COMMAND} output={LEO_LINE} exitCode={0} />
      </div>
      <div data-gallery-block="unbroken">
        <ShellBlock command="git rev-list --all | tr -d '\n'" output={UNBROKEN} exitCode={0} />
      </div>
      <div data-gallery-block="table">
        <ShellBlock command="ps" output={PS} exitCode={0} />
      </div>
      <div data-gallery-block="huge">
        <ShellBlock command="cat build/minified.js" output={HUGE} exitCode={0} />
      </div>
      <div data-gallery-block="output">
        <ToolOutput result={{ text: FETCHED, lang: "text" }} />
      </div>
    </div>
  );
}

const ready: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelectorAll("[data-gallery-block] [data-wrap]").length === 5);
};

const LOOKS: Record<Look, string> = {
  "by-shape":
    "Shipped: every output wraps down, a long line hanging under its start, but the ps table keeps its rows whole and aligned.",
  always: "Every output wraps down, the ps table too.",
  flush: "By shape, with no hanging indent: a wrapped line's next rows start where it starts.",
};

const variants: Record<string, ComponentVariant<Props>> = {};
for (const look of Object.keys(LOOKS) as Look[]) variants[look] = { note: LOOKS[look], props: { look }, play: ready };

export default componentEntry<Props>({
  id: "agent-pane.tool-output-wrap",
  title: "Tool output wraps down",
  area: "Agent pane",
  pane: true,
  height: 720,
  widths: { narrow: 420, normal: 640, wide: 900 },
  anchors: [{ selector: ".tool-output-wrap-gallery" }],
  covers: [
    "agent-session/acpmux/conversation/blockWrap.ts#outputWraps",
    "agent-session/acpmux/conversation/ShellBlock.tsx#ShellBlock",
    "agent-session/acpmux/conversation/ToolOutputBody.tsx#ToolOutput",
  ],
  load: async () => ToolOutputWrapGallery,
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./ToolOutputWrap.gallery.css")]),
  keywords: ["wrap", "output", "shell", "horizontal", "scroll", "table", "overflow"],
  variants,
});

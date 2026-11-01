// l10n-allow-file: public-safe gallery fixtures, not shipped copy.
import { useEffect } from "react";
import { componentEntry } from "../../../gallery/format";
import { tool } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import { ToolGroupRow } from "./ToolGroupRow";
import { resetTranscriptDisclosure, TranscriptDisclosureProvider } from "./transcriptDisclosure";

const SESSION = "gallery-tool-group-expanded";
const commands = (prefix: string, count: number) =>
  Array.from({ length: count }, (_, at) =>
    tool(`Inspect sample ${at + 1}`, "execute", "completed", {
      id: `${prefix}-${at + 1}`,
      command: `echo sample-${at + 1}`,
      output: `Sample ${at + 1} passed.\n`,
    }),
  );
const outer = commands("expanded-command", 13);
const nested = commands("nested-command", 14);

function ToolGroupExpandedGallery() {
  useEffect(() => resetTranscriptDisclosure(SESSION), []);
  return (
    <TranscriptDisclosureProvider sessionId={SESSION}>
      <main className="tool-group-expanded-gallery" data-tool-group-expanded>
        <section data-fixture="expanded">
          <p>Sample project checks</p>
          <div className="cv-tools">
            <ToolGroupRow kind="commands" items={outer} disclosureKey="expanded-commands" folded />
          </div>
        </section>
        <section data-fixture="nested">
          <p>Nested tool group</p>
          <div className="cv-tool-group">
            <ToolGroupRow kind="commands" items={nested} disclosureKey="nested-commands" folded />
          </div>
        </section>
      </main>
    </TranscriptDisclosureProvider>
  );
}

const expanded: Play = async (ctx) => {
  await ctx.click({ selector: '[data-fixture="expanded"] .cv-tools > button' });
  await ctx.waitFor(() =>
    ctx.document.querySelector('[data-fixture="expanded"] .cv-tools > button[aria-expanded="true"]'),
  );
};
const both: Play = async (ctx) => {
  await expanded(ctx);
  await ctx.click({ selector: '[data-fixture="nested"] .cv-tool-group > button' });
  await ctx.waitFor(() =>
    ctx.document.querySelector('[data-fixture="nested"] .cv-tool-group > button[aria-expanded="true"]'),
  );
};

export default componentEntry<Record<string, never>>({
  id: "agent-pane.tool-group-expanded",
  title: "Expanded tool groups",
  area: "Agent pane",
  pane: true,
  experimental: true,
  height: 760,
  widths: { narrow: 700, normal: 980, wide: 1200 },
  covers: ["agent-session/acpmux/conversation/ToolGroupRow.tsx"],
  styles: () => import("./ToolGroupExpanded.gallery.css"),
  load: async () => ToolGroupExpandedGallery,
  variants: {
    expanded: { props: {}, note: "One click opens all 13 commands.", play: expanded },
    nested: { props: {}, note: "Both groups open, including all 14 nested commands.", play: both },
    hover: {
      props: {},
      note: "All items stay visible while one command shows its hover controls.",
      play: async (ctx) => {
        await both(ctx);
        await ctx.hover({ selector: '[data-fixture="expanded"] .cv-command' });
      },
    },
  },
});

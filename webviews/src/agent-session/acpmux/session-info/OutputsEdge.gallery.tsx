// l10n-allow-file: synthetic gallery files and click receipts, never a real conversation.
import { componentEntry } from "../../../gallery/format";
import type { TurnFile } from "../diff";

type Props = { treatment: "subtle" | "balanced" | "roomy"; count?: number };
const files: TurnFile[] = Array.from({ length: 18 }, (_, index) => ({
  path: `/demo/src/output-${index + 1}.ts`,
  displayPath: `src/output-${index + 1}.ts`,
  additions: index + 1,
  deletions: 0,
  created: true,
  edits: [],
}));

export default componentEntry<Props>({
  id: "agent-pane.outputs-edge",
  title: "Outputs scroll edges",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/session-info/OutputsSection.tsx#OutputsSection"],
  load: async () => {
    const [{ useState }, { OutputsSection }, { SessionInfoSection }] = await Promise.all([
      import("react"),
      import("./OutputsSection"),
      import("./SessionInfoSection"),
    ]);
    return function OutputsEdge({ treatment, count = 18 }: Props) {
      const [open, setOpen] = useState(true);
      const [opened, setOpened] = useState("");
      return (
        <div data-outputs-edge-variant={treatment} style={{ padding: 16 }}>
          <SessionInfoSection id="outputs" title="Outputs" open={open} onOpenChange={setOpen}>
            <OutputsSection files={files.slice(0, count)} links={[]} artifacts={0} onOpenFile={setOpened} />
          </SessionInfoSection>
          <output data-opened-file="">{opened}</output>
        </div>
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./sessionInfo.css")]),
  widths: { narrow: 320, normal: 420, wide: 560 },
  height: 440,
  variants: {
    subtle: { props: { treatment: "subtle" }, note: "Chosen: a quiet 12px band, 5px blur. Open Show more and scroll." },
    balanced: { props: { treatment: "balanced" }, note: "Comparison: 16px band and 8px blur." },
    roomy: { props: { treatment: "roomy" }, note: "Comparison: 24px band and 12px blur." },
    short: { props: { treatment: "subtle", count: 3 }, note: "No overflow, so no faded edges." },
  },
});

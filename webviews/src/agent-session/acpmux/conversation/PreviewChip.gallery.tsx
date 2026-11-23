// l10n-allow-file: gallery fixtures (sample commands and addresses), not shipped UI.
// A background dev server's page on its own row (PreviewChip.tsx): the real CommandRow and ToolRow
// over a stand-in for acpmux's `preview`, in three looks. `accent` ships: the globe and address in
// the accent, as the running line's parts read. `pill` puts them in a tinted capsule; `quiet` keeps
// them grey until hover. Every look sits at the edge a running row leaves empty, so the row's height
// and words never move when the chip arrives.
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxActivity, AcpmuxBackgroundState } from "../model";
import { CommandRow } from "./CommandRow";
import { PreviewChipsContext, type PreviewChips } from "./previewChipModel";
import { ToolRow } from "./ToolRow";
import { TranscriptDisclosureProvider } from "./transcriptDisclosure";

type Look = "accent" | "pill" | "quiet";
type Props = { look: Look; url: string; state: AcpmuxBackgroundState["state"] };

const STARTED = Date.UTC(2026, 10, 8, 10, 0, 0);

const call = (id: string, command: string, background: AcpmuxBackgroundState): AcpmuxActivity => ({
  kind: "tool",
  text: command,
  tool: {
    id,
    title: command,
    kind: "execute",
    status: "completed",
    command,
    startedAt: STARTED,
    endedAt: STARTED + 200,
    background,
  },
});

function Stage({ look, url, state }: Props) {
  const preview = { url, port: Number(new URL(url).port) };
  const chips: PreviewChips = {
    byTool: new Map([
      ["dev", preview],
      ["api", { url: "http://127.0.0.1:8000/", port: 8000 }],
    ]),
    latest: preview,
    open: () => undefined,
  };
  const background: AcpmuxBackgroundState = state === "running" ? { state } : { state, endedAt: STARTED + 64_000 };
  return (
    <TranscriptDisclosureProvider sessionId="gallery-preview-chip">
      <PreviewChipsContext.Provider value={chips}>
        <div className="acpmux-shell cv-preview-chip-looks" data-look={look} style={{ padding: 16 }}>
          <div className="cv-tools">
            <CommandRow item={call("dev", "npm run dev", background)} />
          </div>
          <div className="cv-tools">
            <ToolRow item={call("api", "uvicorn app.main:app --reload", background)} />
          </div>
        </div>
      </PreviewChipsContext.Provider>
    </TranscriptDisclosureProvider>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.preview-chip",
  title: "Dev server preview chip",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/conversation/PreviewChip.tsx#PreviewChip"],
  load: async () => Stage,
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./PreviewChip.gallery.css")]),
  height: 160,
  widths: { narrow: 360, normal: 640 },
  anchors: [{ selector: ".cv-preview-chip" }],
  variants: {
    accent: {
      note: "Shipped look: the globe and address in the accent at the running row's edge, underlined on hover. A click opens the page beside the chat; the row stays closed.",
      props: { look: "accent", url: "http://localhost:5173/", state: "running" },
    },
    pill: {
      note: "Alternative: the same chip in a tinted capsule. Louder than the row's other marks, which are bare text and glyphs.",
      props: { look: "pill", url: "http://localhost:5173/", state: "running" },
    },
    quiet: {
      note: "Alternative: grey until hover, as the row's time and check are. Easy to miss, which is the opposite of the point.",
      props: { look: "quiet", url: "http://localhost:5173/", state: "running" },
    },
    "long-path": {
      note: "A page with a path keeps it; past 24 characters the address ends in an ellipsis before the row's words give way.",
      props: { look: "accent", url: "http://localhost:3000/dashboard/projects/settings", state: "running" },
    },
    ended: {
      note: "The server stopped: no chip, only the row's check and time, as any finished background command.",
      props: { look: "accent", url: "http://localhost:5173/", state: "completed" },
    },
  },
});

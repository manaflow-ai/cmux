// l10n-allow-file: gallery fixtures (sample tool calls and a sample extension's card), not shipped UI.
// An extension's chat widget (cmux.chat.widget/1) under an agent's tool call, on the real ToolRow over
// the panels mock: the daemon's route answers GitHub pull request calls with the example pr-card
// extension (examples/extensions/pr-card), whose scene draws with the sections' renderer. cmux ships
// no widgets of its own; the other call has no widget and looks as it always did. Three frames for
// the card: a hairline frame on the row's text column, no frame at all, and the frame with the
// extension's name over it. References: claude/live/transcript-tool-rows-and-task-list (a tool row's
// result sits on the row's text column, quiet) and the Session Info app sections' rows.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { MockAppPanelsClient } from "../../../apps/scene/panelsMock";
import type { AcpmuxActivity } from "../model";
import { ToolRow } from "./ToolRow";
import { ChatWidgetClientContext } from "./ToolWidget";
import { TranscriptDisclosureProvider } from "./transcriptDisclosure";

type Look = "hairline" | "flat" | "titled";
type Props = { look: Look };

const call = (id: string, title: string, input: unknown): AcpmuxActivity => ({
  kind: "tool",
  text: title,
  tool: { id, title, kind: "other", status: "completed", inputSummary: JSON.stringify(input), output: "{}" },
});

function Stage({ look }: Props) {
  const [client] = useState(() => new MockAppPanelsClient());
  return (
    <TranscriptDisclosureProvider sessionId="gallery-tool-widget">
      <ChatWidgetClientContext.Provider value={client}>
        <div className="acpmux-shell cv-tool-widget-looks" data-look={look} style={{ padding: 16 }}>
          <div className="cv-tools">
            <ToolRow
              item={call("w1", "mcp__github__get_pull_request", { owner: "acme", repo: "atlas", pullNumber: 184 })}
            />
          </div>
          <div className="cv-tools">
            <ToolRow item={call("w2", "mcp__linear__get_issue", { id: "ENG-412" })} />
          </div>
        </div>
      </ChatWidgetClientContext.Provider>
    </TranscriptDisclosureProvider>
  );
}

const widgetReady: Play = async (ctx) => {
  await ctx.waitFor(
    () => (ctx.document.querySelector(".cv-tool-widget")?.querySelectorAll('[data-app-type="Row"]').length ?? 0) === 4,
  );
};

export default componentEntry<Props>({
  id: "agent-pane.tool-chat-widget",
  title: "Chat widget under a tool call",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/conversation/ToolWidget.tsx",
    "agent-session/acpmux/conversation/ToolRow.tsx",
    "apps/scene/chatWidgetClient.ts",
  ],
  load: async () => Stage,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../../../ui/controls.css"),
      import("./conversation.css"),
      import("./ToolWidget.gallery.css"),
    ]),
  height: 420,
  widths: { narrow: 360, normal: 640 },
  anchors: [{ selector: ".cv-tool-widget" }],
  variants: {
    hairline: {
      note: "Chosen: the extension's card on the row's text column in a hairline frame, at most 420px wide, so it reads as the extension's and not cmux's own text. The Linear call has no widget and is unchanged.",
      props: { look: "hairline" },
      play: widgetReady,
    },
    flat: {
      note: "Alternative: no frame, the scene straight on the text column like a tool's output. Quietest, but the card's rows run into the next tool row.",
      props: { look: "flat" },
      play: widgetReady,
    },
    titled: {
      note: "Alternative: the hairline frame with the extension's name over it. Says whose card it is, at the cost of one more line per call.",
      props: { look: "titled" },
      play: widgetReady,
    },
  },
});

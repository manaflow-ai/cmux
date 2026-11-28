// l10n-allow-file: gallery variant labels and notes.
import { noChat } from "../../gallery/fixtures/acpmux";
import { agentPaneEntry } from "../../gallery/format";
import type { ChatOpenRefusal } from "./chatUnavailable";
import { showArm } from "./reconvene/arm";

const refused = (openRefusal: ChatOpenRefusal) =>
  noChat([], { missingSession: "example-chat-001", openRefusal, connection: "failed" });

const ready = '.acpmux-stage [data-unavailable="refused"] h2';

export default agentPaneEntry({
  id: "agent-pane.refused-chat",
  title: "A chat that couldn't be opened",
  area: "Agent pane",
  height: 480,
  covers: ["agent-session/acpmux/ChatUnavailableState.tsx#ChatUnavailableState"],
  variants: {
    centered: {
      note: "The existing centered chat notice, with the reason and the tab action.",
      snapshot: refused("device.required"),
      play: (ctx) => showArm(ctx, { ready, css: "" }),
    },
    compact: {
      note: "A compact centered notice without the chat glyph.",
      snapshot: refused("device.revoked"),
      play: (ctx) => showArm(ctx, { ready, css: ".acpmux-unavailable .acpmux-empty-glyph { display: none }" }),
    },
    leading: {
      note: "The notice starts at the transcript’s leading edge.",
      snapshot: refused("no_session"),
      play: (ctx) =>
        showArm(ctx, {
          ready,
          css: `
        .acpmux-stage > .acpmux-unavailable { align-items: flex-start; text-align: start; padding-inline: var(--cv-inset, var(--ds-space-4)) }
        .acpmux-unavailable .acpmux-unavailable-copy { align-items: flex-start }
        .acpmux-unavailable .acpmux-unavailable-actions { justify-content: flex-start }
      `,
        }),
    },
  },
});

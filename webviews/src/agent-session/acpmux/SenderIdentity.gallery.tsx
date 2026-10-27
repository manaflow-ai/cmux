// l10n-allow-file: fixture names, messages and comparison labels; not shipped UI.
import { createElement } from "react";
import { componentEntry } from "../../gallery/format";

type Treatment = "inline" | "separate-line" | "plain-preview";

export default componentEntry<{ treatment: Treatment }>({
  id: "agent-pane.sender-identity",
  title: "Agent sender identity and rail designation",
  area: "Agent pane",
  pane: true,
  height: 450,
  widths: { narrow: 420, normal: 720, wide: 960 },
  covers: [
    "agent-session/acpmux/senderIdentity.ts",
    "agent-session/acpmux/SenderIdentityLabel.tsx",
    "agent-session/acpmux/threadMinimap/PreviewCard.tsx",
  ],
  styles: () => import("./threadMinimap/threadMinimap.css"),
  load: async () => {
    const { SenderIdentityLabel } = await import("./SenderIdentityLabel");
    const { resolveSenderIdentity } = await import("./senderIdentity");
    const { SubsessionContext, SubsessionStore } = await import("./subagents/subsessions");
    const { sessionEntry } = await import("./sessionList");
    const { PreviewCard } = await import("./threadMinimap/PreviewCard");
    const remote = sessionEntry({
      sessionId: "fixture-review",
      name: "review-box/design-check",
      peer: "review-box",
      harness: "codex",
    });
    const child = sessionEntry({
      sessionId: "fixture-child",
      shortName: "syntax-check",
      startedBy: "fixture-parent",
      harness: "claude",
    });
    const store = new SubsessionStore();
    store.set([remote, child]);
    const sender = { name: remote.name!, sessionId: remote.sessionId };
    return function SenderIdentityGallery({ treatment }: { treatment: Treatment }) {
      return createElement(
        SubsessionContext.Provider,
        { value: { store, open: () => {} } },
        createElement(
          "div",
          {
            className: "sender-identity-fixture",
            "data-treatment": treatment,
            style: { padding: 16, position: "relative", minHeight: 400 },
          },
          createElement(
            "style",
            null,
            `
            .sender-identity-fixture > p { margin: 0 0 12px; }
            .sender-identity-fixture .acpmux-minimap__card { left: 0; top: 0; }
            .sender-identity-fixture[data-treatment=separate-line] .acpmux-minimap__prompt .acpmux-sender { display: flex; }
          `,
          ),
          createElement(
            "p",
            null,
            createElement(SenderIdentityLabel, { identity: resolveSenderIdentity(sender, remote, "fixture-parent") }),
          ),
          createElement(
            "p",
            null,
            createElement(SenderIdentityLabel, {
              identity: resolveSenderIdentity(
                { name: "syntax-check", sessionId: child.sessionId },
                child,
                "fixture-parent",
              ),
            }),
          ),
          createElement(
            "p",
            null,
            createElement(SenderIdentityLabel, { identity: resolveSenderIdentity({ name: "unlisted-agent" }) }),
          ),
          createElement(PreviewCard, {
            id: "fixture-agent-card",
            x: 16,
            y: 126,
            railLeft: 0,
            prompt: "Ready for review.\n- Markdown and long paths remain readable.",
            reply: [{ kind: "paragraph", spans: [{ text: "Thanks. I will land the reviewed change.", bold: false }] }],
            metadata: { at: 1793116800000, links: [], ...(treatment !== "plain-preview" && { sender }) },
            onPointerLeave: () => {},
          }),
        ),
      );
    };
  },
  variants: {
    inline: {
      note: "Chosen: sender identity stays within the existing capped title budget; no extra rail ticks.",
      props: { treatment: "inline" },
    },
    "separate-line": {
      note: "Comparison: identity on its own line spends more of the fixed prompt budget.",
      props: { treatment: "separate-line" },
    },
    "plain-preview": {
      note: "Before: the preview reads as a prompt with no visible sender designation.",
      props: { treatment: "plain-preview" },
    },
  },
});

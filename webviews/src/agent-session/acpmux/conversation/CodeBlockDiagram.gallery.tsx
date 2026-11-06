// l10n-allow-file: gallery fixtures (a sample reply with a tree diagram), not shipped UI.
// An agent reply's unlabeled fence holding a tree drawn in box-drawing characters (Leo 2026-11-01:
// "could we render this type of thing better in cmux-next"). Three header looks for an unlabeled
// card (CodeHeader.tsx) and three line heights for a diagram (conversation.css
// `.cv-codeblock--diagram`). Shipped: `corner` (no header row, copy in the corner on hover) at 1.15.
// `normal` lets a fallback glyph (↓) make its line taller; 20px is the old card, gaps between every │.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { UnlabeledHeaderLookContext, type UnlabeledHeaderLook } from "./CodeHeader";
import { Markdown } from "./Markdown";

type Lines = "snug" | "normal" | "tall";
type Props = { look: UnlabeledHeaderLook; lines: Lines };

const TREE = [
  "Your Mac",
  "├─ cmux NEXT app ── Swift window/chrome + web views (the composer, this transcript, the sidebar's lists)",
  "│     talks to ↓ (local sockets)",
  "├─ cmux-tui  (one Rust binary, two daemons + the CLI)",
  "│   ├─ terminal daemon: workspaces, panes, PTYs, scrollback",
  "│   └─ acpmux: the agent daemon; keeps Claude Code and Codex sessions alive",
  "│        as named sessions, and links to other machines' acpmux over ssh",
  "│",
  "Cloud machine (a Freestyle VM, one per workspace)",
  "├─ boots from our image/snapshot: same cmux-tui and acpmux as your Mac",
  "└─ terminals, files, commands: your app goes straight to the VM's daemon",
].join("\n");

const REPLY = `Here's how it fits together today.\n\n\`\`\`\n${TREE}\n\`\`\`\n\nThe labeled card is unchanged:\n\n\`\`\`ts\nexport const retry = 3;\n\`\`\`\n`;

function Stage({ look, lines }: Props) {
  return (
    <UnlabeledHeaderLookContext.Provider value={look}>
      <div className="acpmux-shell" data-gallery-diagram-lines={lines} style={{ padding: 16, maxWidth: 640 }}>
        <Markdown>{REPLY}</Markdown>
      </div>
    </UnlabeledHeaderLookContext.Provider>
  );
}

const hovered: Play = async (ctx) => {
  await ctx.hover({ selector: ".cv-codeblock .cv-codeblock__body" });
};

export default componentEntry<Props>({
  id: "agent-pane.code-block-diagram",
  title: "Code block: box-drawing diagram",
  area: "Agent pane",
  pane: true,
  height: 520,
  covers: [
    "agent-session/acpmux/conversation/CodeBlock.tsx",
    "agent-session/acpmux/conversation/CodeHeader.tsx",
    "agent-session/acpmux/conversation/codeShape.ts",
    "agent-session/acpmux/conversation/StreamingCode.tsx",
    "agent-session/acpmux/conversation/HighlightedCode.tsx",
  ],
  load: async () => Stage,
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./CodeBlockDiagram.gallery.css")]),
  variants: {
    "corner-snug": {
      note: "Shipped: no header row; lines at 1.15 so every │ meets the next; the long line scrolls inside the card.",
      props: { look: "corner", lines: "snug" },
    },
    "corner-snug-hover": {
      note: "Shipped, hovered: the copy floats in the card's top-right corner over the card's own tint.",
      props: { look: "corner", lines: "snug" },
      play: hovered,
    },
    "muted-snug": {
      note: "Version B: a short muted row that names the block, actions on the right.",
      props: { look: "muted", lines: "snug" },
    },
    "row-snug": {
      note: 'Version C: the "</> Plain text" row every fence had, with the joined lines.',
      props: { look: "row", lines: "snug" },
    },
    "corner-normal": {
      note: "Line height normal: joined in one font, but a fallback glyph (↓) can make its line taller and open a gap.",
      props: { look: "corner", lines: "normal" },
    },
    "row-tall": {
      note: "Before: the labeled row and 20px lines; every │ has a band under it.",
      props: { look: "row", lines: "tall" },
    },
  },
});

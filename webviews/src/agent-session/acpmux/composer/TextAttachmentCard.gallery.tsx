// l10n-allow-file: public synthetic paste and file text in gallery fixtures.
// The text attachment card (TextAttachmentCard.tsx) in the composer's strip, in the looks considered
// for Leo's ask (2026-11-01): "bro this is a TERRIBLE text preview we need to do better for these
// text type attachments' previews". `page` ships: the first lines in 11 px monospace from the top,
// faded at the bottom, over "Pasted text · N lines · N characters", as Claude's paste tile. The others are drawn
// here only, by overriding the shipped card's styles: `page-body` (the lines in the body font),
// `header` (the label on top, as ChatGPT's file card names it first) and `tile` (Claude's square
// tile, lines and a PASTED-style label). The prompt's inline card is gallery
// agent-pane.composer `text-pasted-inline`. The pasted card carries Keep as .txt (KeepFileButton,
// ask-48544d7525): an oversized paste sends as a file instead of folding in the prompt.
import React from "react";
import { componentEntry } from "../../../gallery/format";
import type { ComposerAttachment } from "../attachments";
import type { PlayContext } from "../../../gallery/play";

type Look = "page" | "page-body" | "header" | "tile";
type Props = { look: Look };

const transcript = [
  "Ran a command, read a file",
  "$ bun test test/composer-paste-text.test.tsx",
  "  ✓ a paste over 20 lines is a Pasted text chip (41 ms)",
  "  ✓ a paste over 2,000 characters on one line is a chip too",
  ...Array.from({ length: 36 }, (_, index) => `  step ${index + 5}: compiling module ${index + 5}`),
].join("\n");
const config = [
  "{",
  '  "name": "sample-app",',
  '  "version": "1.4.2",',
  '  "scripts": { "build": "vite build", "test": "bun test" }',
  "}",
].join("\n");

const attachments: ComposerAttachment[] = [
  {
    id: "paste",
    kind: "pasted",
    name: "Ran a command, read a file",
    mimeType: "text/plain",
    size: transcript.length,
    text: transcript,
  },
  { id: "file", kind: "text", name: "package.json", mimeType: "application/json", size: config.length, text: config },
];

const LOOKS: Record<Look, string> = {
  page: "",
  "page-body": `[data-text-look=page-body] .acpmux-text-card__lines { font-family: inherit; }`,
  header: `
    [data-text-look=header] .acpmux-text-card .acpmux-attachment-pasted-open { flex-direction: column-reverse; justify-content: flex-end; }
    [data-text-look=header] .acpmux-text-card__label { color: var(--agent-text); font-weight: 600; }`,
  tile: `
    [data-text-look=tile] .acpmux-attachment-pasted { width: 96px; }
    [data-text-look=tile] .acpmux-text-card__lines { white-space: pre-wrap; word-break: break-all; }
    [data-text-look=tile] .acpmux-text-card__label { text-transform: uppercase; }`,
};

/// Right-clicks the strip's paste card: its menu offers Keep as .txt beside Edit in Prompt (review of
/// #37516).
async function openPasteMenu(ctx: PlayContext) {
  const card = ctx.find({ selector: ".acpmux-attachment-pasted" });
  const box = card.getBoundingClientRect();
  card.dispatchEvent(
    new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: box.left + 40, clientY: box.top + 20 }),
  );
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]'));
  if (!/Keep as \.txt/.test(ctx.document.querySelector('[role="menu"]')?.textContent ?? ""))
    throw new Error("the strip's paste card menu must offer Keep as .txt");
}

export default componentEntry<Props>({
  id: "agent-pane.text-attachment-card",
  title: "Text attachment card",
  area: "Composer",
  pane: true,
  height: 240,
  widths: { normal: 560, narrow: 320 },
  covers: [
    "agent-session/acpmux/composer/TextAttachmentCard.tsx",
    "agent-session/acpmux/composer/attachmentIntake.tsx#KeepFileButton",
  ],
  styles: () => import("../styles.css"),
  load: () =>
    import("./attachmentIntake").then(
      ({ AttachmentStrip }) =>
        function TextCards({ look }: Props) {
          return (
            <div
              className="acpmux-shell"
              style={{ padding: 20, display: "block", height: "auto" }}
              data-text-look={look}
            >
              <style>{LOOKS[look]}</style>
              <div className="acpmux-composer">
                <div className="acpmux-composer-box ui-glass" style={{ minHeight: 112 }}>
                  <AttachmentStrip
                    attachments={attachments}
                    onRemove={() => {}}
                    onExpand={() => {}}
                    onKeepFile={() => {}}
                  />
                  <div style={{ padding: 16 }}>Why does the build fail?</div>
                </div>
              </div>
            </div>
          );
        },
    ),
  variants: {
    page: { note: "Shipped: first lines in monospace, faded, over Pasted text · 40 lines.", props: { look: "page" } },
    "page-menu": {
      note: "Right-click on the strip's paste card: Edit in Prompt, Keep as .txt, Remove.",
      props: { look: "page" },
      play: openPasteMenu,
    },
    "page-body": { note: "The same page with the lines in the body font.", props: { look: "page-body" } },
    header: { note: "The label on top, the lines under it.", props: { look: "header" } },
    tile: { note: "Claude's narrow tile: wrapped lines, an uppercase label.", props: { look: "tile" } },
  },
});

// l10n-allow-file: public-safe gallery fixtures.
// Leo: "and why doesn't right click quote put the quote at the bottom? it puts it at the top..."
import { agentPaneEntry } from "../../gallery/format";
import { chat } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import type { MarkdownFieldElement } from "./MarkdownField";

const draft = "I already have a draft reply.";
async function quote(ctx: PlayContext, focused = false, several = false) {
  const page = ctx.document.defaultView as unknown as {
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => unknown>;
  };
  await ctx.waitFor(() => !!page.cmuxAcpmuxActions?.["chat.quoteReply"]);
  const field = ctx.document.querySelector<MarkdownFieldElement>(".acpmux-md-field")!;
  await ctx.waitFor(() => !!field.acpmuxMarkdownField);
  if (focused) {
    field.acpmuxMarkdownField!.focus();
    field.acpmuxMarkdownField!.setCaret(17);
  } else (ctx.document.activeElement as HTMLElement | null)?.blur();
  page.cmuxAcpmuxActions!["chat.quoteReply"]({ markdown: "> Please keep the review focused.\n\n" });
  if (several) {
    (ctx.document.activeElement as HTMLElement | null)?.blur();
    page.cmuxAcpmuxActions!["chat.quoteReply"]({ markdown: "> Then land the change.\n\n" });
  }
  await ctx.waitFor(() => !!field.querySelector("blockquote"));
}

export default agentPaneEntry({
  id: "agent-pane.quote-reply",
  title: "Quote in Reply follows the draft",
  area: "Agent pane",
  height: 500,
  widths: { narrow: 400, normal: 760, wide: 1040 },
  covers: ["agent-session/acpmux/quoteReply.ts", "agent-session/acpmux/Composer.tsx"],
  variants: {
    draft: { ready: { transport: "mock", draft }, snapshot: chat([]) },
    append: {
      note: "A transcript quote follows the draft; the empty reply line takes the caret.",
      ready: { transport: "mock", draft },
      snapshot: chat([]),
      play: (ctx) => quote(ctx),
    },
    focused: {
      note: "A focused caret still sends the quote to the bottom, preserving the existing draft.",
      ready: { transport: "mock", draft },
      snapshot: chat([]),
      play: (ctx) => quote(ctx, true),
    },
    multiple: {
      note: "Two transcript quotes stay in the order they were picked, after the draft.",
      ready: { transport: "mock", draft },
      snapshot: chat([]),
      play: (ctx) => quote(ctx, false, true),
    },
  },
});

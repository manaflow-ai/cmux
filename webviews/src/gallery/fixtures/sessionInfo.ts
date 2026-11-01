// Gallery plays that need Session Info (inspector/ChatInspector.tsx) open beside the chat. It starts
// closed until a person opens it (inspectorState.ts, https://github.com/manaflow-ai/cmux/issues/29874),
// so a play clicks the header's Session Info toggle as a person would, unless this pane already shows
// it (an earlier entry on the same origin left it open).
import type { PlayContext } from "../play";

const shown = (ctx: PlayContext) => ctx.document.querySelector(".acpmux-chat-inspector[data-presence=shown]");

/// Opens Session Info and waits until it is shown.
export async function openSessionInfo(ctx: PlayContext, capMs = 3000): Promise<void> {
  await ctx.waitFor(() => shown(ctx) ?? ctx.document.querySelector('[aria-label="Session Info"]'), { capMs });
  if (!shown(ctx)) await ctx.click({ role: "button", name: "Session Info" });
  await ctx.waitFor(() => shown(ctx), { capMs });
}

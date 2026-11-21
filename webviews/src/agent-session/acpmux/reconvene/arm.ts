// The chat look and speed reconvene (cmuxterm-hq docs/reconvene/chat-look-and-speed.md; Leo,
// 2026-11-10: "prepare a reconvene", he picks). Each `reconvene/*.gallery.ts` entry draws one item: the
// shipped look as `now`, then the candidate designs as gallery-only CSS over the real pane. An arm is
// tokens only (reconvene.test.ts holds every arm to the token-only rule of check-design-tokens.ts), so
// the pick can ship as the same rules in the item's own sheet.
import type { PlayContext } from "../../../gallery/play";

const ARM_ID = "reconvene-arm";

/// One candidate: its rules and the element the stage waits for before the still is taken.
export type Arm = { css: string; ready?: string };

/// Draws `arm` over the mounted pane, replacing an earlier arm, and waits for its element.
export async function showArm(ctx: PlayContext, arm: Arm) {
  ctx.document.getElementById(ARM_ID)?.remove();
  if (arm.css) {
    const style = ctx.document.createElement("style");
    style.id = ARM_ID;
    style.textContent = arm.css;
    ctx.document.head.append(style);
  }
  if (arm.ready) await ctx.waitFor(() => ctx.document.querySelector(arm.ready!));
}

/// `now` (the shipped look, no rules) plus the named candidates, as variant plays.
export const arms = <K extends string>(candidates: Record<K, Arm>) => candidates;

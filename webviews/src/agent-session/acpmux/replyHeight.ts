/// A sub-session reply under its card (SubsessionCallCard.tsx `Cut`): up to three 16px detail lines of
/// about 60 characters, and the toggle once it is cut. Only the first four wrapped lines decide it
/// (three shown, a fourth adds the toggle), so the count stops there instead of splitting the whole
/// reply: a long finished reply or start prompt costs its first few lines, not its length.
export function replyHeight(reply: string): number {
  let lines = 0;
  for (let start = 0; lines <= 3;) {
    const end = reply.indexOf("\n", start);
    lines += Math.max(1, Math.ceil(((end < 0 ? reply.length : end) - start) / 60));
    if (end < 0) break;
    start = end + 1;
  }
  return Math.min(lines, 3) * 16 + (lines > 3 ? 20 : 0);
}

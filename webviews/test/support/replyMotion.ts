// How the reply moved over the painted frames around a turn's end (turn-end-reply-motion-browser.test.ts),
// judged by Leo's rule that no row moves at once: what broke it, empty when nothing did.

/// `replies`: where the reply was drawn on each frame, in order. A reply that moves over more than 8px
/// eases: over three frames or more, under 75% of the move in any one (the house settle front-loads:
/// about half in its biggest frame, the bar turn-end-fold-browser.test.ts holds the fold to), and never
/// past its place and back. A reply that ends where it started, or a few px off, must not move on any
/// frame: a step there and back nets nothing, so the move alone can never clear it.
export function replyMotionProblems(replies: readonly number[]): string[] {
  if (replies.length < 2) return [];
  const move = replies.at(-1)! - replies[0]!;
  const steps = replies.slice(1).map((reply, index) => reply - replies[index]!);
  const biggest = Math.max(...steps.map(Math.abs));
  if (Math.abs(move) <= 8)
    return biggest > 1 ? [`still reply stepped ${biggest.toFixed(1)}px in one frame (move ${move.toFixed(1)})`] : [];
  const problems: string[] = [];
  if (biggest >= Math.abs(move) * 0.75)
    problems.push(`stepped ${biggest.toFixed(1)}px of a ${move.toFixed(1)}px move in one frame`);
  if (steps.filter((step) => Math.abs(step) >= 0.5).length < 3) problems.push("moved in fewer than three frames");
  if (!steps.every((step) => Math.sign(step) !== -Math.sign(move) || Math.abs(step) < 1))
    problems.push("went past its place and back");
  return problems;
}

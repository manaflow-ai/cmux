// LaTeX delimiter normalization for the Markdown renderer.

/**
 * Replies write LaTeX with `\[ … \]` (display) and `\( … \)` (inline) as well as
 * dollars; rewrite them to the dollar forms outside code fences. A display block may span
 * lines; its lines are joined.
 */
export function normalizeMath(lines: string[]): string[] {
  const out: string[] = [];
  let fenced = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    if (/^\s*```/.test(line)) fenced = !fenced;
    if (fenced) {
      out.push(line);
      continue;
    }
    const open = line.match(/^(\s*)\\\[(.*)$/);
    if (open) {
      const body: string[] = [];
      let rest = open[2]!;
      let j = i;
      while (!/\\\]\s*$/.test(rest) && j + 1 < lines.length) {
        body.push(rest);
        rest = lines[++j]!;
      }
      const tex = [...body, rest.replace(/\\\]\s*$/, "")]
        .map((b) => b.trim())
        .filter(Boolean)
        .join(" ");
      // `\[This bracket is escaped.\]` on one line is escaped Markdown brackets around prose,
      // not an equation: three or more plain words with nothing TeX-like.
      const prose = j === i && /^[A-Za-z'’,]+(?:\s+[A-Za-z'’,]+){2,}[.!?:]?$/.test(tex);
      if (/\\\]\s*$/.test(rest) && !prose) {
        out.push(`${open[1]}$$${tex}$$`);
        i = j;
        continue;
      }
    }
    // Inline code keeps its text: `\(x\)` between backticks is not math.
    out.push(
      line.replace(/(`+)[^`]*?\1|\\\((.+?)\\\)/g, (match, ticks: string | undefined, tex: string | undefined) =>
        ticks ? match : `$${tex!.trim()}$`,
      ),
    );
  }
  return out;
}

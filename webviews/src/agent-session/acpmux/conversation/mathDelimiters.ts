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
      if (/\\\]\s*$/.test(rest)) {
        body.push(rest.replace(/\\\]\s*$/, ""));
        const tex = body
          .map((b) => b.trim())
          .filter(Boolean)
          .join(" ");
        out.push(`${open[1]}$$${tex}$$`);
        i = j;
        continue;
      }
    }
    out.push(line.replace(/\\\((.+?)\\\)/g, (_, tex: string) => `$${tex.trim()}$`));
  }
  return out;
}

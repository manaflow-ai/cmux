// Keep a trailing control with the final word, so it cannot become a row by itself. Earlier
// words keep their normal wrapping; unlike a side column this never narrows earlier paragraphs.
import { Children, type ReactNode } from "react";

export function InlineTail({ children, trailing }: { children: ReactNode; trailing?: ReactNode }) {
  if (!trailing) return children;
  const nodes = Children.toArray(children);
  let last = nodes.pop();
  if (typeof last === "string") {
    const match = /^(.*\s)(\S+)$/s.exec(last);
    if (match) {
      nodes.push(match[1]!);
      last = match[2]!;
    }
  }
  return (
    <>
      {nodes}
      <span className="cv-inline-tail">
        <span>{last}</span>
        {trailing}
      </span>
    </>
  );
}

// Non-text final blocks (media, math, rules) share their bottom edge with the links.
// Only this final block participates; earlier message content retains its full width.
export function BlockTail({ children, trailing }: { children: ReactNode; trailing?: ReactNode }) {
  if (!trailing) return children;
  return (
    <div className="cv-block-tail">
      <div>{children}</div>
      {trailing}
    </div>
  );
}

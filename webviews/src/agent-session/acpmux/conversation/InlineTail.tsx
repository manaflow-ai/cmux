// A reply's trailing control (its pull request row, PullRequestDock.tsx). Under a paragraph it is a
// line of its own, right-aligned under the last words, never glued onto the prose; earlier words
// keep their normal wrapping and the paragraph keeps its full width. The gallery's `inline`
// comparison (document attribute `pr-dock="inline"`) keeps the old treatment: the control shares
// the line with the final word.
import { Children, type ReactNode } from "react";

function inlineTreatment(): boolean {
  return typeof document !== "undefined" && document.documentElement.dataset.prDock === "inline";
}

export function InlineTail({ children, trailing }: { children: ReactNode; trailing?: ReactNode }) {
  if (!trailing) return children;
  if (!inlineTreatment())
    // Two fixed slots, so the row keeps its identity (and an open overflow list) while words stream in.
    return (
      <>
        {children}
        <span className="cv-tail-line">{trailing}</span>
      </>
    );
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

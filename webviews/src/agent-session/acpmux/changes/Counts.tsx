// A change's added and removed line counts, in the diff colors. A caller that shortens the numbers
// (`format`) passes the exact counts as `label`, for screen readers; the shortened ones are hidden.
import React, { type ReactNode } from "react";

export function Counts({
  additions,
  deletions,
  format = String,
  label,
}: {
  additions: number;
  deletions: number;
  format?: (count: number) => string;
  label?: ReactNode;
}) {
  const hidden = label === undefined ? undefined : true;
  return (
    <span className="acpmux-diff-counts">
      <span className="acpmux-diff-add" aria-hidden={hidden}>
        +{format(additions)}
      </span>
      <span className="acpmux-diff-del" aria-hidden={hidden}>
        -{format(deletions)}
      </span>
      {label}
    </span>
  );
}

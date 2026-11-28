// A change's added and removed line counts, in the diff colors.
import React from "react";

export function Counts({ additions, deletions }: { additions: number; deletions: number }) {
  return (
    <span className="acpmux-diff-counts">
      <span className="acpmux-diff-add">+{additions}</span>
      <span className="acpmux-diff-del">-{deletions}</span>
    </span>
  );
}

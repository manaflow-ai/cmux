// Minimal TeX typesetting for the arithmetic in agent replies: identifiers in
// italic, binary operators and relations with math spacing, everything else upright, all
// in the STIX face. It covers `$9 - x$` and `$$10x + (9 - x) = 9x + 9$$`; it is not a TeX
// engine (no fractions, scripts or environments).
import type { ReactNode } from "react";

const OPERATORS: Record<string, string> = {
  "+": "+",
  "-": "−",
  "=": "=",
  "−": "−",
  "<": "<",
  ">": ">",
};

function typeset(tex: string): ReactNode[] {
  const out: ReactNode[] = [];
  let run = "";
  const flush = () => {
    if (run) out.push(run);
    run = "";
  };
  for (const ch of tex) {
    if (ch === " ") continue;
    if (/[A-Za-z]/.test(ch)) {
      flush();
      out.push(
        <i key={out.length} className="cv-mi">
          {ch}
        </i>,
      );
    } else if (OPERATORS[ch]) {
      flush();
      out.push(
        <span key={out.length} className="cv-mo">
          {OPERATORS[ch]}
        </span>,
      );
    } else run += ch;
  }
  flush();
  return out;
}

export function MathInline({ tex }: { tex: string }) {
  return <span className="cv-math">{typeset(tex)}</span>;
}

/** Centered display equation. */
export function MathDisplay({ tex }: { tex: string }) {
  return <div className="cv-math-display">{typeset(tex)}</div>;
}

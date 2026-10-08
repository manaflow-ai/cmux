import { useId, type ReactNode } from "react";
import { GLOSSARY, type Term as TermId } from "./glossary";

/** A word with a dotted underline that explains itself on hover or keyboard focus. */
export function Term({ id, children }: { id: TermId; children?: ReactNode }) {
  const tip = useId();
  return (
    <button type="button" className="term" aria-describedby={tip}>
      {children ?? id}
      <span role="tooltip" id={tip} className="tip">
        {GLOSSARY[id]}
      </span>
    </button>
  );
}

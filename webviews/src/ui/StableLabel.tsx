import type { ReactNode } from "react";
import "./stableLabel.css";

/** Keeps an action's box at the widest of its translated labels while its state changes. */
export function StableLabel({ children, reserve }: { children: ReactNode; reserve: readonly ReactNode[] }) {
  return (
    <span className="ui-stable-label">
      <span className="ui-stable-label__current">{children}</span>
      {reserve.map((label, index) => (
        <span key={index} className="ui-stable-label__reserve" aria-hidden="true">
          {label}
        </span>
      ))}
    </span>
  );
}

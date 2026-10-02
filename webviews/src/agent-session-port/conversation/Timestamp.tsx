import type { ReactNode } from "react";

/** Timestamp separator ("Sun, Sep 13 at 7:55 PM"). */
export function Timestamp({ children }: { children: ReactNode }) {
  return <div className="cv-timestamp">{children}</div>;
}

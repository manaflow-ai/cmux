import type { ReactNode } from "react";

/** Consecutive tool rows; the group owns the spacing to the surrounding text. */
export function ToolGroup({ children }: { children: ReactNode }) {
  return <div className="cv-tools">{children}</div>;
}

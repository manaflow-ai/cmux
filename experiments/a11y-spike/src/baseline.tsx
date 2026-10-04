import type { ReactNode } from "react";
export function Providers({ children }: { children: ReactNode }) {
  return <>{children}</>;
}
export function App() {
  return <><button className="trigger">Source</button><input aria-label="Path" /><div role="toolbar" aria-label="Diff tools" /></>;
}

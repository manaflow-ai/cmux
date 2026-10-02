import type { CSSProperties, ReactNode } from "react";
import { CodexLogo } from "./icons";

/** Main column (right of the sidebar). Children are laid out freely; use `relative` positioning inside. */
export function Main({
  children,
  style,
  className = "",
}: {
  children?: ReactNode;
  style?: CSSProperties;
  className?: string;
}) {
  return (
    <main className={`cx-main ${className}`} style={style}>
      {children}
    </main>
  );
}

/** Empty-state hero: Codex mark + "What should we build in <project>?" (project underlined). */
export function EmptyState({
  project = "harness-research",
  prompt = "What should we build in",
  logo,
  style,
}: {
  project?: string | null;
  prompt?: string;
  logo?: ReactNode;
  /** Override placement (default: logo top at 373px from the main column top). */
  style?: CSSProperties;
}) {
  return (
    <div className="cx-hero" style={style}>
      <div className="cx-hero__logo">{logo ?? <CodexLogo />}</div>
      <div className="cx-hero__title">
        {project ? (
          <>
            {prompt} <span className="cx-hero__project">{project}?</span>
          </>
        ) : (
          `${prompt}?`
        )}
      </div>
    </div>
  );
}

/** Composer docked at the bottom center of the main column (empty-state layout). */
export function BottomDock({ children, bottom = 16 }: { children: ReactNode; bottom?: number }) {
  return (
    <div className="cx-dock" style={{ bottom }}>
      {children}
    </div>
  );
}

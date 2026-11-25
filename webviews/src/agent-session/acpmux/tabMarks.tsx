import type React from "react";
import { AgentMark as BrandMark, SessionMark } from "../shared/AgentMark";
import type { HarnessIconSpec } from "../shared/harnessIcons";
import type { TabKind } from "./newTabModel";

// The marks chat lists and the New Tab page share. They live apart from NewTabPage.tsx so a list
// (All chats, chat cards, the queue) does not pull the New Tab page into the chat's first script.

/// The agent's brand mark (design/agent-icons) or its harness's own icon, so a session's row says
/// which agent it is at a glance; an agent without either draws the generic agent glyph.
/// A chat's mark: the icon it set (acpmux `icon`), else its harness's.
export function AgentMark({ harness, icon }: { harness?: string; icon?: HarnessIconSpec }) {
  if (icon) return <SessionMark icon={icon} agent={harness} size={16} fallback={<KindIcon kind="agent" />} />;
  return <BrandMark agent={harness} size={16} fallback={<KindIcon kind="agent" />} />;
}

// 16px stroke icons in currentColor, matching ComposerPickers.
export function StrokeIcon({ children }: { children: React.ReactNode }) {
  return (
    <svg
      className="acpmux-icon"
      width={16}
      height={16}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}

export function KindIcon({ kind }: { kind: TabKind }) {
  switch (kind) {
    case "terminal":
      return (
        <StrokeIcon>
          <rect x="1.75" y="2.75" width="12.5" height="10.5" rx="2" />
          <path d="m4.6 6.2 2 1.8-2 1.8M8.4 10h3" />
        </StrokeIcon>
      );
    case "browser":
      return (
        <StrokeIcon>
          <circle cx="8" cy="8" r="6.1" />
          <path d="M1.9 8h12.2M8 1.9c1.7 1.7 2.5 3.7 2.5 6.1S9.7 12.4 8 14.1C6.3 12.4 5.5 10.4 5.5 8S6.3 3.6 8 1.9Z" />
        </StrokeIcon>
      );
    case "agent":
      return (
        <StrokeIcon>
          <path d="M8 1.9c.4 2.9 1.6 4.1 4.6 4.6-3 .5-4.2 1.7-4.6 4.6-.4-2.9-1.6-4.1-4.6-4.6 3-.5 4.2-1.7 4.6-4.6Z" />
          <path d="M12.4 10.4c.15 1.1.6 1.55 1.7 1.7-1.1.15-1.55.6-1.7 1.7-.15-1.1-.6-1.55-1.7-1.7 1.1-.15 1.55-.6 1.7-1.7Z" />
        </StrokeIcon>
      );
  }
}

import React from "react";
import { ChatMinimap } from "../chatMinimap/ChatMinimap";
import { FindReveal } from "../conversation/chatFind";
import { GuestActionsBoundary } from "../conversation/GuestActionsBoundary";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { JumpToLatest } from "./JumpButtons";
import { LiveLinePulseContext } from "../conversation/liveLinePulse";
import { DisclosureMotion, type RunDisclosure } from "../conversation/transcriptDisclosureModel";

/// A wheel tick re-renders the transcript; these draw again only when their own props change (the minimap reads
/// the scroll from its scroller, not from a prop).
export const JumpToLatestMemo = React.memo(JumpToLatest);
export const ChatMinimapMemo = React.memo(ChatMinimap);

/// A read-only transcript draws inside the guest boundary (conversation/GuestActionsBoundary.tsx).
export function ReadOnlyBoundary({ readOnly, children }: { readOnly: boolean; children: React.ReactNode }) {
  return readOnly ? <GuestActionsBoundary>{children}</GuestActionsBoundary> : <>{children}</>;
}

/// What the transcript's rows read from it: Find's reveal target and, for a prompt's own bookmark
/// button, the session its marks key into (threadMinimap/promptMarks.ts).
export function TranscriptContext({
  find,
  sessionId,
  children,
}: {
  find: React.ContextType<typeof FindReveal>;
  sessionId?: string;
  children: React.ReactNode;
}) {
  return (
    <FindReveal.Provider value={find}>
      <PromptMarksSession.Provider value={sessionId ?? ""}>{children}</PromptMarksSession.Provider>
    </FindReveal.Provider>
  );
}

/// What rows read about their motion: the live line's pulse and a disclosure's one transition
/// (useDisclosure.ts). One wrapper, so a new row context never re-indents the shell's JSX.
export function RowMotionContexts({
  livePulse,
  runDisclosure,
  children,
}: {
  livePulse: React.ContextType<typeof LiveLinePulseContext>;
  runDisclosure: RunDisclosure;
  children: React.ReactNode;
}) {
  return (
    <LiveLinePulseContext.Provider value={livePulse}>
      <DisclosureMotion.Provider value={runDisclosure}>{children}</DisclosureMotion.Provider>
    </LiveLinePulseContext.Provider>
  );
}

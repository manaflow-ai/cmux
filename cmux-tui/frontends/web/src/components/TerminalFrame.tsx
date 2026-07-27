import type { ReactNode } from "react";
import type { CmuxClient } from "cmux/browser";
import { ExtraKeysBar } from "./ExtraKeysBar";

interface TerminalFrameProps {
  children: ReactNode;
  client: CmuxClient | null;
  focused: boolean;
  error: string | null;
  onKey?(key: string): void;
  onSend(text: string): void;
}

export function TerminalFrame({
  children,
  client,
  focused,
  error,
  onKey,
  onSend,
}: TerminalFrameProps) {
  return (
    <>
      <div className={`terminal-stage${focused ? " terminal-focused" : ""}`}>
        {children}
        {error && <div className="terminal-error" role="alert">{error}</div>}
      </div>
      <ExtraKeysBar visible={focused && client !== null} onKey={onKey} onSend={onSend} />
    </>
  );
}

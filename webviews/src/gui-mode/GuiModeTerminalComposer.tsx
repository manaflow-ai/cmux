import React from "react";
import type { AgentSessionCopy, GuiModeSessionContext } from "../agent-session/shared/types";
import { GuiModeContextStrip, GuiModeModeToggle } from "./GuiModeSessionChrome";

export type TerminalCommandResult = {
  command: string;
  output: string;
  exitCode: number;
};

export function GuiModeTerminalComposer({ context, copy, editor, pending, canSend, result, onModeChange, onSubmit, onCancel }: {
  context: GuiModeSessionContext;
  copy?: AgentSessionCopy;
  editor: React.ReactNode;
  pending: boolean;
  canSend: boolean;
  result: TerminalCommandResult | null;
  onModeChange: (mode: "chat" | "terminal") => void;
  onSubmit: () => void;
  onCancel: () => void;
}) {
  return <div className="gui-terminal-composer">
    <div className="gui-terminal-header">
      <GuiModeModeToggle mode="terminal" context={context} onChange={onModeChange} />
      <GuiModeContextStrip context={context} />
    </div>
    <div className="gui-terminal-command-row">
      <span className="gui-terminal-prompt" aria-hidden="true">›</span>
      {editor}
      {pending && <output className="gui-terminal-progress">{copy?.runningStatus}</output>}
      <button type="button" className="gui-terminal-run" disabled={!pending && !canSend}
        aria-label={pending ? copy?.stop : copy?.send} onMouseDown={(event) => event.preventDefault()}
        onClick={pending ? onCancel : onSubmit}>
        {pending
          ? <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><rect x="4" y="4" width="8" height="8" rx="1.5" fill="currentColor" /></svg>
          : <svg width="18" height="18" viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="M10 15V5m-4 4 4-4 4 4" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" /></svg>}
      </button>
    </div>
    {result && (result.output || result.exitCode !== 0) && <div className="gui-mode-terminal-result" data-failed={result.exitCode !== 0}>
      <div className="gui-terminal-result-heading"><code>{result.command}</code><span>{result.exitCode === 0 ? copy?.shellSuccess : copy?.failedStatus}</span></div>
      <pre>{result.output}</pre>
    </div>}
  </div>;
}

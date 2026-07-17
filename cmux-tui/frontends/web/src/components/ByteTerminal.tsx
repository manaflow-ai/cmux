import type { CmuxClient, Id } from "cmux/browser";
import { useAttachedTerminal } from "../hooks/useAttachedTerminal";
import { TerminalFrame } from "./TerminalFrame";

interface ByteTerminalProps {
  client: CmuxClient | null;
  surface: Id;
  error: string | null;
  onError(error: Error): void;
}

export function ByteTerminal({ client, surface, error, onError }: ByteTerminalProps) {
  const { terminalRef, focused } = useAttachedTerminal({ client, surface, onError });
  return (
    <TerminalFrame
      client={client}
      focused={focused}
      error={error}
      onSend={(text) => {
        if (client !== null) void client.send(surface, { text }).catch(onError);
      }}
    >
      <div className="terminal-host" ref={terminalRef} />
    </TerminalFrame>
  );
}

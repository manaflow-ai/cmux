import type { ClientInfo, CmuxClient, Id } from "cmux/browser";
import { useAttachedTerminal } from "../hooks/useAttachedTerminal";
import { TerminalFrame } from "./TerminalFrame";

interface ByteTerminalProps {
  client: CmuxClient | null;
  clients: ClientInfo[];
  surface: Id;
  error: string | null;
  onError(error: Error): void;
}

export function ByteTerminal({ client, clients, surface, error, onError }: ByteTerminalProps) {
  const { terminalRef, focused, foreignSize } = useAttachedTerminal({ client, surface, onError });
  return (
    <TerminalFrame
      client={client}
      clients={clients}
      surface={surface}
      focused={focused}
      foreignSize={foreignSize}
      error={error}
      onSend={(text) => {
        if (client !== null) void client.send(surface, { text }).catch(onError);
      }}
    >
      <div className={`terminal-host${foreignSize === null ? "" : " foreign-sized"}`} ref={terminalRef} />
    </TerminalFrame>
  );
}

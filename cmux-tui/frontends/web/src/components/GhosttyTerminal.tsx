import { useMemo } from "react";
import type { CmuxClient, Id } from "cmux/raw";
import { useGhosttyTerminal } from "../hooks/useGhosttyTerminal";
import { localWebSocketTransport } from "../lib/terminalTransport";
import { TerminalFrame } from "./TerminalFrame";

interface GhosttyTerminalProps {
  client: CmuxClient | null;
  surface: Id;
  error: string | null;
  focusOnMount?: boolean;
  onError(error: Error): void;
}

/** A terminal surface rendered by ghostty-web from the surface's byte stream
 * (RFD 0083 step 4), behind `?terminal=ghostty`. */
export function GhosttyTerminal({ client, surface, error, focusOnMount = false, onError }: GhosttyTerminalProps) {
  const transport = useMemo(() => (client === null ? null : localWebSocketTransport(client)), [client]);
  const { terminalRef, focused } = useGhosttyTerminal({ transport, surface, focusOnMount, onError });
  return (
    <TerminalFrame
      client={client}
      focused={focused}
      error={error}
      onSend={(text) => {
        if (transport !== null) void transport.input(surface, text).catch(onError);
      }}
    >
      <div className="terminal-host ghostty-terminal-host" data-renderer="ghostty" ref={terminalRef} />
    </TerminalFrame>
  );
}

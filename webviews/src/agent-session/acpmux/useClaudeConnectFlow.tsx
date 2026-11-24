import { useState, type ReactNode } from "react";
import { CLAUDE_CONNECT_BRAND, useClaudeConnect, type ClaudeConnectRowProps } from "./claudeConnect";
import { ClaudeConnectDialog } from "./ClaudeConnectDialog";

/// The composer's half of the flow: the picker's row props (undefined when there is no host
/// provider or nothing to connect) and the dialog to render beside the picker.
export function useClaudeConnectFlow(): { row?: ClaudeConnectRowProps; dialog: ReactNode } {
  const host = useClaudeConnect();
  const [open, setOpen] = useState(false);
  const [saved, setSaved] = useState(false);
  // Connected lasts until the host's `needed` turns false (the row goes); a later need (the
  // connection was removed) starts over with Connect.
  if (saved && !host?.needed) setSaved(false);
  // A host with its own way in (`open`) takes Connect there; the dialog is only for a host that adds
  // the pasted token itself (`add`).
  const row: ClaudeConnectRowProps | undefined = host?.needed
    ? {
        brand: host.brand ?? CLAUDE_CONNECT_BRAND,
        connected: saved,
        onConnect: () => (host.open ? host.open() : setOpen(true)),
      }
    : undefined;
  const dialog =
    open && host?.add ? (
      <ClaudeConnectDialog
        add={host.add}
        onClose={() => setOpen(false)}
        onConnected={() => {
          setOpen(false);
          setSaved(true);
        }}
      />
    ) : null;
  return { ...(row ? { row } : {}), dialog };
}

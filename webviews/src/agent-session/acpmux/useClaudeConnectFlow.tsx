import { useState, type ReactNode } from "react";
import {
  CLAUDE_CONNECT_BRAND,
  CODEX_CONNECT_BRAND,
  CONNECT_IDLE,
  useClaudeConnect,
  type ClaudeConnectRowProps,
} from "./claudeConnect";
import { ConnectCard } from "./ConnectCard";

/// The composer's half of the flow: the picker's row props (undefined when there is no host
/// provider or nothing to connect) and the inline connect card to render beside the picker. Connect
/// on the row opens the card and starts the host's one click at once (`begin`), so the person sees
/// its progress line without a second press; a host with only its own way in (`open`) runs that.
export function useClaudeConnectFlow(): { row?: ClaudeConnectRowProps; card: ReactNode } {
  const host = useClaudeConnect();
  const [open, setOpen] = useState(false);
  const [saved, setSaved] = useState(false);
  const [ran, setRan] = useState(false);
  const progress = host?.progress ?? CONNECT_IDLE;
  // A sign-in that ran and ended with no error saved the connection: Connected until the host's
  // `needed` turns false (the row and card go); a later need (it was removed) starts over.
  if (open && progress.phase !== null && !ran) setRan(true);
  if (ran && progress.phase === null && progress.error === null && !saved) setSaved(true);
  if ((saved || open || ran) && !host?.needed) {
    setSaved(false);
    setOpen(false);
    setRan(false);
  }
  const begin = host?.begin;
  const row: ClaudeConnectRowProps | undefined = host?.needed
    ? {
        brand: host.brand ?? CLAUDE_CONNECT_BRAND,
        connected: saved,
        onConnect: () => {
          if (begin || host.add) {
            setOpen(true);
            if (begin) void begin().catch(() => undefined);
          } else host.open?.();
        },
      }
    : undefined;
  const family = (host?.brand ?? CLAUDE_CONNECT_BRAND) === CODEX_CONNECT_BRAND ? "codex" : "claude";
  const card =
    open && host?.needed ? (
      <div className="acpmux-connect-float ui-glass ui-glass-floats">
        <ConnectCard
          family={family}
          progress={progress}
          done={saved}
          {...(begin ? { onBegin: begin } : {})}
          {...(host.cancel
            ? {
                onCancel: () => {
                  // A Cancel ends the run with no error: not a save, so no Connected; the card
                  // folds back to the row's Connect.
                  setOpen(false);
                  setRan(false);
                  host.cancel?.();
                },
              }
            : {})}
          {...(host.add
            ? {
                onPaste: async (token: string) => {
                  await host.add?.(token);
                  setSaved(true);
                },
              }
            : {})}
          {...(host.addKey ? { onApiKey: host.addKey } : {})}
          onDismiss={() => setOpen(false)}
        />
      </div>
    ) : null;
  return { ...(row ? { row } : {}), card };
}

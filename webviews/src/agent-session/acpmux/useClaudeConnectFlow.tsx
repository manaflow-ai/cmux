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
  const [openBrand, setOpenBrand] = useState<string>();
  const [saved, setSaved] = useState(false);
  const [ran, setRan] = useState(false);
  const progress = host?.progress ?? CONNECT_IDLE;
  // A sign-in that ran and ended with no error saved the connection: Connected until the host's
  // `needed` turns false (the row and card go); a later need (it was removed) starts over.
  if (openBrand && progress.phase !== null && !ran) setRan(true);
  if (ran && progress.phase === null && progress.error === null && !saved) setSaved(true);
  const brands = host?.brands ?? [CLAUDE_CONNECT_BRAND];
  if ((saved || openBrand || ran) && (!host?.needed || (openBrand && !brands.includes(openBrand)))) {
    setSaved(false);
    setOpenBrand(undefined);
    setRan(false);
  }
  const begin = host?.begin;
  const row: ClaudeConnectRowProps | undefined = host?.needed
    ? {
        brands,
        connected: saved,
        onConnect: (brand = brands[0]) => {
          if (!brand || !brands.includes(brand)) return;
          if (begin || host.add) {
            setOpenBrand(brand);
            if (begin && progress.phase === null) void begin(brand).catch(() => undefined);
          } else host.open?.(brand);
        },
      }
    : undefined;
  const family = openBrand === CODEX_CONNECT_BRAND ? "codex" : "claude";
  const card =
    openBrand && host?.needed && brands.includes(openBrand) ? (
      <div className="acpmux-connect-float ui-glass ui-glass-floats">
        <ConnectCard
          family={family}
          progress={progress}
          done={saved}
          {...(begin ? { onBegin: () => begin(openBrand) } : {})}
          {...(host.cancel
            ? {
                onCancel: () => {
                  // A Cancel ends the run with no error: not a save, so no Connected; the card
                  // folds back to the row's Connect.
                  setOpenBrand(undefined);
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
          onDismiss={() => setOpenBrand(undefined)}
        />
      </div>
    ) : null;
  return { ...(row ? { row } : {}), card };
}

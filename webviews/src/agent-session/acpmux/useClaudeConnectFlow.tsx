import { useState, type ReactNode } from "react";
import {
  CLAUDE_CONNECT_BRAND,
  CODEX_CONNECT_BRAND,
  CONNECT_IDLE,
  useClaudeConnect,
  type ClaudeConnectRowProps,
} from "./claudeConnect";
import { ConnectCard } from "./ConnectCard";

type ConnectFlowState = { openBrand: string | undefined; saved: boolean; ran: boolean };

/// The connect flow's next state, a fixed point (a second step changes nothing): a sign-in that
/// started has run; one that ran and ended with no error saved; and when the host no longer needs a
/// connection (or the open brand left its list) the flow starts over.
export function connectFlowStep(
  state: ConnectFlowState,
  host: { phase: unknown; error: unknown; needed: boolean; brands: readonly string[] },
): ConnectFlowState {
  const { openBrand } = state;
  const ran = state.ran || (openBrand !== undefined && host.phase !== null);
  const saved = state.saved || (ran && host.phase === null && host.error === null);
  const over = !host.needed || (openBrand !== undefined && !host.brands.includes(openBrand));
  if ((saved || openBrand || ran) && over) return { openBrand: undefined, saved: false, ran: false };
  return { openBrand, saved, ran };
}

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
  // One idempotent step (test/render-phase-set-pairs.test.ts): each state is set once, to a fixed point.
  const brands = host?.brands ?? [CLAUDE_CONNECT_BRAND];
  const next = connectFlowStep({ openBrand, saved, ran }, { ...progress, needed: !!host?.needed, brands });
  if (next.ran !== ran) setRan(next.ran);
  if (next.saved !== saved) setSaved(next.saved);
  if (next.openBrand !== openBrand) setOpenBrand(next.openBrand);
  const begin = host?.begin;
  const row: ClaudeConnectRowProps | undefined = host?.needed
    ? {
        brands,
        connected: saved,
        onConnect: (asked?: string) => {
          const brand = asked ?? brands[0];
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

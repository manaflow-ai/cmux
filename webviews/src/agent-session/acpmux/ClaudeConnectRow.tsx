// The model picker's Claude Code row while no Claude connection serves Cloud (claudeConnect.ts):
// the harness's mark and name, one muted line, and a Connect button at the trailing edge, above the
// section's models and parted from them by a hairline. Connect opens the inline connect card
// (ConnectCard.tsx) above the composer's chips and starts the one click; once saved the row says
// Connected until the host's connection list catches up, then both go. The card lives beside the
// picker (the menu closes on Connect), so the composer holds both through `useClaudeConnectFlow`.
import { useState, type ReactNode } from "react";
import { AgentMark, agentBrand } from "../shared/AgentMark";
import {
  CLAUDE_CONNECT_BRAND,
  CODEX_CONNECT_BRAND,
  CONNECT_IDLE,
  connectDetailKey,
  useClaudeConnect,
  type ClaudeConnectRowProps,
} from "./claudeConnect";
import { ConnectCard } from "./ConnectCard";
import { Check } from "./conversation/icons";
import { useT } from "./i18n";
import "./claudeConnect.css";

export function ClaudeConnectRow({
  name,
  mark,
  connected,
  onConnect,
}: {
  /// The section's harness name ("Claude Code"): a product name, shown as it is.
  name: string;
  mark?: string;
  connected: boolean;
  /// Connect's press. Without it the row sits in a menu item that answers the press itself
  /// (QuickModelMenu), so Connect draws as the button's look on a plain label.
  onConnect?(): void;
}) {
  const t = useT();
  return (
    <span className="acpmux-connect-claude-row" data-connected={connected || undefined}>
      <AgentMark agent={mark ?? CLAUDE_CONNECT_BRAND} size={14} reserve />
      <span className="acpmux-connect-claude-row-text">
        <span className="acpmux-connect-claude-row-name">{name}</span>
        <span className="acpmux-connect-claude-row-detail">
          {connected ? (
            <>
              <Check size={12} /> {t("picker.connectClaude.connected")}
            </>
          ) : (
            t(connectDetailKey(agentBrand(mark ?? CLAUDE_CONNECT_BRAND)))
          )}
        </span>
      </span>
      {!connected &&
        (onConnect ? (
          <button
            type="button"
            className="ui-button ui-btn acpmux-connect-claude-row-button"
            data-variant="subtle"
            data-size="sm"
            onClick={() => onConnect()}
          >
            {t("picker.connectClaude.connect")}
          </button>
        ) : (
          <span className="ui-button ui-btn acpmux-connect-claude-row-button" data-variant="subtle" data-size="sm">
            {t("picker.connectClaude.connect")}
          </span>
        ))}
    </span>
  );
}

type ConnectFlowState = { openBrand: string | undefined; saved: boolean; ran: boolean };

/// The flow's next state from this one and the host's progress, a fixed point (a second step changes
/// nothing). A sign-in that ran and ended with no error is saved; the flow starts over once the host
/// no longer needs a connection, or the open brand left the host's list.
export function connectFlowStep(
  state: ConnectFlowState,
  progress: { phase: unknown; error: unknown },
  needed: boolean,
  brands: readonly string[],
): ConnectFlowState {
  const ran = state.ran || (!!state.openBrand && progress.phase !== null);
  const saved = state.saved || (state.ran && progress.phase === null && progress.error === null);
  if ((saved || state.openBrand || ran) && (!needed || (state.openBrand && !brands.includes(state.openBrand))))
    return { openBrand: undefined, saved: false, ran: false };
  return { openBrand: state.openBrand, saved, ran };
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
  // One idempotent step (render-phase-set-pairs.test.ts): each state's next value is computed once
  // and set only when it differs, so no two lines can undo each other.
  const brands = host?.brands ?? [CLAUDE_CONNECT_BRAND];
  const next = connectFlowStep({ openBrand, saved, ran }, progress, !!host?.needed, brands);
  if (next.ran !== ran) setRan(next.ran);
  if (next.saved !== saved) setSaved(next.saved);
  if (next.openBrand !== openBrand) setOpenBrand(next.openBrand);
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

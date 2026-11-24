import { AgentMark, agentBrand } from "../shared/AgentMark";
import { CLAUDE_CONNECT_BRAND, connectDetailKey, useClaudeConnect, type ClaudeConnectRowProps } from "./claudeConnect";
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

/// The Cloud setup action exposed in the picker's provider section.
export function useClaudeConnectFlow(): ClaudeConnectRowProps | undefined {
  const host = useClaudeConnect();
  if (!host?.needed) return undefined;
  const brands = host.brands ?? [CLAUDE_CONNECT_BRAND];
  return { brands, connected: false, onConnect: (brand) => host.open(brand ?? brands[0] ?? CLAUDE_CONNECT_BRAND) };
}

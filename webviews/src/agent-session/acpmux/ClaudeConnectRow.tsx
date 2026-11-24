// The model picker's Claude Code row while no Claude connection serves Cloud (claudeConnect.ts):
// the harness's mark and name, one muted line, and a Connect button at the trailing edge, above the
// section's models and parted from them by a hairline. Once the token is saved it says Connected
// until the host's connection list catches up, then the row goes. The dialog lives beside the
// picker (the menu closes on Connect), so the composer holds both through `useClaudeConnectFlow`.
import { AgentMark, agentBrand } from "../shared/AgentMark";
import { CLAUDE_CONNECT_BRAND, connectDetailKey } from "./claudeConnect";
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
    <div className="acpmux-connect-claude-row" data-connected={connected || undefined}>
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
            onClick={onConnect}
          >
            {t("picker.connectClaude.connect")}
          </button>
        ) : (
          <span className="ui-button ui-btn acpmux-connect-claude-row-button" data-variant="subtle" data-size="sm">
            {t("picker.connectClaude.connect")}
          </span>
        ))}
    </div>
  );
}

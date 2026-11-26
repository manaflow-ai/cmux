// cmux Tools: whether agents the person starts in cmux (its terminals and agent chats) get cmux's MCP
// server, Computer Use included. A row per coding agent found on this Mac (its mark, name and whether
// it gets cmux's tools in cmux), in the Agents step's list look; one line under the list (Checking…,
// none found, Turning on…, what the answer did); and the place in Settings to change it later. The
// footer's Not Now answers no; Turn On answers yes, then the footer says Done. Neither writes an
// agent's own settings. The host does both (CmuxNextOnboarding AgentToolsStepModel).
import { StatusGlyph } from "../../ui/StatusGlyph";
import { AgentMark } from "../../agent-session/shared/AgentMark";
import { cx } from "../../ui/cx";
import type { AgentToolsState } from "./ops";
import { useOnboarding } from "./parts";
import { agentToolsDetail, agentToolsStatus } from "./text";

export function AgentToolsStep({ tools }: { tools: AgentToolsState | null | undefined }) {
  const { strings } = useOnboarding();
  const rows = tools?.rows ?? [];
  const status = agentToolsStatus(strings, tools);
  return (
    <div className="onb-agents onb-agent-tools">
      <div className="onb-scroll">
        <ul className="onb-agent-list" data-look="list" hidden={rows.length === 0}>
          {rows.map((row) => {
            return (
              <li key={row.id} className="onb-agent" data-agent={row.id} data-tools={row.state}>
                <span className="onb-agent-mark">
                  <AgentMark agent={row.id} size={24} />
                </span>
                <span className="onb-agent-names">
                  <span className="onb-agent-name">{row.name}</span>
                  <span className={cx("onb-agent-detail", row.state === "failed" && "is-error")}>
                    {tools ? agentToolsDetail(strings, row, tools) : ""}
                  </span>
                </span>
                <span className="onb-agent-trailing" aria-hidden="true">
                  {(row.state === "terminals" || row.state === "failed") && (
                    <StatusGlyph name={row.state === "failed" ? "error" : "done"} size={16} />
                  )}
                </span>
              </li>
            );
          })}
        </ul>
      </div>
      <output className="onb-status" aria-live="polite">
        {status ?? ""}
      </output>
      <p className="onb-agent-tools-note">{strings.t("onboarding.agentTools.settings")}</p>
    </div>
  );
}

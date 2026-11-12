// cmux Tools: whether cmux may add its MCP server (Computer Use included) to the person's own coding
// agents. A row per coding agent found on this Mac (its mark, name and what its config holds), in the
// Agents step's list look; one line under the list (Checking…, none found, Adding…, what the answer
// did); and the place in Settings to change it later. The footer's Not Now answers no and writes
// nothing; Add to My Agents answers yes and runs `cmux setup mcp` for the agents found, then the
// footer says Done. The host does both (CmuxNextOnboarding AgentToolsStepModel).
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
                  {(row.state === "added" || row.state === "failed") && (
                    <StatusGlyph name={row.state === "added" ? "done" : "error"} size={16} />
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

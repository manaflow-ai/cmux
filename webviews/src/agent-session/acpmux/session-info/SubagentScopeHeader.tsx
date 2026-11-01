// Whose Session Info it is, while it lists a subagent's things (subagentScope.ts): "Subagent · <name>",
// with a back button to what spawned it (its parent subagent's view, else the chat's). The gallery
// shows three ways to say it; the panel uses SUBAGENT_HEADER.
//
// - `title`: in the panel's own head, in place of "Session Info": the back button, then
//   "Subagent · <name>". One line, no room taken from the sections.
// - `crumb`: under the head, a path: the parent's name (a link back) › "Subagent · <name>".
// - `card`: under the head, a card like the sections': the agent glyph, "Subagent · <name>", its
//   task under it, and "Back to <parent>".
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { AgentMark } from "../../shared/AgentMark";
import { agentTone } from "../subagents/agentTones";
import { TonedIcon } from "../subagents/TonedIcon";
import { tooltipProps } from "../shortcuts";
import type { SubagentScope } from "./subagentScope";

export type SubagentHeaderVariant = "title" | "crumb" | "card";
/// The one the panel draws.
export const SUBAGENT_HEADER: SubagentHeaderVariant = "title";

type Props = { scope: Pick<SubagentScope, "agent" | "parent" | "onBack"> };

function Back({ scope }: Props) {
  const t = useT();
  if (!scope.onBack) return null;
  const label = t("sessionInfo.subagent.back", { name: scope.parent });
  return (
    <button
      type="button"
      className="acpmux-session-info-icon-button acpmux-session-info-scope__back"
      aria-label={label}
      {...tooltipProps(label, undefined)}
      onClick={scope.onBack}
    >
      <Icon name="nav.back" size={12} />
    </button>
  );
}

/// "Subagent · <name>".
function Name({ scope }: Props) {
  const t = useT();
  return (
    <span className="acpmux-session-info-scope__name">
      <span className="acpmux-session-info-scope__kind">{t("sessionInfo.subagent")}</span>
      <span className="acpmux-session-info-scope__dot" aria-hidden="true">
        ·
      </span>
      <span className="acpmux-session-info-scope__agent">{scope.agent.name}</span>
    </span>
  );
}

/// The `title` variant: the panel head's title.
export function SubagentTitle({ scope }: Props) {
  return (
    <span className="acpmux-session-info__title acpmux-session-info-scope" data-variant="title">
      <Back scope={scope} />
      <Name scope={scope} />
    </span>
  );
}

/// The `crumb` and `card` variants: the body's first line.
export function SubagentBanner({ scope, variant }: Props & { variant: Exclude<SubagentHeaderVariant, "title"> }) {
  const t = useT();
  if (variant === "crumb")
    return (
      <div className="acpmux-session-info-scope" data-variant="crumb">
        {scope.onBack ? (
          <button type="button" className="acpmux-session-info-scope__parent" onClick={scope.onBack}>
            <Icon name="nav.back" size={12} />
            <span>{scope.parent}</span>
          </button>
        ) : (
          <span className="acpmux-session-info-scope__parent">{scope.parent}</span>
        )}
        <Icon name="disclosure.collapsed" size={10} className="acpmux-session-info-scope__sep" />
        <Name scope={scope} />
      </div>
    );
  return (
    <div className="acpmux-session-info-scope" data-variant="card">
      <span className="acpmux-session-info-scope__glyph">
        {scope.agent.harness ? (
          <AgentMark
            agent={scope.agent.harness}
            size={14}
            fallback={<TonedIcon name="agent.session" size={14} tone={agentTone(scope.agent.id)} />}
          />
        ) : (
          <TonedIcon name="agent.session" size={14} tone={agentTone(scope.agent.id)} />
        )}
      </span>
      <span className="acpmux-session-info-scope__text">
        <Name scope={scope} />
        {scope.agent.task && scope.agent.task !== scope.agent.name && (
          <span className="acpmux-session-info-scope__task">{scope.agent.task}</span>
        )}
      </span>
      {scope.onBack && (
        <button type="button" className="acpmux-session-info-link" onClick={scope.onBack}>
          {t("sessionInfo.subagent.back", { name: scope.parent })}
        </button>
      )}
    </div>
  );
}

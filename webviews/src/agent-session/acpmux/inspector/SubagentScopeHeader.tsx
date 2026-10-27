// Whose Inspector it is, while it lists a subagent's things (subagentScope.ts): "Subagent · <name>",
// with a back button to what spawned it (its parent subagent's view, else the chat's). The gallery
// shows three ways to say it; the panel uses SUBAGENT_HEADER.
//
// - `title`: in the panel's own head, in place of "Inspector": the back button, then
//   "Subagent · <name>". One line, no room taken from the sections.
// - `crumb`: under the head, a path: the parent's name (a link back) › "Subagent · <name>".
// - `card`: under the head, a card like the sections': the agent glyph, "Subagent · <name>", its
//   task under it, and "Back to <parent>".
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { tooltipProps } from "../shortcuts";
import type { SubagentScope } from "./subagentScope";
import { subagentName } from "../subagents/subagentNavigation";

export type SubagentHeaderVariant = "title" | "crumb" | "card";
/// The one the panel draws.
export const SUBAGENT_HEADER: SubagentHeaderVariant = "title";

type Props = { scope: Pick<SubagentScope, "agent" | "parent" | "onBack"> };

function Back({ scope }: Props) {
  const t = useT();
  if (!scope.onBack) return null;
  const label = t("chatInspector.subagent.back", { name: scope.parent });
  return (
    <button
      type="button"
      className="acpmux-chat-inspector-icon-button acpmux-chat-inspector-scope__back"
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
    <span className="acpmux-chat-inspector-scope__name">
      <span className="acpmux-chat-inspector-scope__kind">{t("chatInspector.subagent")}</span>
      <span className="acpmux-chat-inspector-scope__dot" aria-hidden="true">
        ·
      </span>
      <span className="acpmux-chat-inspector-scope__agent">{subagentName(scope.agent)}</span>
    </span>
  );
}

/// The `title` variant: the panel head's title.
export function SubagentTitle({ scope }: Props) {
  return (
    <span className="acpmux-chat-inspector__title acpmux-chat-inspector-scope" data-variant="title">
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
      <div className="acpmux-chat-inspector-scope" data-variant="crumb">
        {scope.onBack ? (
          <button type="button" className="acpmux-chat-inspector-scope__parent" onClick={scope.onBack}>
            <Icon name="nav.back" size={12} />
            <span>{scope.parent}</span>
          </button>
        ) : (
          <span className="acpmux-chat-inspector-scope__parent">{scope.parent}</span>
        )}
        <Icon name="disclosure.collapsed" size={10} className="acpmux-chat-inspector-scope__sep" />
        <Name scope={scope} />
      </div>
    );
  return (
    <div className="acpmux-chat-inspector-scope" data-variant="card">
      <Icon name="agent.session" size={14} className="acpmux-chat-inspector-scope__glyph" />
      <span className="acpmux-chat-inspector-scope__text">
        <Name scope={scope} />
        {scope.agent.task && scope.agent.task !== subagentName(scope.agent) && (
          <span className="acpmux-chat-inspector-scope__task">{scope.agent.task}</span>
        )}
      </span>
      {scope.onBack && (
        <button type="button" className="acpmux-chat-inspector-link" onClick={scope.onBack}>
          {t("chatInspector.subagent.back", { name: scope.parent })}
        </button>
      )}
    </div>
  );
}

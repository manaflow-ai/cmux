// A subagent's view draws its rows as a chat's do, with no line about where it came from (Leo,
// 2026-11-22: "i notice there's differing layouts among it and normal chats. like the metadata about
// provenance or whatever like subagent of something. we shouldn't have those. we should align things
// better."). What that line carried stays, as small controls in the transcript's top end corner
// (VirtualTranscript `corner`, overlayLayout.ts `viewCorner`), over the rows and taking none of their
// room:
// - a × that closes the subagent's view to the chat's, as Escape does (subagentEscape.ts), in the
//   in-place view only, where the subagent stands in the chat's own pane (Leo, 2026-11-03: "this
//   opened subagent has no close button"); a subagent's own pane closes from its tab;
// - Resume on a stopped helper (Leo, 2026-11-12: "A Resume button in cmux on a stopped helper's row
//   and tab"), in either.
import { useContext } from "react";
import { TurnActionsContext } from "../conversation/turnActions";
import { Icon } from "../icons/Icon";
import { useT } from "../i18n";
import { ResumeControl } from "./ResumeControl";
import type { Subagent } from "./subagentFold";
import { SubagentNavContext } from "./subagentGroupModel";

/// `view`: the id of the view shown (a subagent's, or a workflow agent's pane id), on the corner for
/// automation and galleries to read which view this is.
export function SubagentViewCorner({ view, agent, close }: { view?: string; agent?: Subagent; close: boolean }) {
  const t = useT();
  const open = useContext(SubagentNavContext);
  const actions = useContext(TurnActionsContext);
  return (
    <div className="cv-subagent-corner" data-subagent-view={view}>
      {agent && <ResumeControl agent={agent} actions={actions} />}
      {close && (
        <button
          type="button"
          className="cv-iconbtn cv-iconbtn--compact cv-subagent-corner__close"
          aria-label={t("subagents.close")}
          title={t("subagents.close")}
          onClick={() => open?.(undefined)}
        >
          <Icon name="action.close" size={12} />
        </button>
      )}
    </div>
  );
}

// What a subagent leaves in the transcript once it ends (runningTray.ts `withSubagentLines`): one
// quiet line where it ended, "Subagent finished: Explore the daemon · 1m 20s". It is drawn as a
// tool row, in their font, height and rhythm, as a background shell's end is
// (conversation/BackgroundTaskNote.tsx). A failure says so in the danger color; a subagent the
// person stopped, or acpmux lost, says that, and a stopped one says why when the pane knows
// ("stopped by you", "interrupted by Send now"; subagentFold.ts `stopReasonOf`), nothing when it
// does not. A click opens the subagent's view, its whole run. On hover, a subagent that did not
// finish offers Restart, which asks the chat to run it again with its prompt (restart.ts), in the
// hover row's buttons (conversation/MessageActions.tsx). The line keeps the transcript's one row
// grammar (design/chat-transcript.md "One row grammar"): the icon and the sentence, then the
// trailing column, its duration, then the chevron, so the duration and the chevron line up with
// the rows around it (Leo 2026-10-29: "this ui isn't consistent :(").
//
// While acpmux waits to retry it (retryState.ts), the line reads "Retrying (2/4) after a capacity
// error" with the turning ring. A failed one offers Retry, inline and in its ⋯ menu: acpmux runs
// it again, or, where acpmux cannot, the line asks the chat's agent to ("Ask parent to retry").
// A refusal leaves a short note after the line until the row next changes.
//
// A finished line whose subagent left a report (its final reply, `result`, else its last message)
// offers it under the line (Leo, 2026-11-03, on parallel agents in the running tray: "Tray only,
// richer"): a chevron right after the line's words opens the report, in the transcript's Markdown
// and capped as an opened tool output is. On such a line a click anywhere opens and closes the
// report, and only the agent's name, a link chip, opens the agent's view (Lucas, 2026-11-08). How
// it is offered is an experiment (doneReport.experiment.ts).
import { useContext, useId, useLayoutEffect, useRef, useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { AgentTag } from "../conversation/AgentTag";
import { TranscriptActivityRowShell } from "../conversation/TranscriptActivityRow";
import { spanDuration } from "../conversation/turns";
import { ChevronRight, Retry } from "../conversation/icons";
import { TurnActionsContext } from "../conversation/turnActions";
import { ReactionMark, ReactionReply } from "../conversation/ReactionMark";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { AgentIdentity } from "./AgentIdentity";
import { foreignHarness, SUBAGENT_FALLBACK } from "./agentIdentityModel";
import { useSenderIconLook } from "./senderIconLook";
import { agentTone } from "./agentTones";
import type { AcpmuxRow } from "../model";
import { canRestart, STOP_REASON_LABEL } from "./restart";
import { retryLabel, subagentRetry, type RetryAction, type RetryNote, type SessionRetryFields } from "./retryState";
import { elapsed, SubagentHarnessContext, SubagentNavContext, SubagentPaneContext } from "./subagentGroupModel";
import {
  subagentDisplayName,
  subagentTaskLabel,
  subsessionName,
  useSubsessionInfo,
  type SubsessionInfo,
} from "./subsessions";
import { failedLineLook } from "./failedLine.experiment";
import { Markdown } from "../conversation/Markdown";
import { AgentMessageRow } from "../conversation/AgentMessageRow";
import { messagePreview } from "../conversation/agentMessageRowModel";
import { doneReportLook } from "./doneReport.experiment";
import { RetryAffordanceContext, DoneReportLookContext, doneReport, shortReason } from "./subagentDoneLineModel";
import { useWholeReport, type WholeReport } from "./wholeReport";
import { WholeReportBody } from "./WholeReportBody";

const DONE_LABEL: Record<string, StringKey> = {
  completed: "subagents.ended.completed",
  failed: "subagents.ended.failed",
  cancelled: "subagents.ended.cancelled",
  disconnected: "subagents.ended.disconnected",
};

/// What acpmux names an Agent or Workflow call that gave no description (claude_stdio
/// `spawn_subagent`): never a better name than the one a run reports.
const PLACEHOLDER_TASKS = new Set(["Workflow", "Agent"]);

const ACTION_LABEL: Record<RetryAction, StringKey> = { daemon: "retry.action", ask: "retry.askParent" };

export function SubagentDoneLine({ row }: { row: AcpmuxRow }) {
  // Only a sub-session's line reads the session list (its retry is on its own session row): the
  // other lines never subscribe to it, so a session update wakes no line but its own.
  const child = row.subagents?.[0]?.child;
  return child ? <SubsessionDoneLine row={row} child={child} /> : <DoneLine row={row} />;
}

function SubsessionDoneLine({ row, child }: { row: AcpmuxRow; child: string }) {
  return <DoneLine row={row} child={useSubsessionInfo(child)} />;
}

/// `child`: a sub-session's own session row, where acpmux keeps its retry and its chat's title.
function DoneLine({
  row,
  child,
}: {
  row: AcpmuxRow;
  child?: SessionRetryFields & Partial<Pick<SubsessionInfo, "name" | "sessionId" | "title">>;
}) {
  const t = useT();
  const nav = useContext(SubagentNavContext);
  const pane = useContext(SubagentPaneContext);
  const affordance = useContext(RetryAffordanceContext);
  // The chat's harness: a subagent of another family draws its mark, one of the chat's own draws the
  // subagent mark in its tone, as the tray does (AgentIdentity.tsx `foreignHarness`).
  const chatHarness = useContext(SubagentHarnessContext);
  // The badge look picks which subagents show their family mark (foreignHarness): read here, so a
  // change of the setting draws them again.
  const senderBadge = useSenderIconLook().badge;
  const { restartSubagent, retryAgent, retryCapabilities } = useContext(TurnActionsContext);
  const agent = row.subagents?.[0];
  // A refusal's note lasts until the row changes. A Retry that went keeps the row's Retry disabled
  // until the row changes (acpmux's next word on it), so it can't go twice; acpmux refuses a second
  // one of its own as `retry.busy` meanwhile.
  const [note, setNote] = useState<{ version: number; key?: RetryNote; busy?: boolean }>();
  // How a failed line reads (failedLine.experiment.ts): the quiet grid by default.
  const [failedLook] = useState(() => experimentArm(failedLineLook));
  // How the line offers its report (doneReport.experiment.ts): a chevron that opens it by default.
  const [reportArm] = useState(() => experimentArm(doneReportLook));
  const reportLook = useContext(DoneReportLookContext) ?? reportArm;
  const [reportOpen, setReportOpen] = useState(false);
  const reportId = useId();
  const open = pane ?? nav;
  // The report whole while it shows (wholeReport.ts): `lastMessage` is only acpmux's preview.
  const shownReport = useWholeReport(
    agent?.state === "completed" ? agent : undefined,
    reportOpen || (reportLook === "preview" && agent?.state === "completed"),
  );
  if (!agent) return null;
  // The row's retry, as every surface reads it (retryState.ts ``subagentRetry``).
  const phase = subagentRetry(agent, retryCapabilities, child);
  const waiting = phase.kind === "retrying" ? phase.retry : undefined;
  const action = retryAgent && phase.kind === "failed" ? phase.action : undefined;
  // What it was asked to do (Claude's Agent `description`) first, as the running tray names it;
  // then its name, its prompt's first line, its kind; "Subagent" only when nothing names it. A
  // task that is only acpmux's placeholder ("Workflow", "Agent") keeps the name a run gave it. A
  // retrying line keeps its short name, so its "Retrying (2/4) …" is never cut behind a long task.
  // A sub-session's own chat names it (its title, else its name) before the bare "Subagent": its
  // fold record often names nothing once it ends (Leo, 2026-11-03, on a finished line that read
  // "Subagent").
  const childName =
    child?.sessionId !== undefined && child.name !== undefined
      ? subsessionName({ sessionId: child.sessionId, name: child.name, title: child.title })
      : child?.title?.trim() || undefined;
  const name =
    waiting || PLACEHOLDER_TASKS.has(agent.task ?? "")
      ? subagentDisplayName(t, agent, childName)
      : subagentTaskLabel(t, agent, childName);
  const label = t(DONE_LABEL[agent.state] ?? DONE_LABEL.completed!, { name });
  const reasonKey = agent.state === "cancelled" && agent.stopReason ? STOP_REASON_LABEL[agent.stopReason] : undefined;
  // Its own time once ended; none when its start and end were stamped at one moment.
  const time = spanDuration(t, elapsed(agent, agent.endedAt ?? row.at));
  // A sub-session's failure is on its own session row.
  const error = agent.state === "failed" ? (agent.error ?? child?.error) : undefined;
  // While acpmux retries it, or settles whether it will, Restart would run it a second time.
  const restart =
    restartSubagent && canRestart(agent) && phase.kind !== "retrying" && phase.kind !== "settling"
      ? restartSubagent
      : undefined;
  const head = waiting
    ? [name, retryLabel(t, waiting)]
    : [
        label,
        ...(reasonKey ? [t(reasonKey)] : []),
        ...(phase.kind === "failed" && phase.gaveUp ? [t("retry.retriedOut", { of: phase.gaveUp.of })] : []),
      ];
  // Why it failed, as acpmux recorded it, last: the line cuts it first.
  const parts = [...head, ...(error && !waiting ? [error] : [])];
  const [before, after = ""] = t(DONE_LABEL[agent.state] ?? DONE_LABEL.completed!, { name: "\u0000" }).split("\u0000");
  // The duration is the trailing column's, never part of the sentence; the tooltip and the
  // button's name still read the whole line with it.
  const whole = (waiting ? parts : [...head, ...(time ? [time] : []), ...(error ? [error] : [])]).join(" · ");
  const shown = note?.version === row.version ? note : undefined;
  // A failed line in the quiet looks (Leo, 2026-11-03: "this ui is pretty awkward looking"): its
  // title in plain text and its reason muted, red only on its mark; the grid arm also lines its
  // columns up from row to row: mark | title | short reason | Retry | time.
  const failed = agent.state === "failed" && !waiting;
  const report = waiting ? undefined : doneReport(agent);
  const disclose = report !== undefined && reportLook === "disclosure";
  const preview = report !== undefined && reportLook === "preview";
  const look = failed ? failedLook : undefined;
  const quiet = look === "grid" || look === "quiet";
  const reason =
    [
      ...(phase.kind === "failed" && phase.gaveUp ? [t("retry.retriedOut", { of: phase.gaveUp.of })] : []),
      ...(error ? [shortReason(error)] : []),
    ].join(" · ") || t("subagents.state.failed");
  const run = () => {
    if (!retryAgent || shown?.busy) return;
    setNote({ version: row.version, busy: true });
    void retryAgent(agent).then(
      (key) => setNote(key ? { version: row.version, key } : { version: row.version, busy: true }),
      () => setNote({ version: row.version, key: "retry.failed" }),
    );
  };
  const restartButton = restart && (
    <button
      type="button"
      className="cv-iconbtn cv-iconbtn--compact cv-subagent-restart"
      aria-label={t("subagents.restart")}
      title={t("subagents.restart")}
      data-tooltip-detail={t("subagents.restartDetail")}
      onClick={() => restart(agent)}
    >
      <Retry size={14} />
    </button>
  );
  // A finished line with its report is the one message row (conversation/AgentMessageRow.tsx), as a
  // send and a received message are: "Subagent finished: <name>", the subagent's mark, the report's
  // first line, and the same card that opens to the whole report as Markdown (Leo, 2026-11-07: "with
  // the sub-agent conclusions ... They should look basically the same as the other ones"). The name
  // opens the agent's view, as the line did; the line opens the report.
  if (disclose)
    return (
      <div className="cv-tools">
        <AgentMessageRow
          direction="report"
          className="cv-subagent-done-row cv-subagent-report-row"
          attributes={{ "data-state": agent.state }}
          lineClassName="cv-subagent-done"
          lineAttributes={{ "data-state": agent.state }}
          icon={
            <AgentIdentity
              harness={foreignHarness(agent.harness, chatHarness, senderBadge)}
              tone={agentTone(agent.id)}
              size={16}
              fallback={SUBAGENT_FALLBACK}
            />
          }
          sentence={`${before}\u0000${after}`}
          name={name}
          nameTitle={whole}
          {...(open && { onOpenName: () => open(agent.id), openNameLabel: t("subagents.open", { name }) })}
          preview={messagePreview(report ?? "")}
          label={t(reportOpen ? "subagents.report.hide" : "subagents.report.show")}
          open={reportOpen}
          onToggle={() => setReportOpen((value) => !value)}
          meta={agent.reaction ? <ReactionMark reaction={agent.reaction} /> : undefined}
          time={time}
          actions={restartButton ? <span className="cv-subagent-done__actions">{restartButton}</span> : undefined}
          body={
            <div className="cv-subagent-done__report">
              {shownReport && (
                <WholeReportBody
                  report={shownReport}
                  className="cv-subagent-done__markdown selectable"
                  onOpenView={open && (() => open(agent.id))}
                />
              )}
            </div>
          }
        />
        <ReactionReply reaction={agent.reaction} />
      </div>
    );
  const inline = action && affordance !== "menu" && (
    <button
      type="button"
      className={affordance === "link" ? "cv-subagent-retry-link" : "cv-subagent-retry"}
      disabled={shown?.busy}
      onClick={run}
    >
      {affordance === "button" && <Retry size={12} />}
      {t(ACTION_LABEL[action])}
    </button>
  );
  return (
    <div className="cv-tools">
      <TranscriptActivityRowShell
        className="cv-tool cv-subagent-done-row"
        attributes={{ "data-state": waiting ? "retrying" : agent.state, ...(look && { "data-look": look }) }}
      >
        <button
          type="button"
          className="cv-tool cv-bgtask cv-subagent-done cv-agent-activity__control"
          data-state={waiting ? "retrying" : agent.state}
          {...(agent.stopReason && { "data-reason": agent.stopReason })}
          aria-label={whole}
          disabled={!open}
          onClick={() => open?.(agent.id)}
        >
          <span className="cv-tool__icon">
            <AgentIdentity
              harness={foreignHarness(agent.harness, chatHarness, senderBadge)}
              tone={agentTone(agent.id)}
              size={16}
              fallback={SUBAGENT_FALLBACK}
            />
          </span>
          {quiet ? (
            // tooltip-allow: the line cuts its title and reason; its whole text, the failure included
            <span className="cv-tool__text cv-subagent-failed__text" title={whole}>
              <span className="cv-subagent-failed__title">{name}</span>
              {reason && <span className="cv-subagent-failed__reason">{reason}</span>}
            </span>
          ) : (
            /* tooltip-allow: the line is cut at the pane's width; its whole text, the failure included */
            <span className="cv-tool__text cv-agent-activity__sentence" title={whole}>
              {!waiting && before}
              <AgentTag name={name} />
              {!waiting && after}
              {/* Its own box, cut before the chip (subagents.css): the reason and failure go first. */}
              {parts.length > 1 && (
                <span className="cv-subagent-done__suffix">{` · ${parts.slice(1).join(" · ")}`}</span>
              )}
            </span>
          )}
        </button>
        {inline}
        {shown?.key && <output className="cv-subagent-done__note">{t(shown.key)}</output>}
        {(restart || action) && (
          <span className="cv-subagent-done__actions">
            {restartButton}
            {action && (
              <Menu>
                <MenuButton
                  className="cv-iconbtn cv-iconbtn--compact"
                  data-menu="subagent-done"
                  label={t("retry.menu")}
                  title={t("retry.menu")}
                  aria-haspopup="menu"
                >
                  <Icon name="action.more" size={14} />
                </MenuButton>
                <MenuPopup side="bottom" align="end" className="acpmux-quick-menu" label={t("retry.menu")}>
                  {/* The one Retry the row offers: acpmux's, or asking the chat's agent where acpmux can't. */}
                  <MenuItem className="acpmux-quick-item" onSelect={run}>
                    {t(ACTION_LABEL[action])}
                  </MenuItem>
                </MenuPopup>
              </Menu>
            )}
          </span>
        )}
        <span className="cv-tool__trail cv-subagent-done__trail cv-agent-activity__trail">
          <ReactionMark reaction={agent.reaction} />
          {!waiting && time && <span className="cv-command__meta cv-subagent-done__time">{time}</span>}
        </span>
        {disclose ? (
          // A line with a report: the chevron after its words is its own control, the report's
          // disclosure; the line's button still opens the view. It opens on the click, no fade.
          <button
            type="button"
            className="cv-tool__chevron cv-subagent-done__chevron cv-subagent-done__disclose"
            aria-expanded={reportOpen}
            aria-controls={reportOpen ? reportId : undefined}
            aria-label={t(reportOpen ? "subagents.report.hide" : "subagents.report.show")}
            title={t(reportOpen ? "subagents.report.hide" : "subagents.report.show")}
            onClick={() => setReportOpen((value) => !value)}
          >
            <ChevronRight size={14} className={`cv-rotor${reportOpen ? " is-open" : ""}`} />
          </button>
        ) : (
          /* The chevron only marks that the line opens; the line's button is the one control. Its
             column holds on a line that opens nothing, so the columns still line up. */
          <span
            className={`cv-tool__chevron cv-subagent-done__chevron cv-agent-activity__chevron${open ? "" : " is-idle"}`}
            aria-hidden
          >
            <ChevronRight size={14} />
          </span>
        )}
      </TranscriptActivityRowShell>
      {disclose && reportOpen && shownReport && (
        <div id={reportId} className="cv-subagent-done__report">
          <WholeReportBody
            report={shownReport}
            className="cv-subagent-done__markdown selectable"
            onOpenView={open && (() => open(agent.id))}
          />
        </div>
      )}
      {preview && shownReport && <ReportPreview report={shownReport} onOpenView={open && (() => open(agent.id))} />}
      {/* The chat's quiet reply to its end (ReactionMark.tsx), under the line as text Find reads,
          never only in a tooltip (cmux#33538). */}
      <ReactionReply reaction={agent.reaction} />
    </div>
  );
}

/// The preview arm: the report's first two lines always under the line, Show more opening the rest
/// (capped as an opened report is). Show more appears only when the cut hides lines.
function ReportPreview({ report, onOpenView }: { report: WholeReport; onOpenView?: () => void }) {
  const text = report.text;
  const t = useT();
  const [open, setOpen] = useState(false);
  const [long, setLong] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const id = useId();
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node || open) return;
    const measure = () => setLong(node.scrollHeight - node.clientHeight > 1);
    measure();
    if (typeof ResizeObserver !== "function") return;
    // Stops with the effect: the cleanup disconnects it when the text changes, it opens or unmounts.
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    return () => observer.disconnect();
  }, [text, open]);
  return (
    <div className="cv-subagent-done__report">
      <div
        ref={ref}
        id={id}
        className="cv-subagent-done__markdown selectable"
        data-cut={open ? undefined : true}
        data-more={long && !open ? true : undefined}
      >
        <Markdown commits="quiet">{text}</Markdown>
      </div>
      {(long || open || report.cut) && (
        <button
          type="button"
          className="cv-subagent-done__more"
          aria-expanded={open}
          aria-controls={id}
          onClick={() => {
            // Opening a preview that is only part of the report reads the rest too (wholeReport.ts).
            // Only the subagent's view holds the rest: Show more opens it.
            if (!open && report.cut && report.away && onOpenView) return onOpenView();
            if (!open && report.cut && !report.away) report.more();
            setOpen((value) => !value);
          }}
        >
          {t(open ? "message.less" : "message.more")}
        </button>
      )}
    </div>
  );
}

// An explicit acpmux child session (subagentFold.ts `reduceChild`) where its parent call started
// in the transcript, as a sub-session's card (AgentCard.tsx): its harness's mark, the
// first line of what it was asked, its state (the working spinner while it
// runs, never a dot) and time, under them its harness, model and effort and the machine it
// runs on, and once it ended, what it finally
// said, cut to three lines. Raw opens the command as the call ran it; Show output opens the run's
// own view (the command and all it printed). An acpmux session the session list has opens as its
// chat instead (Open chat).
// Its state, time and reply also show in the tray above the composer and the summary card's
// Subagents list, as every subagent's do.
import { useContext, useId, useState } from "react";
import { Cut } from "../conversation/SubsessionCallCard";
import { TranscriptDisclosureProvider } from "../conversation/transcriptDisclosure";
import { ChevronRight } from "../conversation/icons";
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { AgentCard } from "./AgentCard";
import { elapsed, running, STATE_LABEL, SubagentNavContext, SubagentPaneContext, useNow } from "./SubagentGroup";
import type { Subagent } from "./subagentFold";
import { SubsessionContext, useSenderChat, type SubsessionState } from "./subsessions";

/// A run's state as a card's: running is working, a failed one failed, any other end done, with
/// its own word when it was stopped or lost (`cancelled`, `disconnected`).
const cardState = (agent: Subagent): SubsessionState =>
  running(agent) ? "working" : agent.state === "failed" ? "failed" : "done";
const stopped = (state: string): state is "cancelled" | "disconnected" =>
  state === "cancelled" || state === "disconnected";

/** Keep agent-run result disclosures in the transcript's parent chat across virtualization. */
export function AgentRunTranscriptCard({ agent, sessionId }: { agent: Subagent; sessionId?: string }) {
  return (
    <TranscriptDisclosureProvider sessionId={sessionId}>
      <AgentRunCard agent={agent} />
    </TranscriptDisclosureProvider>
  );
}

export function AgentRunCard({ agent }: { agent: Subagent }) {
  const t = useT();
  const now = useNow(running(agent));
  const subsessions = useContext(SubsessionContext);
  const pane = useContext(SubagentPaneContext);
  const nav = useContext(SubagentNavContext);
  // The acpmux session it made: the sub-session acpmux recorded, or the one the session list has
  // by its name.
  const chat = useSenderChat(agent.session ?? "", agent.child).sessionId;
  const openChat = (agent.child ?? agent.session) && chat && subsessions ? () => subsessions.open(chat) : undefined;
  const openRun = pane ?? nav;
  return (
    <AgentCard
      name={agent.name}
      harness={agent.harness}
      identity={agent.id}
      sessionId={chat}
      // The model and the machine on the line under the name, which keeps the head's room for the
      // name at a narrow width.
      doing={[agent.kind, agent.host].filter(Boolean).join(" · ") || undefined}
      state={cardState(agent)}
      time={formatDuration(elapsed(agent, now))}
      stateLabel={stopped(agent.state) ? t(STATE_LABEL[agent.state]) : undefined}
      onOpen={openChat ?? (openRun ? () => openRun(agent.id) : undefined)}
      openLabel={openChat ? undefined : t("bgTask.showOutput")}
    >
      {agent.result && !running(agent) && <Cut text={agent.result} disclosureKey={`agent-result:${agent.id}`} />}
      {agent.command && <RunCommand command={agent.command} />}
    </AgentCard>
  );
}

/// The command as the call ran it, behind Raw.
function RunCommand({ command }: { command: string }) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const id = useId();
  return (
    <div className="cv-subsession__raw">
      <button
        type="button"
        className="cv-subsession__toggle"
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        onClick={() => setOpen((value) => !value)}
      >
        {t("subsession.raw")}
        <ChevronRight size={12} strokeWidth={1.4} className={`cv-rotor${open ? " is-open" : ""}`} />
      </button>
      {open && (
        <pre id={id} className="cv-agent-run__command selectable">
          {command}
        </pre>
      )}
    </div>
  );
}

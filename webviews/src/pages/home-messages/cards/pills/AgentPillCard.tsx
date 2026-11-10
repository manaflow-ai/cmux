// The small card a click on an agent's pill shows when the agent has no workspace to open yet (Swift
// HomeAgentPillCard; user 2026-11-08: a queued agent's pill must never do nothing): its title, where it
// stands ("Starts next", "1 ahead of it", "Working") and, for a queued agent, Start now. It opens under
// the pill in the ui/ Popover and closes on a press outside, Escape, or a start. Home never splits.
import { useState } from "react";
import { Popover } from "../../../../ui/Popover";
import type { Strings } from "../strings";
import "../cards.css";

export interface AgentPillCardProps {
  title: string;
  /** Where it stands, one line. */
  status: string;
  /** The pill: the card opens under it. */
  anchor: HTMLElement;
  strings: Strings;
  /** Start now; absent draws no button. Resolves true when the Chief started it. */
  onStart?: () => Promise<boolean>;
  onClose(): void;
}

export function AgentPillCard({ title, status, anchor, strings, onStart, onClose }: AgentPillCardProps) {
  const [starting, setStarting] = useState(false);
  const start = () => {
    if (!onStart || starting) return;
    setStarting(true);
    void onStart().then(
      (started) => (started ? onClose() : setStarting(false)),
      () => setStarting(false),
    );
  };
  return (
    <Popover open onOpenChange={(open) => !open && onClose()} anchor={anchor} label={title}>
      <div className="hm-pill-card">
        <span className="hm-pill-card__title">{title}</span>
        <span className="hm-pill-card__status">{status}</span>
        {onStart && (
          <button
            type="button"
            className="hm-pill-card__start"
            disabled={starting}
            /* tooltip-allow: the button's longer meaning, as the native card's tooltip */
            title={strings.t("home.agentPill.startNow.help")}
            onClick={start}
          >
            {strings.t(starting ? "home.agentPill.starting" : "home.agentPill.startNow")}
          </button>
        )}
      </div>
    </Popover>
  );
}

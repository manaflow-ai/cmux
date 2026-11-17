// The Chief's status line while its turn runs (MessagesLab HomeTurnProgress, HomeLiveLine): what it
// works on now and for how long, after the turn's finished steps folded into one part ("Ran 3
// commands · Checking on a31 · 2m 10s"). A click opens This Turn (HomeTurnStatusPopover): every step
// so far with its time, the running one "now", and the turn's total. The line is a row of the
// transcript only while a run streams its "working on" line (`run.activity`, chief-live-v1).
import { useRef, useState, useSyncExternalStore } from "react";
import type { LiveBook, LiveRun } from "../../home-channels/live";
import { useLiveInConversation } from "../../home-channels/live";
import type { RunBook } from "../../home-channels/runs";
import { useNow } from "../../home-channels/RunCard";
import type { Strings } from "../../shared/i18n";
import { Popover } from "../../../ui/Popover";
import { statusParts, turnDetails, TurnSteps, type TurnActivity } from "./turnSteps";

export interface ChiefActivity {
  run: string;
  author: string;
  activity: TurnActivity;
}

/** The newest running run's "working on" line in the conversation; none while nothing streams one. */
export function newestActivity(lives: readonly LiveRun[], running: readonly { id: string; author: string }[]) {
  for (const live of [...lives].reverse()) {
    if (!live.activity) continue;
    if (running.some((run) => run.id === live.run && run.author === live.author))
      return { run: live.run, author: live.author, activity: live.activity } satisfies ChiefActivity;
  }
  return undefined;
}

/** The conversation's Chief activity, followed as live frames and runs change, with the page's own
 * record of the turn's steps (kept here, by the open conversation, so a row scrolled out of the
 * window and back keeps them; a new run starts it again). */
export function useChiefActivity(
  live: LiveBook,
  runs: RunBook,
  conversation: string,
): { activity: ChiefActivity; steps: TurnSteps } | undefined {
  const lives = useLiveInConversation(live, conversation);
  useSyncExternalStore(runs.subscribe, runs.getVersion);
  const record = useRef<{ run: string; steps: TurnSteps }>({ run: "", steps: new TurnSteps() });
  const activity = newestActivity(lives, runs.running(conversation));
  if (!activity) return undefined;
  const key = `${conversation}\0${activity.author}\0${activity.run}`;
  if (record.current.run !== key) record.current = { run: key, steps: new TurnSteps() };
  // Idempotent: the same line and start leave the steps as they are.
  record.current.steps.record(activity.activity);
  return { activity, steps: record.current.steps };
}

export function ChiefStatusLine({
  activity,
  steps,
  strings,
}: {
  activity: ChiefActivity;
  steps: TurnSteps;
  strings: Strings;
}) {
  // The clock ticks only while the line shows (useNow stops with it).
  const now = useNow(true);
  const [anchor, setAnchor] = useState<HTMLElement | null>(null);
  const [open, setOpen] = useState(false);
  const parts = statusParts(steps, activity.activity, now, strings);
  const details = open ? turnDetails(steps, now, strings) : undefined;
  return (
    <div className="mt-chief-status">
      <button
        ref={setAnchor}
        type="button"
        className="mt-chief-status-line"
        title={strings.t("home.turn.show")}
        aria-label={`${strings.t("home.turn.show")}: ${parts.join(" · ")}`}
        aria-expanded={open}
        onClick={() => setOpen((shown) => !shown)}
      >
        {parts.map((part, index) => (
          <span key={index} className="mt-chief-status-part">
            {part}
          </span>
        ))}
      </button>
      {details && (
        <Popover open onOpenChange={setOpen} anchor={anchor} label={strings.t("home.turn.title")} side="top">
          <div className="mt-turn-details">
            <div className="mt-turn-title">
              <strong>{strings.t("home.turn.title")}</strong>
              <span>{details.total}</span>
            </div>
            {details.rows.slice(-30).map((row, index) => (
              <div key={index} className={`mt-turn-row${row.running ? " running" : ""}`}>
                <span className="mt-turn-line">{row.line}</span>
                <span className="mt-turn-time">{row.duration}</span>
              </div>
            ))}
          </div>
        </Popover>
      )}
    </div>
  );
}

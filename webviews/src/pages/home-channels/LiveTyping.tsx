// The typing row under the open conversation: who types, or, while a Chief's run streams
// (`chief-live-v1`), the end of its reply as it writes and under it what it works on now
// ("Editing src/app.ts · 12s", the time counted here). A tap opens the run sheet. A reply that
// already shows as a draft row in the timeline is not repeated here.
import { useSyncExternalStore } from "react";
import { formatDuration } from "../../agent-session/acpmux/conversation/turns";
import type { Strings } from "../shared/i18n";
import { liveReply, tail, useLiveInConversation, type LiveBook, type LiveRun } from "./live";
import type { RunBook } from "./runs";
import { useNow } from "./RunCard";
import type { HomeParticipant, HomeRun } from "./types";

/** How much of a streaming reply the row shows: its end, one line. */
const ROW_LIVE_CHARS = 160;

export interface LiveTypingProps {
  conversation: string;
  live: LiveBook;
  runs: RunBook;
  people: ReadonlyMap<string, HomeParticipant>;
  /** Who types (names), when no run streams. */
  typing: readonly string[];
  /** The turn of the draft row the timeline shows (its text is not repeated). */
  draftTurn?: string;
  strings: Strings;
  onOpen(run: HomeRun): void;
}

/** The newest live run of the conversation whose run the page knows to be running. */
function streaming(lives: readonly LiveRun[], runs: RunBook, conversation: string) {
  const running = runs.running(conversation);
  for (const live of [...lives].reverse()) {
    const run = running.find((candidate) => candidate.id === live.run && candidate.author === live.author);
    if (run) return { live, run };
  }
  return undefined;
}

export function LiveTyping({ conversation, live, runs, people, typing, draftTurn, strings, onOpen }: LiveTypingProps) {
  const { t, format } = strings;
  const lives = useLiveInConversation(live, conversation);
  // Re-reads when the run book changes too (a run that starts or ends).
  useSyncExternalStore(runs.subscribe, runs.getVersion);
  const current = streaming(lives, runs, conversation);
  const activity = current?.live.activity;
  const now = useNow(activity !== undefined);
  const reply = current && current.run.turn !== draftTurn ? liveReply(current.live) : "";
  if (current && (reply || activity)) {
    const name = people.get(current.run.author)?.name ?? current.run.author;
    return (
      <div className="lg-typing live" aria-live="polite">
        <button type="button" className="lg-live" onClick={() => onOpen(current.run)} title={t("run.open")}>
          {reply ? (
            <span className="lg-live-text" dir="auto">
              <strong>{name}</strong> {tail(reply, ROW_LIVE_CHARS)}
            </span>
          ) : (
            <span className="lg-live-text">
              <strong>{name}</strong>
            </span>
          )}
          {activity && (
            <span className="lg-live-activity">
              {activity.line} · {formatDuration(Math.max(0, now - activity.since))}
            </span>
          )}
        </button>
      </div>
    );
  }
  return (
    <div className="lg-typing" aria-live="polite">
      {typing.length === 1 ? format("typing.one", typing[0]!) : typing.length > 1 ? t("typing.many") : ""}
    </div>
  );
}

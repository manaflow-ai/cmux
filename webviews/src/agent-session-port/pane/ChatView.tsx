// The transcript of the selected session: acpmux rows as Codex turns (viewModel), drawn by
// the ported conversation renderer in its real scroll container, with the composer docked
// at the bottom and a pending permission card above it.
import { useMemo, type ReactNode } from "react";
import { Transcript, FLUID_COLUMN, FLUID_COMPOSER } from "../conversation";
import type { Message } from "../conversation/model";
import type { AcpmuxSnapshot } from "../data/acpmux";
import { elapsedMs, turnsFromRows, type PortTurn } from "../viewModel/acpmuxTurns";
import { useTicking } from "./useTicking";
import { ChatActionsContext } from "../conversation/actions";

export type ChatViewProps = {
  snapshot: AcpmuxSnapshot;
  composer: ReactNode;
  /** Right space reserved for the Changes panel when it floats over the transcript. */
  onViewChanges?: (turn: PortTurn) => void;
};

/** Settles turns the rows leave open: only the last turn can still run, and only while acpmux says the session works. */
export function settledTurns(turns: PortTurn[], working: boolean): PortTurn[] {
  return turns.map((turn, index) =>
    turn.status === "inProgress" && (index < turns.length - 1 || !working) ? { ...turn, status: "completed" } : turn,
  );
}

export function ChatView({ snapshot, composer, onViewChanges }: ChatViewProps) {
  const cwd = snapshot.summary?.cwd;
  const turns = useMemo(
    () => settledTurns(turnsFromRows(snapshot.rows, cwd), snapshot.isWorking),
    [snapshot.rows, snapshot.isWorking, cwd],
  );
  const last = turns.at(-1);
  const running = last?.status === "inProgress";
  const now = useTicking(running);
  const messages: Message[] = turns.map((turn, index) => ({
    role: "turn",
    turn,
    derive: { cwd, elapsedMs: index === turns.length - 1 ? elapsedMs(turn, now) : undefined },
    actions: turn.status === "inProgress" ? undefined : index === turns.length - 1 ? "fork" : "hidden",
  }));
  const actions = useMemo(
    () => ({
      viewChanges: (turnId: string) => {
        const turn = turns.find((candidate) => candidate.id === turnId);
        if (turn) onViewChanges?.(turn);
      },
    }),
    [turns, onViewChanges],
  );
  return (
    <ChatActionsContext value={actions}>
      <Transcript
        conversation={{ messages, scroll: "bottom", clock: { now } }}
        columnWidth={FLUID_COLUMN}
        composerWidth={FLUID_COMPOSER}
        composer={composer}
        composerHeight={98}
      />
    </ChatActionsContext>
  );
}

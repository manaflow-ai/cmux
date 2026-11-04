import { useEffect, useState } from "react";
import { useT } from "../i18n";
import { newerRace, type RaceClient, type RaceRecord } from "./model";

export function RaceCompareView({
  parent,
  raceId,
  client,
  initialRace,
  onOpenSession,
}: {
  parent: string;
  raceId: string;
  client: RaceClient;
  initialRace?: RaceRecord;
  onOpenSession?: (sessionId: string) => void;
}) {
  const t = useT();
  const [race, setRace] = useState(initialRace);
  const [error, setError] = useState<string>();
  const [cancelling, setCancelling] = useState(false);
  useEffect(() => {
    let active = true;
    setRace(initialRace?.id === raceId && initialRace.parent === parent ? initialRace : undefined);
    setError(undefined);
    const receive = (next: RaceRecord, fromFetch = false) => {
      if (!active || next.id !== raceId || next.parent !== parent) return;
      setRace((previous) => newerRace(previous, next, fromFetch));
      setError(undefined);
    };
    const unsubscribe = client.watchRaces(receive);
    void client.getRace(parent, raceId).then(
      (next) => receive(next, true),
      (reason: unknown) => {
        if (active) setError(String(reason));
      },
    );
    return () => {
      active = false;
      unsubscribe();
    };
  }, [client, parent, raceId, initialRace]);
  const current = race?.id === raceId && race.parent === parent ? race : undefined;
  return (
    <>
      {error && <p role="alert">{error}</p>}
      {current && (
        <>
          <div className="race-heading">
            <p role="status">{t(`race.${current.state}`)}</p>
            {(current.state === "running" || current.state === "reviewing" || current.state === "failed") && (
              <button
                type="button"
                disabled={cancelling}
                onClick={() => {
                  setCancelling(true);
                  void client
                    .cancelRace(parent, raceId)
                    .then(
                      (next) => setRace((previous) => newerRace(previous, next)),
                      (reason: unknown) => setError(String(reason)),
                    )
                    .finally(() => setCancelling(false));
                }}
              >
                {t("race.cancel")}
              </button>
            )}
          </div>
          <p className="race-prompt">{current.prompt}</p>
          {current.reason && <p className="race-decision">{current.reason}</p>}
          <div className="race-comparison">
            {current.candidates.map((candidate) => (
              <section key={candidate.id} className="race-candidate" data-winner={candidate.id === current.winnerId}>
                <h3>
                  {candidate.target.harness} · {candidate.target.model}
                </h3>
                <p>{candidate.id === current.winnerId ? t("race.winner") : t(`race.${candidate.state}`)}</p>
                {current.state === "completed" &&
                  candidate.id === current.winnerId &&
                  candidate.sessionId &&
                  onOpenSession && (
                    <button type="button" onClick={() => onOpenSession(candidate.sessionId!)}>
                      {t("subsession.openChat")}
                    </button>
                  )}
                {candidate.error && <p role="alert">{candidate.error}</p>}
                <pre>{candidate.reply ?? t("race.noReply")}</pre>
                {candidate.cwd && candidate.state !== "discarded" && (
                  <p className="race-worktree">
                    {t("race.worktree")}: <code>{candidate.cwd}</code>
                  </p>
                )}
              </section>
            ))}
          </div>
        </>
      )}
    </>
  );
}

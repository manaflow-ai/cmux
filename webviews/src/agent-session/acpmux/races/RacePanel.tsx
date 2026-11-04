import { useEffect, useMemo, useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxSnapshot } from "../model";
import { newerRace, raceChoices, type RaceClient, type RaceRecord } from "./model";
import { RaceCompareView } from "./RaceCompareView";
import "./styles.css";

export function RacePanel({
  parent,
  catalog,
  client,
  onClose,
  onOpenSession,
}: {
  parent: string;
  catalog: AcpmuxSnapshot["catalog"];
  client: RaceClient;
  onClose(): void;
  onOpenSession?: (sessionId: string) => void;
}) {
  const t = useT();
  const choices = useMemo(() => raceChoices(catalog), [catalog]);
  const [selected, setSelected] = useState<string[]>([]);
  const [reviewer, setReviewer] = useState("");
  const [prompt, setPrompt] = useState("");
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState<string>();
  const [races, setRaces] = useState<RaceRecord[]>([]);
  const [opened, setOpened] = useState<RaceRecord>();
  useEffect(() => {
    let active = true;
    const merge = (incoming: RaceRecord[], fromFetch = false) => {
      if (!active) return;
      setRaces((previous) => {
        const byId = new Map(previous.map((race) => [race.id, race]));
        for (const next of incoming)
          if (next.parent === parent) byId.set(next.id, newerRace(byId.get(next.id), next, fromFetch));
        return [...byId.values()].sort((a, b) => b.createdAt - a.createdAt);
      });
    };
    const unsubscribe = client.watchRaces((race) => merge([race]));
    void client.listRaces(parent).then(
      (next) => merge(next, true),
      (reason: unknown) => {
        if (active) setError(String(reason));
      },
    );
    return () => {
      active = false;
      unsubscribe();
    };
  }, [client, parent]);
  const candidates = choices.filter((choice) => selected.includes(choice.key));
  const reviewerChoice = choices.find((choice) => choice.key === reviewer);
  return (
    <section className="race-panel" aria-label={t("race.title")}>
      <header className="race-heading">
        <h2>{t("race.title")}</h2>
        <button type="button" onClick={onClose}>
          {t("race.back")}
        </button>
      </header>
      {opened ? (
        <>
          <button type="button" onClick={() => setOpened(undefined)}>
            {t("race.new")}
          </button>
          <RaceCompareView
            key={opened.id}
            parent={parent}
            raceId={opened.id}
            initialRace={opened}
            client={client}
            onOpenSession={onOpenSession}
          />
        </>
      ) : (
        <>
          {error && <p role="alert">{error}</p>}
          <form
            onSubmit={(event) => {
              event.preventDefault();
              if (!reviewerChoice || candidates.length < 2 || !prompt.trim() || starting) return;
              setStarting(true);
              setError(undefined);
              void client
                .startRace({
                  parent,
                  prompt,
                  candidates: candidates.map((choice) => choice.target),
                  reviewer: reviewerChoice.target,
                })
                .then(setOpened, (reason: unknown) => setError(String(reason)))
                .finally(() => setStarting(false));
            }}
          >
            <label className="race-field">
              {t("race.task")}
              <textarea value={prompt} onChange={(event) => setPrompt(event.target.value)} required rows={4} />
            </label>
            <fieldset disabled={starting}>
              <legend>{t("race.models")}</legend>
              <div className="race-models">
                {choices.map((choice) => (
                  <label key={choice.key}>
                    <input
                      type="checkbox"
                      checked={selected.includes(choice.key)}
                      onChange={(event) =>
                        setSelected((previous) =>
                          event.target.checked
                            ? [...previous, choice.key]
                            : previous.filter((key) => key !== choice.key),
                        )
                      }
                    />
                    {choice.label}
                  </label>
                ))}
              </div>
            </fieldset>
            <label className="race-field">
              {t("race.reviewer")}
              <select
                value={reviewer}
                onChange={(event) => setReviewer(event.target.value)}
                required
                disabled={starting}
              >
                <option value="" />
                {choices.map((choice) => (
                  <option key={choice.key} value={choice.key}>
                    {choice.label}
                  </option>
                ))}
              </select>
            </label>
            <p
              aria-hidden={candidates.length >= 2 && !!reviewerChoice}
              style={{ visibility: candidates.length >= 2 && reviewerChoice ? "hidden" : undefined }}
            >
              {t("race.empty")}
            </p>
            <button type="submit" disabled={starting || candidates.length < 2 || !reviewerChoice || !prompt.trim()}>
              {t(starting ? "race.starting" : "race.start")}
            </button>
          </form>
          {races.length > 0 && (
            <nav aria-label={t("race.recent")}>
              <h3>{t("race.recent")}</h3>
              {races.map((race) => (
                <button className="race-recent" type="button" key={race.id} onClick={() => setOpened(race)}>
                  {race.prompt} · {t(`race.${race.state}`)}
                </button>
              ))}
            </nav>
          )}
        </>
      )}
    </section>
  );
}

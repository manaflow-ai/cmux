// Fleet: the CI machines from the fleet dashboard (its data.json, read by the app): load per
// core, CPU, free memory, busy runners and how many of the person's agents run on each, with the
// runner and queue totals on top. Without a dashboard named, or when it does not answer, the view
// says so and offers a field to name one.
import { useMemo, useState, type FormEvent } from "react";
import { agentsOnHost, fleetTotals, loadPerCore } from "../model";
import { agentsOf, Loaded } from "../parts";
import type { ChiefViewProps } from "../registry";
import type { FleetMachine } from "../types";

const percent = (value: number | null | undefined, language: string) =>
  value == null
    ? "–"
    : new Intl.NumberFormat(language, { style: "percent", maximumFractionDigits: 0 }).format(value / 100);

export function FleetView({ data, strings, placement, onSetFleetURL }: ChiefViewProps) {
  const agents = agentsOf(data);
  const fleet = data.fleet;
  const reply = "reply" in fleet ? fleet.reply : undefined;
  const totals = useMemo(() => fleetTotals(reply?.machines ?? []), [reply]);
  const machines = useMemo(
    () =>
      [...(reply?.machines ?? [])].sort(
        (a, b) => (loadPerCore(b) ?? -1) - (loadPerCore(a) ?? -1) || a.host.localeCompare(b.host),
      ),
    [reply],
  );
  // Beside another view the table drops CPU and memory, which the load meter already sums up.
  const compact = placement !== "pane";
  const number = new Intl.NumberFormat(strings.language);
  return (
    <div className="cv-fleet">
      <Loaded
        status={fleet.status === "loading" && reply ? "ready" : fleet.status}
        strings={strings}
        unavailable={
          <FleetSetup
            strings={strings}
            configured={fleet.status === "unavailable" && fleet.configured !== false}
            onSave={onSetFleetURL}
          />
        }
      >
        <ul className="cv-tiles">
          <Tile
            label={strings.t("chiefViews.fleet.runners")}
            value={`${number.format(totals.busy)} / ${number.format(totals.online)}`}
          />
          <Tile label={strings.t("chiefViews.fleet.queue")} value={number.format(reply?.queued ?? 0)} />
          <Tile label={strings.t("chiefViews.fleet.agents")} value={number.format(agents.length)} />
          <Tile
            label={strings.t("chiefViews.fleet.unreachable")}
            value={number.format(totals.unreachable)}
            warn={totals.unreachable > 0}
          />
        </ul>
        {reply?.updated && (
          <p className="cv-caption">
            {strings.format("chiefViews.fleet.updated", new Date(reply.updated).toLocaleTimeString(strings.language))}
          </p>
        )}
        <table className="cv-table" data-compact={compact ? "" : undefined}>
          <thead>
            <tr>
              <th scope="col">{strings.t("chiefViews.fleet.col.machine")}</th>
              <th scope="col">{strings.t("chiefViews.fleet.col.load")}</th>
              {!compact && <th scope="col">{strings.t("chiefViews.fleet.col.cpu")}</th>}
              {!compact && <th scope="col">{strings.t("chiefViews.fleet.col.memory")}</th>}
              <th scope="col">{strings.t("chiefViews.fleet.col.runners")}</th>
              <th scope="col">{strings.t("chiefViews.fleet.col.agents")}</th>
            </tr>
          </thead>
          <tbody>
            {machines.map((machine) => (
              <MachineRow
                key={machine.host}
                machine={machine}
                agents={agentsOnHost(agents, machine.host)}
                compact={compact}
                language={strings.language}
              />
            ))}
          </tbody>
        </table>
      </Loaded>
    </div>
  );
}

function Tile({ label, value, warn }: { label: string; value: string; warn?: boolean }) {
  return (
    <li className="cv-tile" data-warn={warn ? "" : undefined}>
      <span className="cv-tile-value">{value}</span>
      <span className="cv-tile-label">{label}</span>
    </li>
  );
}

function MachineRow({
  machine,
  agents,
  compact,
  language,
}: {
  machine: FleetMachine;
  agents: number;
  compact: boolean;
  language: string;
}) {
  const load = loadPerCore(machine);
  return (
    <tr data-error={machine.error ? "" : undefined} data-hot={load !== undefined && load > 1 ? "" : undefined}>
      <th scope="row" className="cv-host" title={machine.error ?? undefined}>
        {machine.host.split(".")[0]}
      </th>
      {machine.error ? (
        // An unreachable machine's numbers are stale zeros: its error says more.
        <td className="cv-host-error" colSpan={compact ? 3 : 5}>
          {machine.error}
        </td>
      ) : (
        <MachineCells machine={machine} agents={agents} compact={compact} language={language} />
      )}
    </tr>
  );
}

function MachineCells({
  machine,
  agents,
  compact,
  language,
}: {
  machine: FleetMachine;
  agents: number;
  compact: boolean;
  language: string;
}) {
  const load = loadPerCore(machine);
  const number = new Intl.NumberFormat(language, { maximumFractionDigits: 1 });
  return (
    <>
      <td>
        <span className="cv-meter" aria-hidden="true">
          <span className="cv-meter-fill" style={{ inlineSize: `${Math.min(100, Math.round((load ?? 0) * 100))}%` }} />
        </span>
        <span className="cv-num">{load === undefined ? "–" : number.format(load)}</span>
      </td>
      {!compact && <td className="cv-num">{percent(machine.cpuPct, language)}</td>}
      {!compact && <td className="cv-num">{percent(machine.memFreePct, language)}</td>}
      <td className="cv-num">
        {machine.runnersBusy}/{machine.runnersOnline}
      </td>
      <td className="cv-num">{agents || "–"}</td>
    </>
  );
}

function FleetSetup({
  strings,
  configured,
  onSave,
}: {
  strings: ChiefViewProps["strings"];
  configured: boolean;
  onSave: (url: string) => Promise<boolean>;
}) {
  const [url, setURL] = useState("");
  const [busy, setBusy] = useState(false);
  const [refused, setRefused] = useState(false);
  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!url.trim() || busy) return;
    setBusy(true);
    setRefused(!(await onSave(url)));
    setBusy(false);
  };
  return (
    <form className="cv-setup" onSubmit={submit}>
      <p className="cv-setup-title">{strings.t("chiefViews.fleet.unavailable.title")}</p>
      <p className="cv-note">
        {strings.t(configured ? "chiefViews.fleet.unreachable.body" : "chiefViews.fleet.unavailable.body")}
      </p>
      <div className="cv-setup-row">
        <input
          className="cv-filter"
          type="url"
          inputMode="url"
          value={url}
          placeholder="https://"
          aria-label={strings.t("chiefViews.fleet.url.label")}
          aria-invalid={refused || undefined}
          onChange={(event) => {
            setURL(event.currentTarget.value);
            setRefused(false);
          }}
        />
        <button type="submit" className="cv-button" disabled={!url.trim() || busy}>
          {strings.t("chiefViews.fleet.url.save")}
        </button>
      </div>
      {refused && (
        <p className="cv-note cv-host-error" role="alert">
          {strings.t("chiefViews.fleet.url.invalid")}
        </p>
      )}
    </form>
  );
}

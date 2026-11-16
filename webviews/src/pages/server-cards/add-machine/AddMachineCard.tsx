// The Add Machine card (`#/add-machine`; palette "Add Machine…", Settings > Machines, the Machines
// section, Add Device's Any Computer way) and Check Machine: the host field with the tailnet's
// machines under it, then the steps filling in live, then ready or failed. One layout per phase;
// every button shows and binds its key, and the click and the key run the same `perform`.
// design/server-cards.md "Add Machine" has the states, sizes and the pick among the variants.
import { useEffect, useRef, useSyncExternalStore } from "react";
import type { Strings } from "../../shared/i18n";
import { DialogButton } from "../../../ui/DialogButton";
import { StatusGlyph } from "../../../ui/StatusGlyph";
import type { StatusGlyphName } from "../../../ui/statusGlyphs.generated";
import type { ChecklistRow } from "./checklist";
import { badgeKey, buttonKey, stepKey, statusKey, type AddMachineButton } from "./model";
import { viewOf, type AddMachineSnapshot, type AddMachineStore, type AddMachineView } from "./store";
import type { HostCandidate } from "./types";

/** How a run's steps show (design/server-cards.md):
 * - `progress`: one line while it goes well, the whole list once a step needs the person;
 * - `list`: every step with its glyph from the start;
 * - `rail`: one glyph per step in a row, the step running named under it. */
export type ChecklistVariant = "progress" | "list" | "rail";
export const CHECKLIST_PICK: ChecklistVariant = "progress";

export function AddMachineCard({
  store,
  strings,
  variant = CHECKLIST_PICK,
}: {
  store: AddMachineStore;
  strings: Strings;
  variant?: ChecklistVariant;
}) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const view = viewOf(snapshot);
  return (
    <div className="am-card" data-card="add-machine" data-phase={view.phase}>
      <Header view={view} strings={strings} />
      {view.phase === "pick" ? (
        <>
          <Fields store={store} snapshot={snapshot} view={view} strings={strings} />
          <CandidateList store={store} snapshot={snapshot} strings={strings} />
        </>
      ) : (
        <Steps store={store} snapshot={snapshot} view={view} strings={strings} variant={variant} />
      )}
      <Footer store={store} view={view} strings={strings} />
    </div>
  );
}

function Header({ view, strings }: { view: AddMachineView; strings: Strings }) {
  const adding = view.mode.kind === "add";
  switch (view.phase) {
    case "pick":
      return (
        <header className="am-header">
          <h1 className="am-title">{strings.t("addMachine.title")}</h1>
          <p className="am-subtitle">{strings.t("addMachine.subtitle")}</p>
        </header>
      );
    case "running":
      return (
        <header className="am-header">
          <h1 className="am-title">
            {strings.format(adding ? "addMachine.addingTitle" : "addMachine.checkingTitle", view.runName)}
          </h1>
        </header>
      );
    case "ready":
      return (
        <header className="am-header am-header-status">
          <StatusGlyph name="done" size={20} />
          <div>
            <h1 className="am-title">{strings.format("addMachine.ready", view.runName)}</h1>
            {adding ? <p className="am-subtitle">{strings.t("addMachine.readyDetail")}</p> : null}
          </div>
        </header>
      );
    case "failed":
      return (
        <header className="am-header am-header-status">
          <StatusGlyph name="error" size={20} />
          <h1 className="am-title">
            {strings.format(adding ? "addMachine.addFailed" : "addMachine.checkFailed", view.runName)}
          </h1>
        </header>
      );
  }
}

function Fields({
  store,
  snapshot,
  view,
  strings,
}: {
  store: AddMachineStore;
  snapshot: AddMachineSnapshot;
  view: AddMachineView;
  strings: Strings;
}) {
  const host = useRef<HTMLInputElement>(null);
  useEffect(() => host.current?.focus(), []);
  const placeholder = strings.t("addMachine.hostPlaceholder");
  return (
    <div className="am-fields">
      <input
        ref={host}
        className="am-host"
        value={snapshot.destination}
        placeholder={placeholder}
        aria-label={placeholder}
        spellCheck={false}
        autoCapitalize="off"
        autoCorrect="off"
        onChange={(event) => store.setDestination(event.currentTarget.value)}
      />
      <label className="am-name">
        <span className="am-caption">{strings.t("addMachine.name")}</span>
        <input
          value={snapshot.name}
          placeholder={view.defaultName}
          aria-label={strings.t("addMachine.name")}
          spellCheck={false}
          onChange={(event) => store.setName(event.currentTarget.value)}
        />
      </label>
    </div>
  );
}

/** The tailnet's machines under the field: a working glyph while the list loads, then one row per peer.
 * Peers already added, offline or with ssh off are greyed and say why. Without Tailscale the list
 * is not shown at all. */
function CandidateList({
  store,
  snapshot,
  strings,
}: {
  store: AddMachineStore;
  snapshot: AddMachineSnapshot;
  strings: Strings;
}) {
  const candidates = snapshot.candidates;
  if (candidates.kind === "loading") {
    return (
      <div className="am-looking">
        <StatusGlyph name="working" size={12} />
        <span className="am-caption am-tertiary">{strings.t("addMachine.lookingForPeers")}</span>
      </div>
    );
  }
  if (candidates.kind === "unavailable" || candidates.list.length === 0) return null;
  return (
    <div className="am-candidates">
      <span className="am-caption">{strings.t("addMachine.tailnet")}</span>
      <ul className="am-candidate-list" aria-label={strings.t("addMachine.tailnet")}>
        {candidates.list.map((candidate) => (
          <CandidateRow
            key={candidate.id}
            candidate={candidate}
            picked={snapshot.destination === candidate.destination}
            strings={strings}
            pick={() => store.pick(candidate)}
          />
        ))}
      </ul>
    </div>
  );
}

function CandidateRow({
  candidate,
  picked,
  strings,
  pick,
}: {
  candidate: HostCandidate;
  picked: boolean;
  strings: Strings;
  pick: () => void;
}) {
  const badge = badgeKey(candidate);
  return (
    <li>
      <button
        type="button"
        aria-pressed={picked}
        className="am-candidate"
        data-picked={picked || undefined}
        disabled={!candidate.pickable}
        onClick={pick}
      >
        <span className="am-candidate-text">
          <span className="am-candidate-name">{candidate.name}</span>
          {candidate.os ? <span className="am-caption am-tertiary">{candidate.os}</span> : null}
        </span>
        {badge ? <span className="am-caption am-tertiary">{strings.t(badge)}</span> : null}
      </button>
    </li>
  );
}

/** The steps of a run. In the picked layout a run going well is one progress line with Show
 * Details; a step that failed or warned opens the whole list, the failed one with its whole detail
 * and fix. */
function Steps({
  store,
  snapshot,
  view,
  strings,
  variant,
}: {
  store: AddMachineStore;
  snapshot: AddMachineSnapshot;
  view: AddMachineView;
  strings: Strings;
  variant: ChecklistVariant;
}) {
  const checklist = view.checklist;
  const failing = checklist.failing?.step;
  const needsPerson = checklist.needsPerson;
  const open = variant === "list" || snapshot.showDetails || needsPerson;
  const rows = (
    <ul className="am-steps">
      {checklist.rows.map((row) => (
        <StepRow key={row.step} row={row} open={row.step === failing} installing={view.installing} strings={strings} />
      ))}
    </ul>
  );
  return (
    <div className="am-checklist" data-variant={variant}>
      {variant === "progress" && !needsPerson ? (
        <Progress view={view} open={open} strings={strings} toggle={() => store.toggleDetails()} />
      ) : null}
      {variant === "rail" ? <Rail view={view} strings={strings} /> : null}
      {open || (variant === "rail" && needsPerson) ? rows : null}
    </div>
  );
}

function progressText(view: AddMachineView, strings: Strings): string {
  const summary = view.checklist.summary;
  if (!summary.current) return summary.done === summary.total ? strings.t("addMachine.progress.done") : "";
  return strings.format(
    "addMachine.progress.step",
    String(summary.done + 1),
    String(summary.total),
    stepName(summary.current, strings),
  );
}

function Progress({
  view,
  open,
  strings,
  toggle,
}: {
  view: AddMachineView;
  open: boolean;
  strings: Strings;
  toggle: () => void;
}) {
  const summary = view.checklist.summary;
  return (
    <div className="am-progress-line">
      <StatusGlyph name={summary.current ? "working" : "done"} size={12} />
      <span className="am-progress-text">{progressText(view, strings)}</span>
      <button type="button" className="am-link" onClick={toggle} aria-expanded={open}>
        {strings.t(open ? "addMachine.hideDetails" : "addMachine.showDetails")}
      </button>
    </div>
  );
}

function Rail({ view, strings }: { view: AddMachineView; strings: Strings }) {
  return (
    <div className="am-rail">
      <ol className="am-rail-dots">
        {view.checklist.rows.map((row) => (
          <li key={row.step} title={stepName(row.step, strings)}>
            <StatusGlyph name={glyphOf(row)} size={12} />
          </li>
        ))}
      </ol>
      <span className="am-progress-text">{progressText(view, strings)}</span>
    </div>
  );
}

/** A step's still glyph: told apart by shape (idle, working, done, waiting, error). */
function glyphOf(row: ChecklistRow): StatusGlyphName {
  if (row.status.kind === "pending") return "idle";
  if (row.status.kind === "running") return "working";
  switch (row.status.state) {
    case "ok":
    case "fixed":
      return "done";
    case "warn":
      return "waiting";
    case "fail":
      return "error";
    case "skip":
      return "idle";
  }
}

const dotStatus = (row: ChecklistRow) => (row.status.kind === "done" ? row.status.state : row.status.kind);

function stepName(step: string, strings: Strings): string {
  const key = stepKey(step);
  return key ? strings.t(key) : step;
}

function StepRow({
  row,
  open,
  installing,
  strings,
}: {
  row: ChecklistRow;
  open: boolean;
  installing: boolean;
  strings: Strings;
}) {
  const detail =
    row.step === "install" && row.status.kind === "running" && installing
      ? strings.t("addMachine.installingAppBuild")
      : row.status.kind === "done" && row.status.state === "fail" && row.detail === ""
        ? strings.t("addMachine.stopped")
        : row.detail;
  const showFix = row.fix && (open || (row.status.kind === "done" && row.status.state === "warn"));
  const label = [stepName(row.step, strings), strings.t(statusKey(row)), detail, row.fix ?? ""]
    .filter((part) => part !== "")
    .join(". ");
  return (
    <li className="am-step" data-status={dotStatus(row)} data-open={open || undefined} aria-label={label}>
      <StatusGlyph name={glyphOf(row)} className="am-glyph" size={12} />
      <span className="am-step-text">
        <span className="am-step-name">{stepName(row.step, strings)}</span>
        {detail ? <span className="am-step-detail">{detail}</span> : null}
        {showFix ? <span className="am-step-fix">{row.fix}</span> : null}
      </span>
    </li>
  );
}

function Footer({ store, view, strings }: { store: AddMachineStore; view: AddMachineView; strings: Strings }) {
  return (
    <footer className="am-footer">
      {view.phase === "running" ? <StatusGlyph name="working" size={12} /> : null}
      <span className="am-spacer" />
      {view.buttons.map((button) => (
        <FooterButton key={button.action} button={button} view={view} strings={strings} store={store} />
      ))}
    </footer>
  );
}

function FooterButton({
  button,
  view,
  strings,
  store,
}: {
  button: AddMachineButton;
  view: AddMachineView;
  strings: Strings;
  store: AddMachineStore;
}) {
  return (
    <DialogButton
      dialogKey={button.key ?? null}
      className={button.key === "return" ? "am-button am-primary" : "am-button"}
      disabled={!button.enabled}
      data-action={button.action}
      onClick={() => void store.perform(button.action)}
    >
      {strings.t(buttonKey(button.action, view.phase))}
    </DialogButton>
  );
}

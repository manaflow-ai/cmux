// Import from Browsers, Express (docs/design/onboarding-import-express.md): one summary (the checked
// browsers' app icons, one sentence, the kinds to bring) over one Import, with the browsers that need
// a grant as asks under it. "Choose Browsers and Data…" swaps in the full list: one row per detected
// browser profile (the browser's icon with the profile's picture on it, the names, and a checkbox),
// then the kinds and Keep history in sync. Import runs in place: the summary names the profile being
// read over a progress bar (the list's rows show their own progress), then sums it up. A browser cmux
// has no folder grant for asks with Allow Access…, which swaps the body for the folder explainer; with
// passwords checked, Import first swaps it for the Keychain explainer. The explainers take the same
// body area, and the toggle under it keeps its place.
import { useState, type InputHTMLAttributes, type MouseEvent } from "react";
import { Button } from "../../ui/Button";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../ui/Menu";
import { Select } from "../../ui/Select";
import { StatusGlyph } from "../../ui/StatusGlyph";
import { ViewSwap } from "../../ui/motion/ViewSwap";
import { cx } from "../../ui/cx";
import { Lock, Spinner } from "../../agent-session/acpmux/conversation/icons";
import { OPS, type ImportCounts, type ImportRow, type ImportState } from "./ops";
import { HostIcon, useOnboarding } from "./parts";
import { countsLine, importRowDetail, importStatus, keychainLine, kindLabel } from "./text";

/** Row slots kept mounted, so detection fills them in place. */
export const IMPORT_ROW_SLOTS = 4;
/** The target menu's value for the row's own new matching profile. */
const NEW_PROFILE = "";
/** The row's own controls: a click on one is that control's, never the row's toggle. */
const ROW_CONTROLS =
  "input, button, select, a, [role='button'], [role='combobox'], [role='menu'], [role='listbox'], .onb-import-target";

/** A checkbox with its drawn mark: the box and the check (in the accent's text color) instead of
 * WebKit's, so every row's box is the same shape. */
function Check({
  className,
  "data-shown": shown,
  ...input
}: InputHTMLAttributes<HTMLInputElement> & { "data-shown"?: string }) {
  return (
    <span className={cx("onb-box", className)} data-shown={shown}>
      <input type="checkbox" {...input} />
      <svg className="onb-box-mark" viewBox="0 0 16 16" aria-hidden="true" focusable="false">
        <path d="M4 8.4 6.8 11 12 5.2" />
      </svg>
    </span>
  );
}

function ProfileRow({ row, importer }: { row: Extract<ImportRow, { kind: "profile" }>; importer: ImportState }) {
  const { strings, store } = useOnboarding();
  const idle = row.state.kind === "idle";
  const showsAccess = row.needsFullDiskAccess && idle;
  const editable = importer.editable && !row.needsFullDiskAccess;
  const showsBox = idle && !showsAccess;
  const { text, tooltip } = importRowDetail(strings, row);
  const offersTargets = !importer.targetFixed && importer.targetChoices.length > 0;
  const showsTarget = offersTargets && showsBox && importer.editable && row.checked;
  const name = row.profileName == null ? row.browserName : `${row.browserName} · ${row.profileName}`;
  const subtitle = row.needsFullDiskAccess ? strings.t("onboarding.import.fda.subtitle") : (row.profileName ?? "");
  const toggle = () => {
    if (editable) store.call(OPS.toggleProfile, { id: row.id });
  };
  // A click on the row's own surface checks it, or on a row that needs Full Disk Access opens that
  // pane; its controls (the checkbox, the target menu, Open System Settings) act alone, so picking a
  // target never also unchecks the profile.
  const rowClick = (event: MouseEvent<HTMLDivElement>) => {
    if ((event.target as Element).closest(ROW_CONTROLS)) return;
    if (showsAccess) store.call(OPS.openFullDiskAccess);
    else if (showsBox) toggle();
  };
  const glyph = row.state.kind === "done" ? "done" : row.state.kind === "failed" ? "error" : null;
  return (
    <div
      className="onb-import-row"
      role="presentation"
      onClick={rowClick}
      data-row={row.id}
      data-state={row.state.kind}
      data-editable={(editable && showsBox) || showsAccess ? "" : undefined}
      data-access={showsAccess ? "" : undefined}
      data-dimmed={showsBox && !row.checked ? "" : undefined}
    >
      <span className="onb-import-icons">
        <HostIcon image={row.icon} className="onb-import-icon" />
        <HostIcon image={row.avatar} className="onb-import-avatar" />
      </span>
      <span className="onb-import-names">
        <span className="onb-import-name">{row.browserName}</span>
        <span className="onb-import-sub">{subtitle}</span>
      </span>
      <span className="onb-import-trailing">
        <span className="onb-import-detail" title={tooltip ?? undefined}>
          {text}
        </span>
        {offersTargets && (
          <span className="onb-import-target" data-shown={showsTarget ? "" : undefined} inert={!showsTarget}>
            <Select
              label={strings.t("onboarding.import.target.label")}
              value={row.target ?? NEW_PROFILE}
              closeOnPick
              align="end"
              disabled={!showsTarget}
              options={[
                { value: NEW_PROFILE, label: strings.t("onboarding.import.target.new") },
                ...importer.targetChoices.map((choice) => ({ value: choice.id, label: choice.name })),
              ]}
              onChange={(value) =>
                store.call(OPS.setTarget, { id: row.id, target: value === NEW_PROFILE ? null : value })
              }
            />
          </span>
        )}
        {showsAccess && (
          <Button
            variant="subtle"
            size="sm"
            className="onb-import-access"
            onClick={() => store.call(OPS.openFullDiskAccess)}
          >
            {strings.t("onboarding.button.openSystemSettings")}
          </Button>
        )}
        <span className="onb-slot onb-import-state">
          <Check
            className="onb-import-box"
            data-shown={showsBox ? "" : undefined}
            aria-hidden={showsBox ? undefined : true}
            tabIndex={showsBox ? undefined : -1}
            aria-label={name}
            checked={row.checked}
            disabled={!editable || !showsBox}
            onChange={toggle}
          />
          <span className="onb-slot-spinner" data-shown={row.state.kind === "importing" ? "" : undefined}>
            <Spinner size={16} loading />
          </span>
          <span className="onb-import-glyph" data-shown={glyph ? "" : undefined}>
            {glyph && <StatusGlyph name={glyph} size={12} label={text} />}
          </span>
        </span>
      </span>
    </div>
  );
}

function AwaitingRow({ row }: { row: Extract<ImportRow, { kind: "awaiting" }> }) {
  const { strings, store } = useOnboarding();
  return (
    <div className="onb-import-row" data-row={`awaiting:${row.browser}`} data-state="awaiting">
      <span className="onb-import-icons">
        <HostIcon image={row.icon} className="onb-import-icon" />
      </span>
      <span className="onb-import-names">
        <span className="onb-import-name">{row.browserName}</span>
        <span className="onb-import-sub">{strings.t("onboarding.access.needed")}</span>
      </span>
      <span className="onb-import-trailing">
        <Button
          variant="subtle"
          size="sm"
          className="onb-import-access"
          onClick={() => store.call(OPS.askAccess, { browser: row.browser })}
        >
          {strings.t("onboarding.access.allow")}
        </Button>
        <span className="onb-slot onb-import-state" />
      </span>
    </div>
  );
}

function KindChoices({ importer }: { importer: ImportState }) {
  const { strings, store } = useOnboarding();
  return (
    <div className="onb-kinds">
      {importer.kindChoices.map((kind) => (
        <label key={kind} className="onb-check" data-kind={kind}>
          <Check
            aria-label={kindLabel(strings, kind)}
            checked={importer.kinds.includes(kind)}
            disabled={!importer.editable}
            onChange={() => store.call(OPS.toggleKind, { kind })}
          />
          {kindLabel(strings, kind)}
        </label>
      ))}
    </div>
  );
}

function ImportList({ importer }: { importer: ImportState }) {
  const { strings, store } = useOnboarding();
  // The list draws what was found, and keeps row slots only while browsers are looked for (as
  // placeholders), so the card never shows empty rows.
  const slots = importer.phase === "detecting" ? Math.max(0, IMPORT_ROW_SLOTS - importer.rows.length) : 0;
  const history = importer.kinds.includes("history");
  return (
    <div className="onb-import-main">
      <div className="onb-import-shelf">
        <div
          className="onb-import-list onb-scroll"
          data-phase={importer.phase}
          data-empty={importer.rows.length === 0 && slots === 0 ? "" : undefined}
        >
          {importer.rows.map((row) =>
            row.kind === "profile" ? (
              <ProfileRow key={row.id} row={row} importer={importer} />
            ) : (
              <AwaitingRow key={`awaiting:${row.browser}`} row={row} />
            ),
          )}
          {Array.from({ length: slots }, (_, index) => (
            <div key={`slot-${index}`} className="onb-import-row" data-state="slot" aria-hidden="true">
              <span className="onb-slot-icon" />
              <span className="onb-slot-bar" />
            </div>
          ))}
        </div>
      </div>
      <div className="onb-import-options">
        <KindChoices importer={importer} />
        {/* Keep in Sync stays shown and dimmed without History, so the kinds card never holds an
            empty line. */}
        <label
          className="onb-check onb-sync"
          data-off={history ? undefined : ""}
          inert={!history}
          title={strings.t("onboarding.import.keepInSync.help")}
        >
          <Check
            aria-label={strings.t("onboarding.import.keepInSync")}
            checked={importer.keepsHistoryInSync}
            disabled={!importer.editable || !history}
            onChange={() => store.call(OPS.toggleKeepInSync)}
          />
          {strings.t("onboarding.import.keepInSync")}
        </label>
      </div>
    </div>
  );
}

/** The other ways in (another browser's export files, a passwords CSV), in the footer: one button when
 * only the files are offered, else a menu of both. Hidden in place while an explainer shows, so the
 * footer never moves. */
export function ImportSources({ importer }: { importer: ImportState }) {
  const { strings, store } = useOnboarding();
  const explaining = importer.phase === "confirmingPasswords" || importer.phase === "explainingAccess";
  const fromFiles = strings.t("onboarding.import.fromFiles");
  return (
    <div className={cx("onb-footer-sources", explaining && "is-hidden")} inert={explaining}>
      {importer.offersPasswordCSV ? (
        <Menu>
          <MenuButton
            className="ui-btn onb-link-button onb-sources-button"
            label={strings.t("onboarding.import.otherSources")}
          >
            <span>{strings.t("onboarding.import.otherSources")}</span>
            <span className="onb-sources-chevron" aria-hidden="true" />
          </MenuButton>
          <MenuPopup side="top" align="start">
            <MenuItem onSelect={() => store.call(OPS.fromFiles)}>{fromFiles}</MenuItem>
            <MenuItem onSelect={() => store.call(OPS.passwordsCSV)}>
              {strings.t("onboarding.import.passwordsCSV")}
            </MenuItem>
          </MenuPopup>
        </Menu>
      ) : (
        <Button variant="ghost" size="sm" className="onb-link-button" onClick={() => store.call(OPS.fromFiles)}>
          {fromFiles}
        </Button>
      )}
    </div>
  );
}

export function ProgressBar({ value }: { value: number | null }) {
  const fraction = Math.max(0, Math.min(1, value ?? 0));
  return (
    // How far the import flow is, for the eye; the explainer's title says where it is.
    <div className="onb-progress" aria-hidden="true">
      <span className="onb-progress-bar" style={{ transform: `scaleX(${fraction})` }} />
    </div>
  );
}

function AccessExplainer({
  access,
  progress,
}: {
  access: NonNullable<ImportState["access"]>;
  progress: number | null;
}) {
  const { strings } = useOnboarding();
  return (
    <div className="onb-explainer" data-explainer="access">
      <ProgressBar value={progress} />
      <h2 className="onb-explainer-title">{strings.format("onboarding.access.title", access.browserName)}</h2>
      <p>{strings.t("onboarding.access.none")}</p>
      <p>{strings.format("onboarding.access.how", access.browserName)}</p>
      <div className="onb-steps">
        <p>{strings.t("onboarding.access.step1")}</p>
        <p>{strings.t("onboarding.access.step2.open")}</p>
        <p className="onb-folder font-mono selectable">{access.folder}</p>
      </div>
      <output className="onb-explainer-note" data-shown={access.notGranted ? "" : undefined}>
        {access.notGranted ? strings.format("onboarding.access.notGranted", access.folder) : ""}
      </output>
    </div>
  );
}

function ConsentExplainer({
  consent,
  progress,
  offersPasswordCSV,
}: {
  consent: NonNullable<ImportState["consent"]>;
  progress: number | null;
  offersPasswordCSV: boolean;
}) {
  const { strings, store } = useOnboarding();
  return (
    <div className="onb-explainer" data-explainer="consent">
      <ProgressBar value={progress} />
      <h2 className="onb-explainer-title onb-explainer-heading">
        <Lock size={16} className="onb-explainer-lock" />
        {strings.t("onboarding.unlock.title")}
      </h2>
      <p>{keychainLine(strings, consent.keychainItems, consent.includesFirefox)}</p>
      <output className="onb-explainer-note" data-shown={consent.denied ? "" : undefined}>
        {consent.denied ? strings.t("onboarding.passwords.authDenied") : ""}
      </output>
      <div className="onb-links">
        <Button
          variant="ghost"
          size="sm"
          className="onb-link-button"
          disabled={consent.authorizing}
          onClick={() => store.call(OPS.skipPasswords)}
        >
          {strings.t("onboarding.button.importWithoutPasswords")}
        </Button>
        {offersPasswordCSV && (
          <Button variant="ghost" size="sm" className="onb-link-button" onClick={() => store.call(OPS.passwordsCSV)}>
            {strings.t("onboarding.import.passwordsCSV")}
          </Button>
        )}
      </div>
    </div>
  );
}

/** The browsers (name and icon, in list order, one per browser) whose profiles pass `keep`. */
function browsersOf(importer: ImportState, keep: (row: Extract<ImportRow, { kind: "profile" }>) => boolean) {
  const seen = new Map<string, Extract<ImportRow, { kind: "profile" }>["icon"]>();
  for (const row of importer.rows)
    if (row.kind === "profile" && keep(row) && !seen.has(row.browserName)) seen.set(row.browserName, row.icon);
  return [...seen].map(([name, icon]) => ({ name, icon }));
}

function listOf(names: string[], language: string): string {
  try {
    return new Intl.ListFormat(language, { type: "conjunction" }).format(names);
  } catch {
    return new Intl.ListFormat("en", { type: "conjunction" }).format(names);
  }
}

function sum(counts: ImportCounts[]): ImportCounts {
  const total: ImportCounts = { bookmarks: 0, history: 0, openTabs: 0, cookies: 0, passwords: 0, searchEngines: 0 };
  for (const c of counts) for (const key of Object.keys(total) as (keyof ImportCounts)[]) total[key] += c[key];
  return total;
}

/** Icons shown in the summary's stack, at most. */
const STACK = 4;

/** Express: the summary over the one Import. While browsers are looked for it keeps three icon
 * placeholders; ready, it names the checked browsers and the kinds and lists the grant asks;
 * importing, it names the profile being read over a progress bar and the counts so far; after, it
 * says what came over (the step's status line). */
function ExpressSummary({ importer, status }: { importer: ImportState; status: string }) {
  const { strings, store } = useOnboarding();
  const { phase } = importer;
  const started = (row: Extract<ImportRow, { kind: "profile" }>) => row.state.kind !== "idle";
  const ready = phase === "ready" || phase === "cancelled";
  const browsers =
    phase === "importing" || phase === "finished"
      ? browsersOf(importer, started)
      : browsersOf(importer, (row) => row.checked && !row.needsFullDiskAccess);
  const profiles = importer.rows.filter((row) => row.kind === "profile");
  const current = profiles.find((row) => row.state.kind === "importing");
  const inImport = profiles.filter(started);
  const landed = inImport.filter((row) => row.state.kind === "done" || row.state.kind === "failed").length;
  const counts = countsLine(
    strings,
    sum(inImport.map((row) => ("counts" in row.state ? row.state.counts : null)).filter((c) => c != null)),
  );
  const fullDisk = ready && importer.editable ? browsersOf(importer, (row) => row.needsFullDiskAccess) : [];
  const awaiting = ready && importer.editable ? importer.rows.filter((row) => row.kind === "awaiting") : [];
  let lead = status;
  if (ready && profiles.length + awaiting.length > 0)
    lead =
      browsers.length === 0
        ? strings.t("onboarding.import.express.noneChecked")
        : strings.format(
            "onboarding.import.express.lead",
            listOf(
              browsers.map((b) => b.name),
              strings.language,
            ),
          );
  if (phase === "importing")
    lead = current
      ? strings.format(
          "onboarding.import.express.importing",
          current.profileName ? `${current.browserName} · ${current.profileName}` : current.browserName,
        )
      : "";
  return (
    <div className="onb-express" data-phase={phase}>
      <div className="onb-express-stack" aria-hidden="true">
        {phase === "detecting" || phase === "idle"
          ? Array.from({ length: 3 }, (_, index) => <span key={index} className="onb-express-icon" data-empty="" />)
          : browsers
              .slice(0, STACK)
              .map((browser) => <HostIcon key={browser.name} image={browser.icon} className="onb-express-icon" />)}
        {phase === "finished" && (
          <span className="onb-express-done">
            <StatusGlyph name="done" size={20} />
          </span>
        )}
      </div>
      <output className="onb-express-lead" aria-live="polite">
        {lead}
      </output>
      {ready && browsers.length > 0 && (
        <p className="onb-express-kinds">{importer.kinds.map((kind) => kindLabel(strings, kind)).join(" · ")}</p>
      )}
      {phase === "importing" && (
        <div className="onb-express-progress">
          <ProgressBar value={inImport.length === 0 ? 0 : (landed + 0.5) / inImport.length} />
          <p className="onb-express-kinds">{counts}</p>
        </div>
      )}
      {fullDisk.length + awaiting.length > 0 && (
        <ul className="onb-express-asks">
          {fullDisk.map((browser) => (
            <li key={`fda:${browser.name}`} className="onb-express-ask">
              <HostIcon image={browser.icon} className="onb-express-ask-icon" />
              <span className="onb-express-ask-text">
                {strings.format("onboarding.import.express.fda", browser.name)}
              </span>
              <Button variant="subtle" size="sm" onClick={() => store.call(OPS.openFullDiskAccess)}>
                {strings.t("onboarding.button.openSystemSettings")}
              </Button>
            </li>
          ))}
          {awaiting.map(
            (row) =>
              row.kind === "awaiting" && (
                <li key={`awaiting:${row.browser}`} className="onb-express-ask">
                  <HostIcon image={row.icon} className="onb-express-ask-icon" />
                  <span className="onb-express-ask-text">
                    {strings.format("onboarding.import.express.folder", row.browserName)}
                  </span>
                  <Button
                    variant="subtle"
                    size="sm"
                    onClick={() => store.call(OPS.askAccess, { browser: row.browser })}
                  >
                    {strings.t("onboarding.access.allow")}
                  </Button>
                </li>
              ),
          )}
        </ul>
      )}
    </div>
  );
}

export function ImportStep({ importer, progress }: { importer: ImportState; progress: number | null }) {
  const { strings } = useOnboarding();
  // The full list is opt-in, per visit of the step: Express shows the summary first, except after an
  // import some profiles failed, whose rows say why on hover. A press of the toggle decides from then on.
  const [chosen, setChosen] = useState<boolean | null>(null);
  const details = chosen ?? (importer.phase === "finished" && importer.summary?.someFailed === true);
  const setDetails = (next: (open: boolean) => boolean) => setChosen(next(details));
  const consent = importer.phase === "confirmingPasswords" ? importer.consent : null;
  const access = consent == null && importer.phase === "explainingAccess" ? importer.access : null;
  const mode = consent != null ? "consent" : access != null ? "access" : details ? "list" : "summary";
  const status = importStatus(strings, importer);
  const explaining = consent != null || access != null;
  const offersDetails = importer.rows.length > 0;
  return (
    <div className="onb-import" data-mode={mode}>
      <ViewSwap swapKey={mode} look="fade" className="onb-import-body">
        {consent != null ? (
          <ConsentExplainer consent={consent} progress={progress} offersPasswordCSV={importer.offersPasswordCSV} />
        ) : access != null ? (
          <AccessExplainer access={access} progress={progress} />
        ) : details ? (
          <ImportList importer={importer} />
        ) : (
          <ExpressSummary importer={importer} status={status} />
        )}
      </ViewSwap>
      {mode === "list" && status !== "" && (
        <output className="onb-status" aria-live="polite" title={status || undefined}>
          {status}
        </output>
      )}
      <div
        className={cx("onb-express-toggle", (explaining || !offersDetails) && "is-hidden")}
        inert={explaining || !offersDetails}
      >
        <Button variant="ghost" size="sm" className="onb-link-button" onClick={() => setDetails((open) => !open)}>
          {details ? strings.t("onboarding.import.express.hide") : strings.t("onboarding.import.express.choose")}
        </Button>
      </div>
    </div>
  );
}

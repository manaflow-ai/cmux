// Import from Browsers: one row per detected browser profile (the browser's icon with the profile's
// picture on it, the names, and a checkbox), then the line of kinds to bring and Keep history in
// sync. Import runs in place: each row shows its progress, then what came over; the line under the
// list sums it up. A browser cmux has no folder grant for is a row with Allow Access…, which swaps
// the list for the folder explainer; with passwords checked, Import first swaps it for the Keychain
// explainer. The list keeps four row slots mounted while browsers are looked for, and the explainers
// take the same body area, so the status line and the links never move.
import type { MouseEvent } from "react";
import { Button } from "../../ui/Button";
import { Select } from "../../ui/Select";
import { StatusGlyph } from "../../ui/StatusGlyph";
import { ViewSwap } from "../../ui/motion/ViewSwap";
import { cx } from "../../ui/cx";
import { Lock, Spinner } from "../../agent-session/acpmux/conversation/icons";
import { OPS, type ImportRow, type ImportState } from "./ops";
import { HostIcon, useOnboarding } from "./parts";
import { importRowDetail, importStatus, keychainLine, kindLabel } from "./text";

/** Row slots kept mounted, so detection fills them in place. */
export const IMPORT_ROW_SLOTS = 4;
/** The target menu's value for the row's own new matching profile. */
const NEW_PROFILE = "";
/** The row's own controls: a click on one is that control's, never the row's toggle. */
const ROW_CONTROLS =
  "input, button, select, a, [role='button'], [role='combobox'], [role='menu'], [role='listbox'], .onb-import-target";

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
  // A click on the row's own surface checks it; its controls (the checkbox, the target menu, Open
  // System Settings) act alone, so picking a target never also unchecks the profile.
  const rowClick = (event: MouseEvent<HTMLDivElement>) => {
    if (!showsBox || (event.target as Element).closest(ROW_CONTROLS)) return;
    toggle();
  };
  const glyph = row.state.kind === "done" ? "done" : row.state.kind === "failed" ? "error" : null;
  return (
    <div
      className="onb-import-row"
      role="presentation"
      onClick={rowClick}
      data-row={row.id}
      data-state={row.state.kind}
      data-editable={editable && showsBox ? "" : undefined}
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
            variant="ghost"
            size="sm"
            className="onb-import-access"
            onClick={() => store.call(OPS.openFullDiskAccess)}
          >
            {strings.t("onboarding.button.openSystemSettings")}
          </Button>
        )}
        <span className="onb-slot onb-import-state">
          <input
            type="checkbox"
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
          variant="ghost"
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

function ImportList({ importer }: { importer: ImportState }) {
  const { strings, store } = useOnboarding();
  const empty = Math.max(0, IMPORT_ROW_SLOTS - importer.rows.length);
  const history = importer.kinds.includes("history");
  return (
    <div className="onb-import-main">
      <div className="onb-import-list onb-scroll" data-phase={importer.phase}>
        {importer.rows.map((row) =>
          row.kind === "profile" ? (
            <ProfileRow key={row.id} row={row} importer={importer} />
          ) : (
            <AwaitingRow key={`awaiting:${row.browser}`} row={row} />
          ),
        )}
        {Array.from({ length: empty }, (_, index) => (
          <div key={`slot-${index}`} className="onb-import-row" data-state="slot" aria-hidden="true" />
        ))}
      </div>
      <hr className="onb-separator" />
      <div className="onb-kinds">
        {importer.kindChoices.map((kind) => (
          <label key={kind} className="onb-check" data-kind={kind}>
            <input
              type="checkbox"
              aria-label={kindLabel(strings, kind)}
              checked={importer.kinds.includes(kind)}
              disabled={!importer.editable}
              onChange={() => store.call(OPS.toggleKind, { kind })}
            />
            {kindLabel(strings, kind)}
          </label>
        ))}
      </div>
      <label
        className="onb-check onb-sync"
        data-shown={history ? "" : undefined}
        inert={!history}
        title={strings.t("onboarding.import.keepInSync.help")}
      >
        <input
          type="checkbox"
          aria-label={strings.t("onboarding.import.keepInSync")}
          checked={importer.keepsHistoryInSync}
          disabled={!importer.editable}
          onChange={() => store.call(OPS.toggleKeepInSync)}
        />
        {strings.t("onboarding.import.keepInSync")}
      </label>
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

export function ImportStep({ importer, progress }: { importer: ImportState; progress: number | null }) {
  const { strings, store } = useOnboarding();
  const consent = importer.phase === "confirmingPasswords" ? importer.consent : null;
  const access = consent == null && importer.phase === "explainingAccess" ? importer.access : null;
  const mode = consent != null ? "consent" : access != null ? "access" : "list";
  const status = importStatus(strings, importer);
  const explaining = mode !== "list";
  return (
    <div className="onb-import" data-mode={mode}>
      <ViewSwap swapKey={mode} look="fade" className="onb-import-body">
        {consent != null ? (
          <ConsentExplainer consent={consent} progress={progress} offersPasswordCSV={importer.offersPasswordCSV} />
        ) : access != null ? (
          <AccessExplainer access={access} progress={progress} />
        ) : (
          <ImportList importer={importer} />
        )}
      </ViewSwap>
      <output className="onb-status" aria-live="polite" title={status || undefined}>
        {status}
      </output>
      <div className={cx("onb-links", explaining && "is-hidden")} inert={explaining}>
        <Button variant="ghost" size="sm" className="onb-link-button" onClick={() => store.call(OPS.fromFiles)}>
          {strings.t("onboarding.import.fromFiles")}
        </Button>
        {importer.offersPasswordCSV && (
          <Button variant="ghost" size="sm" className="onb-link-button" onClick={() => store.call(OPS.passwordsCSV)}>
            {strings.t("onboarding.import.passwordsCSV")}
          </Button>
        )}
      </div>
    </div>
  );
}

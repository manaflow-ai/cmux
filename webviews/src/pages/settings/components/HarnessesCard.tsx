// Agents > Harnesses (cx-mg91): the coding agents this app's acpmux can start, from the host's
// `cmux.settings.harnesses.state` (it reads acpmux's `_acpmux/harnesses`), live through
// cmux.settings.harnesses.changed. Sign In and Check open a terminal tab of the focused pane
// running `acpmux harness login <id>` (`--status` for Check), so the agent's own sign-in runs
// where the person sees it; Browse ACP Registry runs `acpmux harness registry` the same way.
// Health (cx-ny85, `_acpmux/harness/health`): the installed and newest versions, a sign-out the
// daemon has evidence for, and Update / Update all, which start owner-bound terminal jobs.
// An update that needs sudo shows its exact command instead of a button.
// Accounts (`_acpmux/accounts`, when the daemon has it): a provider row says "Authenticated · <plan>"
// for the CLI's own login and lists every account routing may use under it (ProviderAccounts).
import { useCallback, useId } from "react";
import { Button } from "../../../ui/Button";
import { agentDisplayName } from "../../../agent-session/acpmux/agents";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { useSettingsState, useStore } from "../context";
import {
  accountRows,
  accountsFor,
  agoText,
  newestCheck,
  offersUpdate,
  planName,
  primaryAccount,
  updatable,
  updateUnsettled,
} from "../harnesses";
import type { HarnessRow, HarnessesState, ProviderAccount } from "../ops";
import { locale, t } from "../strings";
import { ProviderAccounts } from "./ProviderAccounts";

const SOURCES = new Set(["managed", "user-file", "cmux-json", "registry", "path", "config"]);

function sourceText(row: HarnessRow): string {
  return t(`settingsWindow.harnesses.source.${SOURCES.has(row.source) ? row.source : "config"}`);
}

function jobText(job: NonNullable<HarnessesState["jobs"]>[number]): string {
  if (job.state === "created") return t("settingsWindow.harnesses.jobCreated");
  if (job.state === "pending") return t("settingsWindow.harnesses.jobPending");
  if (job.state === "exited" && job.exit_code !== undefined)
    return t("settingsWindow.harnesses.jobExit", job.exit_code);
  if (job.state === "exited" && job.signal !== undefined) return t("settingsWindow.harnesses.jobSignal", job.signal);
  // A lost creation reply (`unknown`) and an end without a process result (`outcome: "unknown"`).
  return t("settingsWindow.harnesses.jobUnknown");
}

function HarnessUpdateCard({ row, harnesses }: { row: HarnessRow; harnesses: HarnessesState | null }) {
  const store = useStore();
  const name = row.name ?? agentDisplayName(row.id);
  const safeUpdate = offersUpdate(row);
  const titleId = useId();
  const unsettled = updateUnsettled(harnesses, row.id);
  if (!row.outdated || !row.version || !row.latest || !row.update) return null;
  return (
    <article className="harness-update-card" data-harness-update-card={row.id}>
      <div className="harness-update-card-copy">
        <strong id={titleId}>{t("settingsWindow.harnesses.updateCard.title", name)}</strong>
        <p className="row-help">{t("settingsWindow.harnesses.updateCard.detail", row.version, row.latest)}</p>
        {row.update.elevated && <p className="row-help">{t("settingsWindow.harnesses.updateElevated")}</p>}
        {!safeUpdate && !row.update.elevated && (
          <p className="row-help">{t("settingsWindow.harnesses.updateCard.manual", name)}</p>
        )}
        {!safeUpdate && (
          <code className="font-mono selectable" data-harness-update-command="">
            {row.update.command}
          </code>
        )}
      </div>
      {safeUpdate && (
        <Button
          type="button"
          className="button"
          data-harness-action="updateCard"
          aria-describedby={titleId}
          disabled={unsettled}
          onClick={() => void store.runHarnesses({ action: "update", id: row.id })}
        >
          {t("settingsWindow.harnesses.update")}
        </Button>
      )}
    </article>
  );
}

/** "Authenticated · ChatGPT Pro" for the CLI's own login, or "Not signed in". */
function authLine(family: string, account: ProviderAccount): string {
  if (!account.signedIn) return t("settingsWindow.harnesses.notAuthenticated");
  const plan = planName(family, account.plan);
  return plan ? t("settingsWindow.harnesses.authenticatedPlan", plan) : t("settingsWindow.harnesses.authenticated");
}

function Row({ row, family }: { row: HarnessRow; family: string | null }) {
  const store = useStore();
  const { harnesses } = useSettingsState();
  const accounts = family ? accountsFor(harnesses, family) : null;
  const primary = primaryAccount(accounts);
  const name = row.name ?? agentDisplayName(row.id);
  const terminal = row.kind === "terminal";
  // Every row has a Check and a Sign In: each names its harness for assistive tech.
  const titleId = useId();
  return (
    <div className="row accounts-row" data-harness={row.id}>
      <div className="row-main">
        <span className="accounts-mark" aria-hidden="true">
          <AgentMark agent={row.id} size={16} />
        </span>
        <div className="row-label">
          <div className="row-title" id={titleId}>
            {name}
          </div>
          <div className="row-help">
            {row.id === name.toLowerCase() ? sourceText(row) : `${row.id} · ${sourceText(row)}`}
          </div>
          {family && primary && (
            <div className="row-help" data-harness-account-auth={primary.signedIn ? "signedIn" : "signedOut"}>
              {authLine(family, primary)}
            </div>
          )}
          {row.version && (
            <div className="row-help" data-harness-version="">
              {row.outdated && row.latest
                ? t("settingsWindow.harnesses.versionOutdated", row.version, row.latest)
                : t("settingsWindow.harnesses.version", row.version)}
            </div>
          )}
          {row.outdated && row.update?.elevated && (
            <>
              <div className="row-help">{t("settingsWindow.harnesses.updateElevated")}</div>
              {/* The command is a value to copy, on its own line, not part of the description. */}
              <div className="row-help selectable">
                <code className="font-mono" data-harness-command="">
                  {row.update.command}
                </code>
              </div>
            </>
          )}
          {row.update && !row.update.elevated && (
            <label className="row-help harness-auto">
              <input
                type="checkbox"
                data-harness-auto=""
                aria-label={t("settingsWindow.harnesses.autoUpdate")}
                checked={row.autoUpdate ?? false}
                aria-describedby={titleId}
                onChange={(event) =>
                  void store.runHarnesses({ action: "autoUpdate", id: row.id, on: event.currentTarget.checked })
                }
              />{" "}
              {t("settingsWindow.harnesses.autoUpdate")}
            </label>
          )}
          {row.lastAutoUpdate && !row.lastAutoUpdate.ok && (
            <div className="row-error" data-harness-auto-failed="">
              {t("settingsWindow.harnesses.autoUpdateFailed", row.lastAutoUpdate.detail)}
            </div>
          )}
          {(row.auth === "signedOut" || row.auth === "expired") && (
            <div className="row-error" data-harness-auth={row.auth}>
              {t("settingsWindow.harnesses.signedOut")}
            </div>
          )}
          {row.problem && <div className="row-error">{row.problem}</div>}
        </div>
        <div className="row-control">
          {offersUpdate(row) && (
            <Button
              type="button"
              className="button"
              data-harness-action="update"
              disabled={updateUnsettled(harnesses, row.id)}
              aria-describedby={titleId}
              onClick={() => void store.runHarnesses({ action: "update", id: row.id })}
            >
              {t("settingsWindow.harnesses.update")}
            </Button>
          )}
          {terminal ? (
            <span className="badge">{t("settingsWindow.harnesses.terminalOnly")}</span>
          ) : (
            <>
              <Button
                type="button"
                className="button"
                data-harness-action="check"
                aria-describedby={titleId}
                onClick={() => void store.runHarnesses({ action: "check", id: row.id })}
              >
                {t("settingsWindow.harnesses.check")}
              </Button>
              <Button
                type="button"
                className="button"
                data-harness-action="signIn"
                aria-describedby={titleId}
                onClick={() => void store.runHarnesses({ action: "signIn", id: row.id })}
              >
                {t("settingsWindow.harnesses.signIn")}
              </Button>
            </>
          )}
        </div>
      </div>
      {family && accounts && accounts.length > 0 && <ProviderAccounts family={family} accounts={accounts} />}
    </div>
  );
}

export function HarnessesCard() {
  const store = useStore();
  const { harnesses } = useSettingsState();
  const outdated = updatable(harnesses);
  const families = accountRows(harnesses);
  const checked = newestCheck(harnesses);
  const ago = checked === null ? null : agoText(checked, Date.now(), locale());
  // Read again when the card mounts (a stable callback ref runs once per mount), like Accounts:
  // a harness installed since the last visit shows.
  const mounted = useCallback(
    (node: HTMLElement | null) => {
      if (node) void store.runHarnesses({ action: "refresh" });
    },
    [store],
  );
  return (
    <section className="group" data-card="harnesses" ref={mounted}>
      <h3 className="group-title">{t("settingsWindow.harnesses.title")}</h3>
      <div className="accounts-header">
        {checked !== null && (
          <span className="row-help" data-harnesses-checked="">
            {ago ? t("settingsWindow.harnesses.checkedAgo", ago) : t("settingsWindow.harnesses.checkedJustNow")}
          </span>
        )}
        <Button
          type="button"
          className="button"
          data-harness-action="refresh"
          disabled={harnesses?.loading ?? false}
          onClick={() => void store.runHarnesses({ action: "refresh", recheck: true })}
        >
          {t("settingsWindow.harnesses.refresh")}
        </Button>
        <Button
          type="button"
          className="button"
          data-harness-action="registry"
          disabled={harnesses?.problem === "unavailable"}
          onClick={() => void store.runHarnesses({ action: "registry" })}
        >
          {t("settingsWindow.harnesses.registry")}
        </Button>
        {outdated.length > 0 && (
          <Button
            type="button"
            className="button"
            data-harness-action="updateAll"
            onClick={() => void store.runHarnesses({ action: "updateAll" })}
          >
            {t("settingsWindow.harnesses.updateAll")}
          </Button>
        )}
      </div>
      {harnesses && !harnesses.problem && (
        <div className="harness-update-cards" data-harness-update-cards="">
          {harnesses.harnesses.map((row) => (
            <HarnessUpdateCard key={row.id} row={row} harnesses={harnesses} />
          ))}
        </div>
      )}
      {(harnesses?.jobs ?? []).map((job, index) => (
        <div key={`${job.machine}:${job.terminal ?? index}`} className="row-help" data-agent-update-job={job.state}>
          <output>
            {agentDisplayName(job.cli)}
            {" · "}
            {jobText(job)}
          </output>
          {job.can_resume && job.intent_key && job.state === "unknown" && !job.terminal && (
            <Button
              type="button"
              className="button"
              data-harness-action="resumeUpdate"
              onClick={() => void store.runHarnesses({ action: "resumeUpdate", intent: job.intent_key })}
            >
              {t("settingsWindow.harnesses.resumeUpdate")}
            </Button>
          )}
          {job.can_dismiss && job.intent_key && job.state === "unknown" && !job.terminal && (
            <Button
              type="button"
              className="button"
              data-harness-action="dismissUpdate"
              onClick={() => void store.runHarnesses({ action: "dismissUpdate", intent: job.intent_key })}
            >
              {t("settingsWindow.harnesses.dismissUpdate")}
            </Button>
          )}
        </div>
      ))}
      {harnesses?.problem && (
        <div className="row-error" data-harnesses-problem={harnesses.problem}>
          {t(`settingsWindow.harnesses.problem.${harnesses.problem}`)}
        </div>
      )}
      {harnesses && !harnesses.problem && harnesses.harnesses.length === 0 && !harnesses.loading && (
        <div className="row-help" data-harnesses-empty="">
          {t("settingsWindow.harnesses.empty")}
        </div>
      )}
      {harnesses?.loading && !harnesses.problem && harnesses.harnesses.length === 0 && (
        <div className="row-help" data-harnesses-checking="">
          {t("settingsPage.agents.checking")}
        </div>
      )}
      {harnesses && harnesses.harnesses.length > 0 && (
        <div className="rows">
          {harnesses.harnesses.map((row) => (
            <Row key={row.id} row={row} family={families.get(row.id) ?? null} />
          ))}
        </div>
      )}
    </section>
  );
}

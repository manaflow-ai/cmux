// Settings > Integrations: the integrations hub (cmux platform /v1/hub), as the bundled
// `cmux hub overview --json` shapes it (SettingsIntegrationsHub in the app; cmux-tui cli/hub.rs
// writes every label, amount and sentence this card shows). Linked accounts with Remove, Link
// Stripe (a pasted restricted key, sent once to the host and cleared here) and Link GitHub, the
// approvals waiting for the person with Allow, Deny and Don't ask again, the rules with Add and
// Remove, the pause switch and recent audit rows. Nothing changes without a click; an approval is
// answered only here, never by the CLI.
import { useCallback, useEffect, useId, useState, type FormEvent } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { useStore } from "../context";
import { Switch } from "../editors/ToggleEditor";
import type { HubCall, HubConnection, HubRule, HubRuleFields, HubRun, HubState } from "../ops";
import { t } from "../strings";

const SELECT_CLASS =
  "box-border h-7 rounded-md border border-solid border-edge bg-transparent px-2 font-[inherit] text-control text-fg outline-none focus:border-accent-soft";

/** The actions a rule can name from the card, with their labels. */
const RULE_ACTIONS = [
  { value: "stripe.refund.create", label: "settingsWindow.hub.rule.action.refunds" },
  { value: "stripe.*", label: "settingsWindow.hub.rule.action.anyStripe" },
  { value: "github.*", label: "settingsWindow.hub.rule.action.anyGithub" },
  { value: "*", label: "settingsWindow.hub.rule.action.any" },
] as const;

/** An audit row's tone as the status dot Settings > Devices draws. */
const AUDIT_TONE = { good: "success", warn: "attention", plain: "neutral" } as const;

type Run = (run: Exclude<HubRun, { action: "refresh" }>) => Promise<void>;

function ConnectionRow({ row, busy, onRun }: { row: HubConnection; busy: boolean; onRun: Run }) {
  const titleId = useId();
  const [confirming, setConfirming] = useState(false);
  const confirmTitle = t("settingsWindow.hub.removeTitle", row.title);
  const details = [row.modeLabel, row.sharingLabel].filter((part): part is string => !!part);
  return (
    <div className="row accounts-row" data-hub-connection={row.id} data-hub-provider={row.provider}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title" id={titleId}>
            {row.title}
          </div>
          <div className="row-help selectable">{details.join(" · ")}</div>
        </div>
        <span className="row-control keys-control">
          <span
            className="accounts-status devices-status"
            data-tone={row.healthy ? "success" : "attention"}
            data-hub-status=""
          >
            <span className="accounts-dot" aria-hidden="true" />
            {row.statusLabel}
          </span>
          {row.canRemove && !confirming && (
            <Button
              danger
              variant="ghost"
              className="button"
              data-hub-action="remove"
              aria-describedby={titleId}
              disabled={busy}
              onClick={() => setConfirming(true)}
            >
              {t("settingsWindow.hub.remove")}
            </Button>
          )}
        </span>
      </div>
      {confirming && (
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        <div className="accounts-form" data-hub-confirm="" role="group" aria-label={confirmTitle}>
          <div className="row-title">{confirmTitle}</div>
          <div className="row-help">{t("settingsWindow.hub.removeBody")}</div>
          <div className="accounts-buttons">
            <Button
              danger
              variant="ghost"
              className="button"
              data-hub-action="confirmRemove"
              disabled={busy}
              onClick={() => {
                setConfirming(false);
                void onRun({ action: "remove", id: row.id });
              }}
            >
              {t("settingsWindow.hub.remove")}
            </Button>
            <Button className="button" data-hub-action="cancel" onClick={() => setConfirming(false)}>
              {t("settingsWindow.hub.cancel")}
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}

function LinkStripe({ busy, onRun }: { busy: boolean; onRun: Run }) {
  const [key, setKey] = useState("");
  const [sharing, setSharing] = useState<"private" | "team">("private");
  const submit = (event: FormEvent) => {
    event.preventDefault();
    const pasted = key.trim();
    // The key goes to the host once and leaves the page's state at once.
    setKey("");
    if (pasted) void onRun({ action: "link", provider: "stripe", key: pasted, sharing });
  };
  return (
    <form className="row accounts-row hub-wide" data-hub-link="stripe" onSubmit={submit}>
      <div className="row-label">
        <div className="row-title">{t("settingsWindow.hub.linkStripe")}</div>
        <div className="row-help">{t("settingsWindow.hub.stripeHelp")}</div>
      </div>
      <div className="keys-answer hub-actions">
        <Input
          className="field keys-field"
          type="password"
          autoComplete="off"
          spellCheck={false}
          aria-label={t("settingsWindow.hub.keyField")}
          placeholder={t("settingsWindow.hub.keyPlaceholder")}
          value={key}
          data-hub-key-field=""
          onChange={(event) => setKey(event.target.value)}
        />
        <select
          aria-label={t("settingsWindow.hub.sharing")}
          className={SELECT_CLASS}
          value={sharing}
          data-hub-sharing=""
          onChange={(event) => setSharing(event.target.value === "team" ? "team" : "private")}
        >
          <option value="private">{t("settingsWindow.hub.sharing.private")}</option>
          <option value="team">{t("settingsWindow.hub.sharing.team")}</option>
        </select>
        <Button type="submit" variant="solid" className="button" data-hub-action="linkStripe" disabled={!key || busy}>
          {t("settingsWindow.hub.link")}
        </Button>
      </div>
    </form>
  );
}

function ApprovalRow({ call, busy, onRun }: { call: HubCall; busy: boolean; onRun: Run }) {
  const titleId = useId();
  const id = call.approvalId;
  const details = [call.actionLabel, call.amountText, call.requestedByText, call.expiresText].filter(
    (part): part is string => !!part,
  );
  return (
    <div className="row accounts-row hub-wide" data-hub-approval={id ?? call.id}>
      <div className="row-main">
        <div className="row-label">
          {/* The pinned summary the hub wrote: what the person is approving, word for word. */}
          <div className="row-title selectable" id={titleId} data-hub-approval-line="">
            {call.line}
          </div>
          <div className="row-help selectable">{details.join(" · ")}</div>
          {call.policyText && <div className="row-help selectable">{call.policyText}</div>}
        </div>
      </div>
      {id && (
        <div className="accounts-buttons hub-actions">
          <Button
            variant="solid"
            className="button"
            data-hub-action="allow"
            aria-describedby={titleId}
            disabled={busy}
            onClick={() => void onRun({ action: "approve", id })}
          >
            {t("settingsWindow.hub.allow")}
          </Button>
          <Button
            className="button"
            data-hub-action="remember"
            aria-describedby={titleId}
            disabled={busy}
            onClick={() => void onRun({ action: "approve", id, remember: true })}
          >
            {t("settingsWindow.hub.remember")}
          </Button>
          <Button
            danger
            variant="ghost"
            className="button"
            data-hub-action="deny"
            aria-describedby={titleId}
            disabled={busy}
            onClick={() => void onRun({ action: "deny", id })}
          >
            {t("settingsWindow.hub.deny")}
          </Button>
        </div>
      )}
    </div>
  );
}

function RuleRow({ rule, busy, onRun }: { rule: HubRule; busy: boolean; onRun: Run }) {
  const titleId = useId();
  return (
    <div className="row accounts-row" data-hub-rule={rule.id}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title selectable" id={titleId}>
            {rule.text}
          </div>
          <div className="row-help">
            {rule.remembered ? t("settingsWindow.hub.rule.remembered", rule.ownerLabel) : rule.ownerLabel}
          </div>
        </div>
        {rule.canRemove && (
          <span className="row-control">
            <Button
              danger
              variant="ghost"
              className="button"
              data-hub-action="removeRule"
              aria-describedby={titleId}
              disabled={busy}
              onClick={() => void onRun({ action: "removeRule", id: rule.id })}
            >
              {t("settingsWindow.hub.remove")}
            </Button>
          </span>
        )}
      </div>
    </div>
  );
}

function AddRule({ busy, onRun, onDone }: { busy: boolean; onRun: Run; onDone: () => void }) {
  const [fields, setFields] = useState<HubRuleFields>({ ruleAction: "stripe.refund.create", effect: "ask" });
  const set = (patch: Partial<HubRuleFields>) => setFields((current) => ({ ...current, ...patch }));
  const money = fields.ruleAction.startsWith("stripe.");
  const github = fields.ruleAction.startsWith("github.");
  const submit = (event: FormEvent) => {
    event.preventDefault();
    const rule: HubRuleFields = { ruleAction: fields.ruleAction, effect: fields.effect };
    if (money && fields.amountLte) rule.amountLte = fields.amountLte;
    if (money && fields.currency) rule.currency = fields.currency;
    if (github && fields.repo) rule.repo = fields.repo;
    void onRun({ action: "addRule", ...rule }).then(onDone);
  };
  return (
    <form className="row accounts-row hub-form" data-hub-add-rule="" onSubmit={submit}>
      <div className="row-title">{t("settingsWindow.hub.addRule")}</div>
      <div className="accounts-buttons">
        <select
          aria-label={t("settingsWindow.hub.rule.action")}
          className={SELECT_CLASS}
          value={fields.ruleAction}
          data-hub-rule-action=""
          onChange={(event) => set({ ruleAction: event.target.value })}
        >
          {RULE_ACTIONS.map((entry) => (
            <option key={entry.value} value={entry.value}>
              {t(entry.label)}
            </option>
          ))}
        </select>
        <select
          aria-label={t("settingsWindow.hub.rule.effect")}
          className={SELECT_CLASS}
          value={fields.effect}
          data-hub-rule-effect=""
          onChange={(event) => set({ effect: event.target.value as HubRuleFields["effect"] })}
        >
          <option value="ask">{t("settingsWindow.hub.rule.effect.ask")}</option>
          <option value="allow">{t("settingsWindow.hub.rule.effect.allow")}</option>
          <option value="block">{t("settingsWindow.hub.rule.effect.block")}</option>
        </select>
      </div>
      {money && (
        <div className="accounts-buttons">
          <Input
            className="field hub-field"
            inputMode="numeric"
            aria-label={t("settingsWindow.hub.rule.amountLte")}
            placeholder={t("settingsWindow.hub.rule.amountLte")}
            value={fields.amountLte ?? ""}
            data-hub-rule-amount=""
            onChange={(event) => set({ amountLte: event.target.value })}
          />
          <Input
            className="field hub-field"
            aria-label={t("settingsWindow.hub.rule.currency")}
            placeholder={t("settingsWindow.hub.rule.currency")}
            value={fields.currency ?? ""}
            data-hub-rule-currency=""
            onChange={(event) => set({ currency: event.target.value })}
          />
        </div>
      )}
      {github && (
        <Input
          className="field"
          spellCheck={false}
          aria-label={t("settingsWindow.hub.rule.repo")}
          placeholder={t("settingsWindow.hub.rule.repo")}
          value={fields.repo ?? ""}
          data-hub-rule-repo=""
          onChange={(event) => set({ repo: event.target.value })}
        />
      )}
      <div className="accounts-buttons">
        <Button type="submit" variant="solid" className="button" data-hub-action="saveRule" disabled={busy}>
          {t("settingsWindow.hub.rule.save")}
        </Button>
        <Button type="button" className="button" data-hub-action="cancelRule" onClick={onDone}>
          {t("settingsWindow.hub.cancel")}
        </Button>
      </div>
    </form>
  );
}

export function IntegrationsHubCard() {
  const store = useStore();
  const pauseId = useId();
  const [state, setState] = useState<HubState | null>(null);
  const [busy, setBusy] = useState(false);
  const [addingRule, setAddingRule] = useState(false);
  const refresh = useCallback(async () => {
    setState(await store.runHub({ action: "refresh" }));
  }, [store]);
  useEffect(() => {
    void refresh();
  }, [refresh]);
  const run = useCallback<Run>(
    async (gesture) => {
      setBusy(true);
      try {
        setState(await store.runHub(gesture));
      } finally {
        setBusy(false);
      }
    },
    [store],
  );
  const overview = state?.overview ?? null;
  const ready = overview?.ok === true && overview.available ? overview : null;
  return (
    // One card made of sections, as Settings > Devices: each heading starts its own group, so it
    // keeps the group's spacing from the card above it.
    <div className="hub-card" data-card="integrationsHub">
      <section className="group" data-hub-group="header">
        <div className="group-title">{t("settingsWindow.hub.title")}</div>
        <div className="row-help">{t("settingsWindow.hub.help")}</div>
        <div className="accounts-header">
          <Button
            type="button"
            className="button"
            data-hub-action="refresh"
            disabled={state?.loading ?? false}
            onClick={() => void refresh()}
          >
            {t("settingsWindow.hub.refresh")}
          </Button>
        </div>
        {!state && (
          <div className="row-help" data-hub-checking="">
            {t("settingsWindow.hub.checking")}
          </div>
        )}
        {state?.problem === "unavailable" && (
          <div className="row-error" data-hub-problem="unavailable">
            {t("settingsWindow.hub.problem.unavailable")}
          </div>
        )}
        {overview?.ok === false && (
          <div className="row-error selectable" role="alert" data-hub-problem={overview.error.code}>
            {overview.error.message || t("settingsWindow.hub.problem.failed")}
          </div>
        )}
        {state?.problem === "failed" && !overview && (
          <div className="row-error" data-hub-problem="failed">
            {t("settingsWindow.hub.problem.failed")}
          </div>
        )}
        {overview?.ok === true && !overview.available && (
          <div className="row-help" data-hub-not-here="">
            {overview.message}
          </div>
        )}
        {state?.error && (
          <div className="row-error hub-note selectable" role="alert" data-hub-error={state.error.code}>
            {state.error.message || t("settingsWindow.hub.error.notFinished")}
          </div>
        )}
        {state?.lastCall && (
          <div className="row-help hub-note selectable" data-hub-last-call={state.lastCall.status}>
            {`${state.lastCall.line} · ${state.lastCall.statusLabel}`}
            {state.lastCall.errorText ? ` · ${state.lastCall.errorText}` : ""}
          </div>
        )}
        {ready && (
          <div className="rows hub-note">
            <div className="row accounts-row" data-hub-pause="">
              <div className="row-main">
                <div className="row-label">
                  <div className="row-title" id={pauseId}>
                    {t("settingsWindow.hub.pause")}
                  </div>
                  <div className="row-help">{ready.pausedText}</div>
                </div>
                <span className="row-control">
                  <Switch
                    checked={ready.paused}
                    disabled={busy}
                    labelId={pauseId}
                    onToggle={(paused) => void run({ action: "pause", paused })}
                  />
                </span>
              </div>
            </div>
          </div>
        )}
      </section>

      {ready && (
        <>
          <section className="group" data-hub-group="approvals">
            <div className="group-title" data-hub-heading="approvals">
              {t("settingsWindow.hub.approvals")}
            </div>
            {ready.approvals.length === 0 ? (
              <div className="row-help" data-hub-empty="approvals">
                {t("settingsWindow.hub.noApprovals")}
              </div>
            ) : (
              <div className="rows">
                {ready.approvals.map((call) => (
                  <ApprovalRow key={call.id} call={call} busy={busy} onRun={run} />
                ))}
              </div>
            )}
          </section>

          <section className="group" data-hub-group="accounts">
            <div className="group-title" data-hub-heading="accounts">
              {t("settingsWindow.hub.accounts")}
            </div>
            {ready.connections.length === 0 && (
              <div className="row-help hub-lead" data-hub-empty="accounts">
                {t("settingsWindow.hub.noAccounts")}
              </div>
            )}
            {(ready.connections.length > 0 || !ready.hasStripe || !ready.hasGithub) && (
              <div className="rows">
                {ready.connections.map((row) => (
                  <ConnectionRow key={row.id} row={row} busy={busy} onRun={run} />
                ))}
                {!ready.hasStripe && <LinkStripe busy={busy} onRun={run} />}
                {!ready.hasGithub && (
                  <div className="row accounts-row" data-hub-link="github">
                    <div className="row-main">
                      <div className="row-label">
                        <div className="row-title">{t("settingsWindow.hub.linkGithub")}</div>
                        <div className="row-help">{t("settingsWindow.hub.githubHelp")}</div>
                      </div>
                      <span className="row-control">
                        <Button
                          className="button"
                          data-hub-action="linkGithub"
                          disabled={busy}
                          onClick={() => void run({ action: "link", provider: "github" })}
                        >
                          {t("settingsWindow.hub.link")}
                        </Button>
                      </span>
                    </div>
                  </div>
                )}
              </div>
            )}
          </section>

          <section className="group" data-hub-group="rules">
            <div className="group-title" data-hub-heading="rules">
              {t("settingsWindow.hub.rules")}
            </div>
            {ready.rules.length === 0 && (
              <div className="row-help hub-lead" data-hub-empty="rules">
                {t("settingsWindow.hub.noRules")}
              </div>
            )}
            {(ready.rules.length > 0 || addingRule) && (
              <div className="rows">
                {ready.rules.map((rule) => (
                  <RuleRow key={rule.id} rule={rule} busy={busy} onRun={run} />
                ))}
                {addingRule && <AddRule busy={busy} onRun={run} onDone={() => setAddingRule(false)} />}
              </div>
            )}
            {!addingRule && (
              <div className="accounts-header hub-below">
                <Button className="button" data-hub-action="addRule" onClick={() => setAddingRule(true)}>
                  {t("settingsWindow.hub.addRule")}
                </Button>
              </div>
            )}
          </section>

          <section className="group" data-hub-group="audit">
            <div className="group-title" data-hub-heading="audit">
              {t("settingsWindow.hub.audit")}
            </div>
            {ready.audit.length === 0 ? (
              <div className="row-help" data-hub-empty="audit">
                {t("settingsWindow.hub.noAudit")}
              </div>
            ) : (
              <div className="rows">
                {ready.audit.map((row) => (
                  <div className="row accounts-row" key={row.seq} data-hub-audit={row.seq} data-tone={row.tone}>
                    <div className="row-main">
                      <div className="row-label">
                        <div className="row-title selectable">{row.line}</div>
                        <div className="row-help">{row.whenText}</div>
                      </div>
                      <span className="row-control">
                        <span className="accounts-status devices-status" data-tone={AUDIT_TONE[row.tone]}>
                          <span className="accounts-dot" aria-hidden="true" />
                          {row.eventLabel}
                        </span>
                      </span>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </section>
        </>
      )}
    </div>
  );
}

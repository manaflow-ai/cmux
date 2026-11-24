import React, { useEffect, useId, useRef, useState } from "react";
import { pathName } from "../chips/paths";
import { ChevronRight } from "../conversation/icons";
import { mcpTitleName } from "../conversation/mcpCalls";
import { ShellBlock } from "../conversation/ShellBlock";
import { toolIcon } from "../conversation/toolRowModel";
import { permissionDiffs } from "../permissionMessage";
import { shellCommand } from "../toolActivity";
import { useT, type StringKey } from "../i18n";
import { SHORTCUT_ACTIONS, useShortcut, withShortcut } from "../shortcuts";
import { errorMessage } from "../transportErrors";
import type { PermissionClientState, PermissionDecision, PermissionGroupItem } from "./protocol";
import { permissionKeyAction } from "./prompt";
import { ProposedEdits } from "./ProposedEdits";
import { focusRoute } from "../../../ui/focusRoute";
import { HoldRing } from "./HoldButton";
import { holdButtonProps, holdTitle, useHoldToApprove, type HoldControl } from "./useHoldToApprove";
import { holdApplies, holdSettings } from "./holdToApprove";
import type { HoldScope } from "./holdToApprove.experiment";

/// Each answer's letter, as the single card's (prompt.ts PERMISSION_LETTERS).
const LETTERS: Record<PermissionDecision, string> = { allow_once: "y", allow_chat: "a", deny: "n" };

/// What a receipt says was answered.
const choices: Record<PermissionDecision, StringKey> = {
  allow_once: "permission.allowOnce",
  allow_chat: "permission.allowChat",
  deny: "permission.deny",
};

/// The answers at the end of a waiting ask's row, short, in this order (Leo 2026-10-14).
const answers: [PermissionDecision, StringKey][] = [
  ["allow_once", "permission.allow"],
  ["allow_chat", "permission.always"],
  ["deny", "permission.deny"],
];

/// ACP tool kinds to the verb before what the call names.
const verbs: Partial<Record<string, StringKey>> = {
  execute: "permission.verb.run",
  edit: "permission.verb.edit",
  read: "permission.verb.read",
  delete: "permission.verb.delete",
  move: "permission.verb.move",
  fetch: "permission.verb.fetch",
  search: "permission.verb.search",
};

type Props = {
  state: PermissionClientState;
  /// The chat's turn is running: an answered group's receipt shows only until its turn ends.
  working: boolean;
  onRespond(groupId: string, revision: number, decision: PermissionDecision): void;
  onRetry(): void;
  onRevoke(): void;
  onRefresh(): void;
  /// Hold to approve's scope and hold time, in place of the experiments' (holdToApprove.experiment.ts).
  /// The pane passes none; the gallery and tests do.
  hold?: { scope: HoldScope; durationMs: number; reduced?: boolean };
};

const record = (value: unknown) =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
const text = (value: unknown) => (typeof value === "string" && value.trim() ? value : undefined);

/// What one request asks, as its row names it: what the call does in the agent's words when it
/// says (acpmux's `summary`, a shell call's description), else a verb and the command, path,
/// address or pattern the call carries (in the code face), else the agent's title for it.
function askOf(item: PermissionGroupItem, fallback: string) {
  const request = record(item.request);
  const subject = record(request?.subject);
  const subjectTool = subject?.type === "tool_call" ? record(subject.toolCall) : undefined;
  const subjectCommand = subject?.type === "command" ? subject : undefined;
  const requestTitle = text(request?.title) ?? text(request?.description);
  const tool = record(request?.toolCall) ?? subjectTool;
  const input = record(tool?.rawInput) ?? subjectCommand;
  const kind = text(tool?.kind) ?? (subjectCommand ? "execute" : undefined);
  const paths = (Array.isArray(tool?.locations) ? tool.locations : [])
    .map((location) => text(record(location)?.path))
    .filter((path): path is string => path !== undefined);
  // acpmux's copy drops the line it put before a subagent's command to name the caller.
  const command = kind === "execute" ? (text(item.command) ?? text(shellCommand(input))) : undefined;
  const summary = text(item.summary);
  const path = paths[0] ?? text(input?.file_path) ?? text(input?.path);
  const named =
    kind === "execute"
      ? command
      : kind === "edit" || kind === "read" || kind === "delete" || kind === "move"
        ? path && pathName(path)
        : kind === "fetch"
          ? text(input?.url)
          : kind === "search"
            ? (text(input?.pattern) ?? text(input?.query))
            : undefined;
  return {
    tool,
    kind,
    // The title already says what the call does ("Edit upload.sh"): no verb before it.
    verb: summary === undefined && named !== undefined ? verbs[kind ?? ""] : undefined,
    subject:
      summary ??
      named ??
      (typeof tool?.title === "string" ? mcpTitleName(tool.title) : undefined) ??
      text(subjectCommand?.title) ??
      requestTitle ??
      text(tool?.title) ??
      fallback,
    code: summary === undefined && named !== undefined,
    command,
    cwd: text(input?.cwd),
    scope:
      text(input?.app) ??
      text(input?.application) ??
      text(input?.appName) ??
      paths[0] ??
      text(input?.file_path) ??
      text(input?.path) ??
      text(input?.url) ??
      text(input?.cwd),
    paths,
    input: tool?.rawInput,
  };
}

/// One answer of a waiting group. Under hold to approve (HoldButton.tsx) an allow answers after a
/// held press, never a click; it registers its hold so the panel's keys (y, a, Return) can run it.
function AnswerButton({
  holdKey,
  identity,
  label,
  className,
  keyshortcuts,
  disabled,
  holds,
  durationMs,
  reduced,
  holdDescription,
  onRespond,
  register,
}: {
  holdKey: string;
  /// What a hold answers: the group, its revision and the decision. A hold answers only the identity
  /// it started on, so a new revision or group needs a new press.
  identity: string;
  label: string;
  className: string;
  keyshortcuts?: string;
  disabled: boolean;
  holds: boolean;
  durationMs: number;
  reduced?: boolean;
  holdDescription: string;
  onRespond(): void;
  register(key: string, hold: HoldControl | undefined): void;
}) {
  const hold = useHoldToApprove({
    enabled: holds,
    identity,
    durationMs,
    disabled,
    reducedOverride: reduced,
    onComplete: onRespond,
  });
  useEffect(() => {
    register(holdKey, hold);
    return () => register(holdKey, undefined);
  });
  return (
    <button
      type="button"
      className={className}
      aria-keyshortcuts={keyshortcuts}
      disabled={disabled}
      onClick={onRespond}
      {...(hold ? holdButtonProps(hold, holdDescription) : {})}
      title={hold ? holdTitle(undefined, holdDescription) : undefined}
    >
      {hold && <HoldRing hold={hold} />}
      {label}
    </button>
  );
}

/// One request: a row like the transcript's tool rows (its glyph, verb and what it names, on one
/// line), which opens to the full request in plain words. An edit's proposed change shows under it
/// without opening anything, as the transcript draws an edit (cx-d73v2).
function AskRow({
  item,
  actions,
  expandSignal,
}: {
  item: PermissionGroupItem;
  actions?: React.ReactNode;
  expandSignal: number;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  useEffect(() => {
    if (expandSignal !== 0) setOpen(true);
  }, [expandSignal]);
  const detailsId = useId();
  const ask = askOf(item, t("permission.toolRequest"));
  const diffs = permissionDiffs(ask.tool);
  return (
    <>
      <div className="acpmux-ask-row">
        <button
          type="button"
          className="acpmux-ask-toggle"
          aria-expanded={open}
          aria-controls={open ? detailsId : undefined}
          onClick={() => setOpen((value) => !value)}
        >
          <ChevronRight size={12} className={`acpmux-ask-chevron${open ? " is-open" : ""}`} />
          <span className="acpmux-ask-icon" aria-hidden="true">
            {toolIcon(ask.kind)}
          </span>
          {ask.verb && <span className="acpmux-ask-verb">{t(ask.verb)}</span>}
          <span className={`acpmux-ask-subject${ask.code ? " is-code" : ""}`}>{ask.subject}</span>
          {item.state !== "pending" && (
            <span className="acpmux-ask-state">
              {t(item.state === "cancelled" ? "permission.itemCancelled" : "permission.itemResolved")}
            </span>
          )}
        </button>
        {actions}
      </div>
      {ask.scope && <p className="acpmux-ask-scope">{t("permission.cwd", { path: ask.scope })}</p>}
      {open && (
        <div id={detailsId} className="acpmux-ask-details">
          {ask.command ? (
            // A command waiting to run shows whole: what is approved is never under a fade.
            <ShellBlock command={ask.command} whole />
          ) : ask.input !== undefined ? (
            <pre className="acpmux-ask-input">
              {typeof ask.input === "string" ? ask.input : JSON.stringify(ask.input, null, 2)}
            </pre>
          ) : (
            <p>{t("permission.noInput")}</p>
          )}
          {ask.cwd && <p>{t("permission.cwd", { path: ask.cwd })}</p>}
          {!ask.command && ask.paths.length > 0 && (
            <ul>
              {ask.paths.map((path) => (
                <li key={path}>{path}</li>
              ))}
            </ul>
          )}
          <p>{t("permission.reach")}</p>
        </div>
      )}
      <ProposedEdits permissionId={item.permissionId} diffs={diffs} />
    </>
  );
}

export function PermissionPanel({ state, working, onRespond, onRetry, onRevoke, onRefresh, hold }: Props) {
  const t = useT();
  // Hold to approve (HoldButton.tsx, off unless its experiment is on), read once per panel.
  const [experimentHold] = useState(holdSettings);
  const holdConfig = hold ?? experimentHold;
  /// Each allow button's hold, by `<groupId>:<decision>`, for the panel's keys.
  const holds = useRef(new Map<string, HoldControl>());
  const registerHold = (key: string, control: HoldControl | undefined) => {
    if (control) holds.current.set(key, control);
    else holds.current.delete(key);
  };
  const shortcuts = {
    allow_once: useShortcut(SHORTCUT_ACTIONS.permissionAllowOnce),
    allow_chat: useShortcut(SHORTCUT_ACTIONS.permissionAllowChat),
    deny: useShortcut(SHORTCUT_ACTIONS.permissionDeny),
  } satisfies Record<PermissionDecision, string | undefined>;
  const retryShortcut = useShortcut(SHORTCUT_ACTIONS.permissionRetry);
  const refreshShortcut = useShortcut(SHORTCUT_ACTIONS.permissionRefresh);
  const [expandSignal, setExpandSignal] = useState(0);
  const pendingRef = useRef<typeof state.groups>([]);
  const stateRef = useRef(state);
  stateRef.current = state;
  pendingRef.current = state.groups.filter((group) => group.state === "pending" || group.state === "collecting");
  const callbacks = useRef({ onRespond, onRetry, onRevoke, onRefresh });
  callbacks.current = { onRespond, onRetry, onRevoke, onRefresh };
  const panel = useRef<HTMLElement>(null);
  useEffect(() => {
    const handlers = new Map<string, EventListener>([
      ["permissionAllowOnce", () => respondToPending("allow_once")],
      ["permissionAllowChat", () => respondToPending("allow_chat")],
      ["permissionDeny", () => respondToPending("deny")],
      ["permissionRetry", runRetry],
      ["permissionRevoke", runRevoke],
      ["permissionRefresh", runRefresh],
      ["permissionExpand", () => setExpandSignal((value) => value + 1)],
    ]);
    /// The pending group `decision` would answer now, if any.
    function pendingFor(decision: PermissionDecision) {
      const current = stateRef.current;
      if (!current.supported || current.busy || current.loading || current.ready === false || current.uncertain)
        return undefined;
      if (decision !== "deny" && current.allowRefused) return undefined;
      return pendingRef.current.find(
        (candidate) => candidate.state === "pending" && candidate.decisions.includes(decision),
      );
    }
    /// Whether a pending group took `decision`. `event` is the key that asked, absent for an app
    /// shortcut's page event: under hold to approve a held key runs the button's hold, and a page
    /// event, which cannot be held, puts the keyboard on the button.
    function respondToPending(decision: PermissionDecision, event?: KeyboardEvent): boolean {
      const group = pendingFor(decision);
      if (!group) return false;
      const hold = holds.current.get(`${group.groupId}:${decision}`);
      if (hold) {
        if (event) hold.holdKey(event);
        else focusRoute(hold.ref.current, "person", "an app allow shortcut under hold to approve");
        return true;
      }
      callbacks.current.onRespond(group.groupId, group.revision, decision);
      return true;
    }
    // The single card's keys (prompt.ts permissionKeyAction): y, a and n, Return and Esc, with
    // nothing focused, focus in the panel or in an empty composer. Capture, as the card's.
    const onKey = (event: KeyboardEvent) => {
      const action = permissionKeyAction(event, panel.current, false);
      if (!action || action === "closeFeedback") return;
      if (!respondToPending(action === "allow_always" ? "allow_chat" : action, event)) return;
      event.preventDefault();
      event.stopPropagation();
    };
    document.addEventListener("keydown", onKey, true);
    function runRetry() {
      const current = stateRef.current;
      if (current.supported && current.uncertain && !current.busy && !current.loading) callbacks.current.onRetry();
    }
    function runRevoke() {
      const current = stateRef.current;
      if (
        current.supported &&
        current.chatAllowance &&
        current.ready !== false &&
        !current.busy &&
        !current.loading &&
        !current.uncertain
      )
        callbacks.current.onRevoke();
    }
    function runRefresh() {
      const current = stateRef.current;
      if (current.supported && !!current.error && !current.busy && !current.loading) callbacks.current.onRefresh();
    }
    for (const [name, handler] of handlers) window.addEventListener(`cmux-acpmux-${name}`, handler);
    return () => {
      document.removeEventListener("keydown", onKey, true);
      for (const [name, handler] of handlers) window.removeEventListener(`cmux-acpmux-${name}`, handler);
    };
  }, []);
  // The answered group whose turn has ended: its receipt left the chat with that turn, and a later
  // turn that asks nothing does not bring it back (cx-1lq0s).
  const last = state.groups.at(-1);
  const answered = last && last.state !== "pending" && last.state !== "collecting" ? last.groupId : undefined;
  const [ended, setEnded] = useState<string>();
  useEffect(() => {
    if (!working && answered) setEnded(answered);
  }, [working, answered]);
  if (!state.supported) return null;
  const pending = state.groups.filter((group) => group.state === "pending" || group.state === "collecting");
  const receipt = pending.length === 0 && working && answered !== ended ? last : undefined;
  if (!pending.length && !receipt && !state.error) return null;
  const disabled = state.busy || state.loading || state.ready === false || !!state.uncertain;
  // The group the keys answer (respondToPending): the first one waiting, whose answers list the
  // letters. No keycap is drawn: the pending command is one quiet row (Leo 2026-10-14), its answers small.
  const keyed = pending.find((group) => group.state === "pending");
  // acpmux refuses this reader's group allows (a chat on another machine, whose daemon allows only
  // from its own app): no Allow or Always that cannot count, and the reason in plain words.
  const allowRefused = state.allowRefused
    ? errorMessage({ reason: state.allowRefused }) || t("transport.personRequired")
    : undefined;
  return (
    <section
      ref={panel}
      className="acpmux-permission acpmux-permission-panel"
      aria-label={t("permission.title")}
      aria-busy={state.busy}
    >
      {pending.map((group) => {
        const groupHolds = holdApplies(
          holdConfig.scope,
          group.items.map((item) => {
            const ask = askOf(item, "");
            return { kind: ask.kind, command: ask.command };
          }),
        );
        const buttons =
          group.state === "pending" ? (
            <div className="acpmux-ask-actions">
              {answers
                .filter(([decision]) => group.decisions.includes(decision) && (!allowRefused || decision === "deny"))
                .map(([decision, label]) => (
                  <AnswerButton
                    key={decision}
                    holdKey={`${group.groupId}:${decision}`}
                    identity={`${group.groupId}\u0000${group.revision}\u0000${decision}`}
                    label={t(label)}
                    className={`acpmux-ask-action${decision === "allow_once" ? " is-primary" : decision === "allow_chat" ? " is-secondary" : ""}`}
                    keyshortcuts={
                      [group === keyed && LETTERS[decision], shortcuts[decision]].filter(Boolean).join(" ") || undefined
                    }
                    disabled={disabled}
                    holds={groupHolds && decision !== "deny"}
                    durationMs={holdConfig.durationMs}
                    reduced={hold?.reduced}
                    holdDescription={t("permission.holdToAllow")}
                    onRespond={() => onRespond(group.groupId, group.revision, decision)}
                    register={registerHold}
                  />
                ))}
            </div>
          ) : undefined;
        return (
          <fieldset
            className="acpmux-ask acpmux-permission-surface"
            aria-label={t("permission.title")}
            key={group.groupId}
          >
            {group.items.map((item, index) => (
              <AskRow
                key={item.permissionId}
                item={item}
                actions={index === 0 ? buttons : undefined}
                expandSignal={expandSignal}
              />
            ))}
            {group.state === "collecting" && <output className="acpmux-ask-note">{t("permission.collecting")}</output>}
            {/* What Always grants, in view while it can be chosen: hidden behind the row, the
                bigger grant read as the same as Allow (cg-design-judge, 0-16 blind bouts). */}
            {group.state === "pending" && allowRefused && <output className="acpmux-ask-note">{allowRefused}</output>}
            {group.state === "pending" && !allowRefused && group.decisions.includes("allow_chat") && (
              <output className="acpmux-ask-note">{t("permission.alwaysScope")}</output>
            )}
            {group.state === "pending" && !allowRefused && !group.decisions.includes("allow_once") && (
              <output className="acpmux-ask-note">{t("permission.denyOnly")}</output>
            )}
          </fieldset>
        );
      })}
      {receipt && (
        <details className="acpmux-permission-receipt">
          <summary>
            {receipt.state === "cancelled"
              ? t("permission.cancelled")
              : receipt.decision
                ? t(choices[receipt.decision])
                : t("permission.answered")}
          </summary>
          {receipt.items.map((item) => (
            <AskRow key={item.permissionId} item={item} expandSignal={expandSignal} />
          ))}
        </details>
      )}
      {state.error && (
        <div className="acpmux-permission-error" role="alert">
          <span>{state.error}</span>
          <button disabled={state.busy || state.loading} onClick={state.uncertain ? onRetry : onRefresh}>
            {withShortcut(
              state.uncertain ? t("permission.checkRetry") : t("permission.refresh"),
              state.uncertain ? retryShortcut : refreshShortcut,
            )}
          </button>
        </div>
      )}
    </section>
  );
}

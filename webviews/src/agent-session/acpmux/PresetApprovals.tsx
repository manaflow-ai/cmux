// "Unattended runs" on a new chat's home: the presets a fleet lane may run under with no one there
// to answer its asks (Leo, 2026-11-09, on a no-prompt preset approved once in the cmux app so
// handed-off sessions run without anyone watching: "yeah we should have that too"). acpmux lists
// them (`_acpmux/preset_approvals`); a preset someone tried to dispatch while it was not approved
// waits here with an Approve, which takes a second, plainly worded click. An approved one shows who
// approved it and its runs, with Revoke. One that cannot be carried to another machine exactly
// says why and offers nothing. The card reads when it mounts and after each approve or revoke; a
// switch away and back reads nothing (plans/cmux-next/shared-projections.md), and it never polls.
// An acpmux without the method, or no presets, draws nothing.
import { useCallback, useEffect, useRef, useState } from "react";

import { AgentMark } from "../shared/AgentMark";
import { agentDisplayName } from "./agents";
import { age } from "./homeListsModel";
import { type Translate, useT } from "./i18n";
import {
  BLOCKED_OTHER,
  BLOCKED_WORDS,
  CONFIRM_OTHER,
  CONFIRM_WORDS,
  ERROR_OTHER,
  ERROR_WORDS,
  NO_PRESET_APPROVALS,
  POLICY_OTHER,
  POLICY_WORDS,
  type PresetApprovals as PresetApprovalsList,
  type PresetApprovalsClient,
  type PresetRow,
  methodMissing,
  presetApprovals,
  presetRow,
  presetState,
  refusalReason,
  withRow,
} from "./presetApprovalsModel";

/// How the card lays a preset out: an inbox row with its details and answers under it (`list`,
/// the home's), one line per preset with its button at its end (`compact`), or a card with every
/// detail on its own line (`card`). The gallery shows all three.
export type PresetApprovalsLook = "list" | "compact" | "card";

export function PresetApprovals({
  client,
  look = "list",
  now = Date.now(),
}: {
  /// The pane's acpmux connection; none draws nothing.
  client?: PresetApprovalsClient;
  look?: PresetApprovalsLook;
  now?: number;
}) {
  const t = useT();
  const [list, setList] = useState<PresetApprovalsList>(NO_PRESET_APPROVALS);
  // Each read's turn: a slower, older reply never replaces a newer one.
  const turn = useRef(0);
  const read = useCallback(() => {
    if (!client) return;
    const mine = ++turn.current;
    let reply: Promise<unknown>;
    try {
      reply = Promise.resolve(client.presetApprovals());
    } catch (error) {
      reply = Promise.reject(error);
    }
    reply.then(
      (value) => {
        if (mine === turn.current) setList(presetApprovals(value));
      },
      (error) => {
        // An acpmux without the method has none to show; any other failure keeps what was read.
        if (mine === turn.current && methodMissing(error)) setList(NO_PRESET_APPROVALS);
      },
    );
  }, [client]);
  useEffect(() => {
    read();
    return () => {
      turn.current += 1;
    };
  }, [read]);
  if (!client || list.presets.length === 0) return null;
  const waiting = list.presets.filter((row) => presetState(row) === "needs").length;
  const label = t("presetApprovals.title");
  return (
    <div className="acpmux-home">
      <section className="acpmux-home-list acpmux-home-inbox acpmux-presets" data-look={look} aria-label={label}>
        <h3 className="acpmux-home-label">
          {label}
          {waiting > 0 && <span className="acpmux-home-inbox-count">{waiting}</span>}
        </h3>
        <ul>
          {list.presets.map((row) => (
            <PresetItem
              key={row.name}
              row={row}
              machines={list.machines}
              look={look}
              now={now}
              client={client}
              onRow={(next) => setList((before) => withRow(before, next))}
              reread={read}
            />
          ))}
        </ul>
      </section>
    </div>
  );
}

function PresetItem({
  row,
  machines,
  look,
  now,
  client,
  onRow,
  reread,
}: {
  row: PresetRow;
  machines: readonly string[];
  look: PresetApprovalsLook;
  now: number;
  client: PresetApprovalsClient;
  onRow(row: PresetRow): void;
  reread(): void;
}) {
  const t = useT();
  const [confirming, setConfirming] = useState(false);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string>();
  // Set before the request goes out, so a second click in the same tick sends nothing.
  const inFlight = useRef(false);
  // The digest the confirm was shown for: contents that changed since need a new first click.
  const [shownDigest, setShownDigest] = useState(row.digest);
  if (shownDigest !== row.digest) {
    setShownDigest(row.digest);
    setConfirming(false);
  }
  const state = presetState(row);
  const harness = agentDisplayName(row.harness);
  // Sent straight from the click, no await before it: the host takes it only on a fresh gesture.
  const send = (approve: boolean) => {
    if (inFlight.current) return;
    inFlight.current = true;
    setSending(true);
    setError(undefined);
    let reply: Promise<unknown>;
    try {
      reply = Promise.resolve(client.presetApprove(row.name, approve, approve ? row.digest : undefined));
    } catch (failure) {
      reply = Promise.reject(failure);
    }
    reply.then(
      (value) => {
        inFlight.current = false;
        setSending(false);
        setConfirming(false);
        const next = presetRow(value);
        if (next) onRow(next);
        reread();
      },
      (failure) => {
        inFlight.current = false;
        setSending(false);
        const reason = refusalReason(failure);
        setError(reason && ERROR_WORDS[reason] ? t(ERROR_WORDS[reason]!) : t(ERROR_OTHER));
        // The preset changed since the card read it: read it again, so its new contents show.
        if (reason === "preset_approval.changed") {
          setConfirming(false);
          reread();
        }
      },
    );
  };
  const runs = [harness, row.model, row.effort].filter(Boolean).join(" · ");
  const policy = POLICY_WORDS[row.policy] ? t(POLICY_WORDS[row.policy]!) : t(POLICY_OTHER, { policy: row.policy });
  const where = machines.length
    ? t("presetApprovals.where", { machines: machines.join(", ") })
    : t("presetApprovals.whereNone");
  const tried = askLine(row, now, t);
  const approvedLine = row.approval
    ? [
        t("presetApprovals.approvedBy", { by: row.approval.by, host: row.approval.host }),
        row.runs > 0 ? t("presetApprovals.runs", { n: row.runs }) : t("presetApprovals.noRuns"),
        row.lastRun ? t("presetApprovals.lastRun", { age: age(row.lastRun.at, now, t) ?? "" }) : undefined,
      ]
        .filter(Boolean)
        .join(" · ")
    : undefined;
  const blocked = row.blocked
    ? BLOCKED_WORDS[row.blocked]
      ? t(BLOCKED_WORDS[row.blocked]!)
      : t(BLOCKED_OTHER, { reason: row.blocked })
    : undefined;
  // What the row says under its name, by look: a compact line keeps only what tells it apart.
  const lines =
    state === "approved"
      ? [approvedLine]
      : state === "blocked"
        ? look === "compact"
          ? [blocked]
          : [`${runs} · ${policy}`, blocked]
        : look === "compact"
          ? [`${runs} · ${policy}`]
          : [`${runs} · ${policy}`, where, tried];
  const title = row.description && look === "list" ? `${row.name} — ${row.description}` : row.name;
  return (
    <li
      className="acpmux-home-inbox-row acpmux-presets-row"
      data-state={state}
      data-confirming={confirming ? "" : undefined}
      data-sending={sending ? "" : undefined}
    >
      <div className="acpmux-home-inbox-open acpmux-presets-head">
        <span className="acpmux-home-inbox-mark">
          <AgentMark agent={row.harness} size={14} reserve />
        </span>
        <span className="acpmux-home-inbox-text">
          <span className="acpmux-home-inbox-ask" title={title}>
            {title}
          </span>
          {look === "card" && row.description && <span className="acpmux-presets-description">{row.description}</span>}
          {lines.filter(Boolean).map((line, index) => (
            <span
              key={index}
              className={index === 0 ? "acpmux-home-inbox-detail" : "acpmux-home-inbox-where"}
              data-blocked={line === blocked ? "" : undefined}
              title={line}
            >
              {line}
            </span>
          ))}
        </span>
      </div>
      {state === "needs" && !confirming && (
        <div className="acpmux-home-inbox-answers">
          <button type="button" data-tone="allow" disabled={sending} onClick={() => setConfirming(true)}>
            {t("presetApprovals.approve")}
          </button>
        </div>
      )}
      {state === "needs" && confirming && (
        <fieldset className="acpmux-presets-confirm" aria-label={t("presetApprovals.confirmLabel")}>
          <p className="acpmux-presets-consequence">
            {t(CONFIRM_WORDS[row.policy] ?? CONFIRM_OTHER, { name: row.name, policy: row.policy })}{" "}
            {t("presetApprovals.withdraw")} {t("presetApprovals.guards", { harness })}
          </p>
          {look === "compact" && <p className="acpmux-presets-consequence">{where}</p>}
          <div className="acpmux-home-inbox-answers">
            <button
              type="button"
              data-tone="allow"
              disabled={sending}
              aria-busy={sending}
              onClick={(event) => {
                // The second click of a double-click on Approve is not a confirmation.
                if (event.detail > 1) return;
                send(true);
              }}
            >
              {t("presetApprovals.confirmApprove")}
            </button>
            <button type="button" disabled={sending} onClick={() => setConfirming(false)}>
              {t("presetApprovals.cancel")}
            </button>
          </div>
        </fieldset>
      )}
      {state === "approved" && (
        <div className="acpmux-home-inbox-answers">
          <button type="button" disabled={sending} aria-busy={sending} onClick={() => send(false)}>
            {t("presetApprovals.revoke")}
          </button>
        </div>
      )}
      {error && (
        <p className="acpmux-home-inbox-error" role="alert">
          {error}
        </p>
      )}
    </li>
  );
}

/// Who tried the preset last, on which machine and how long ago, and how many tries before it.
function askLine(row: PresetRow, now: number, t: Translate): string | undefined {
  const [newest, ...older] = row.asks;
  if (!newest) return undefined;
  const when = age(newest.at, now, t) ?? "";
  const host = newest.host ?? "";
  const line = newest.from
    ? t("presetApprovals.asked", { from: newest.from, host, age: when })
    : t("presetApprovals.askedNoFrom", { host, age: when });
  return older.length ? `${line} ${t("presetApprovals.moreAsks", { n: older.length })}` : line;
}

export type { PresetApprovalsClient } from "./presetApprovalsModel";

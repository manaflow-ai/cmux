// Waiting on you (History > Waiting on you): every approval, plan, question and pull request that
// waits on the person, across agents and machines, highest score first (queueModel.ts). Keyboard
// first: j/k or the arrows move, Return goes to the chat, `x` copies the audit trail, and the app's
// permission shortcuts (Allow Once, Deny) answer the selected row: allow or deny once, or accept a
// pull request or ask for changes on one. A plain letter never answers: a permission answer needs
// the person's click or that shortcut, which the host counts as theirs (AgentPaneUserGestures). A
// question opens its chat, whose card asks the whole of it. An answer goes the way Needs you sends
// it; its row leaves in the frame the person decides and closes up over the house settle, and a
// refusal brings it back with the reason under it.
import React, { memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { age } from "../homeListsModel";
import { useT, type Translate } from "../i18n";
import { Keycap } from "../Keycap";
import { AgentMark } from "../NewTabPage";
import type { NeedsYouAnswer } from "../needsYou/model";
import { formatCost } from "../ledger/ledgerModel";
import { SHORTCUT_ACTIONS, useShortcut } from "../shortcuts";
import { queueAnswers, queueCommand, queueReasons, type QueueItem, type QueueReason } from "./queueModel";
import { useQueue, type QueueCache } from "./useQueue";
import "./queue.css";

/// How a row reads (gallery `agent-pane.review-queue`): `inbox` two lines with the answers on the
/// selected row (shipped), `cards` every row a card with its answers and detail showing, `compact`
/// one line each.
export type QueueLook = "inbox" | "cards" | "compact";

export type QueueActions = {
  /// `_acpmux/review_queue` (direct.ts `reviewQueue`).
  load(): Promise<unknown>;
  /// One answer, the way Needs you sends it (needsYou/useNeedsYou.ts `answerAnotherChat`):
  /// "opened" when the chat had to take it instead.
  answer(item: QueueItem, choice: NeedsYouAnswer): Promise<"answered" | "opened">;
  /// A pull request's verdict (`_acpmux/review_verdict`).
  verdict(item: QueueItem, verdict: "accept" | "changes", comment?: string): Promise<unknown>;
  /// Shows the item's chat in this tab, as History's own rows open one (`chat.select`).
  open(item: QueueItem): void;
  /// Copies the audit trail (`_acpmux/audit`); resolves to how many entries it copied.
  exportAudit(): Promise<number>;
  /// The Review queue of code changes, where there is one.
  openReview?(): void;
};

type Props = QueueActions & {
  /// Changes whenever the asks acpmux reports change, so the queue reads again.
  refreshKey?: string;
  look?: QueueLook;
  now?: number;
  /// History's copy of the last answer, so a return to the tab shows it without a read.
  cache?: QueueCache;
};

/// `detail`: words the person wrote that reached nowhere, shown whole so they can copy them.
type Notice = { tone: "ok" | "error"; text: string };

const NO_ITEMS: QueueItem[] = [];
const rowId = (id: string) => `wq-row-${id.replace(/[^A-Za-z0-9_-]/g, "_")}`;

export function QueueScreen({
  load,
  answer,
  verdict,
  open,
  exportAudit,
  openReview,
  refreshKey = "",
  look = "inbox",
  now,
  cache,
}: Props) {
  const t = useT();
  const { state, refresh } = useQueue(load, refreshKey, cache);
  /// Items the person answered here that acpmux may still list: hidden until a read drops them.
  const [answered, setAnswered] = useState<ReadonlySet<string>>(() => new Set());
  const [failures, setFailures] = useState<ReadonlyMap<string, string>>(() => new Map());
  const [selected, setSelected] = useState<string | undefined>();
  const [comment, setComment] = useState<{ id: string; text: string } | undefined>();
  const [notice, setNotice] = useState<Notice | undefined>();
  /// A comment neither the chat nor the clipboard took: its only copy, kept (in History's cache
  /// too) until the person dismisses it, whatever notice comes after.
  const [unsent, setUnsentState] = useState<string | undefined>(() => cache?.unsent());
  const setUnsent = useCallback(
    (next: string | undefined) => {
      cache?.keepUnsent(next);
      setUnsentState(next);
    },
    [cache],
  );
  const lastIndex = useRef(0);
  const list = useRef<HTMLDivElement>(null);

  const reply = "reply" in state ? state.reply : undefined;
  const all = useMemo(() => reply?.items ?? NO_ITEMS, [reply]);
  const items = useMemo(() => all.filter((item) => !answered.has(item.id)), [all, answered]);
  // The rows the first read listed are there at once; a row that arrives later enters.
  const firstRead = useRef<ReadonlySet<string> | undefined>(undefined);
  if (reply && !firstRead.current) firstRead.current = new Set(reply.items.map((item) => item.id));
  // A read that no longer lists an answered item lets it go from the hidden set.
  useEffect(() => {
    if (!reply) return;
    setAnswered((previous) => {
      if (previous.size === 0) return previous;
      const listed = new Set(reply.items.map((item) => item.id));
      const next = new Set([...previous].filter((id) => listed.has(id)));
      return next.size === previous.size ? previous : next;
    });
  }, [reply]);

  const found = items.findIndex((item) => item.id === selected);
  const index = items.length === 0 ? -1 : found >= 0 ? found : Math.min(lastIndex.current, items.length - 1);
  const current = index >= 0 ? items[index] : undefined;
  useLayoutEffect(() => {
    if (index >= 0) lastIndex.current = index;
  });
  useEffect(() => {
    list.current?.focus({ preventScroll: true });
  }, []);
  useEffect(() => {
    if (current) document.getElementById(rowId(current.id))?.scrollIntoView({ block: "nearest" });
  }, [current]);

  const settle = useCallback(
    (item: QueueItem, run: () => Promise<unknown>, failed: string, refused?: () => void) => {
      setAnswered((previous) => new Set(previous).add(item.id));
      setFailures((previous) => without(previous, item.id));
      run().then(
        (outcome) => {
          // The chat took it instead: the row comes back until acpmux says it was answered.
          if (outcome === "opened") setAnswered((previous) => withoutId(previous, item.id));
          refresh();
        },
        () => {
          setAnswered((previous) => withoutId(previous, item.id));
          setFailures((previous) => new Map(previous).set(item.id, failed));
          refused?.();
        },
      );
    },
    [refresh],
  );

  const give = useCallback(
    (item: QueueItem, choice: NeedsYouAnswer | undefined) => {
      if (!choice) return false;
      settle(item, () => answer(item, choice), t("waiting.answerFailed"));
      return true;
    },
    [answer, settle, t],
  );

  const sendVerdict = useCallback(
    (item: QueueItem, kind: "accept" | "changes", text?: string) => {
      // The box closes with the row; a refused verdict brings both back with what was typed, so
      // the person never writes the request again.
      setComment(undefined);
      setNotice(undefined);
      settle(
        item,
        async () => {
          const reply = await verdict(item, kind, text);
          // The chat did not get the words: say where they went (historyPages.ts `verdict`).
          const copied = (reply as { commentCopied?: unknown } | null)?.commentCopied;
          if (copied === true) setNotice({ tone: "ok", text: t("waiting.commentCopied") });
          // Neither the chat nor the clipboard took it: the words stay on the page to copy by hand,
          // after any earlier ones still kept.
          else if (copied === false && text) {
            const kept = cache?.unsent();
            setUnsent(kept ? `${kept}\n\n${text}` : text);
          }
          return reply;
        },
        t("waiting.answerFailed"),
        text === undefined ? undefined : () => setComment({ id: item.id, text }),
      );
      list.current?.focus({ preventScroll: true });
    },
    [settle, verdict, t, cache, setUnsent],
  );

  const runExport = useCallback(() => {
    setNotice(undefined);
    exportAudit().then(
      (n) => setNotice({ tone: "ok", text: t("waiting.exported", { n }) }),
      () => setNotice({ tone: "error", text: t("waiting.exportFailed") }),
    );
  }, [exportAudit, t]);

  const move = (step: number) => {
    const next = items[Math.max(0, Math.min(items.length - 1, index + step))];
    if (next) setSelected(next.id);
  };

  const onKeyDown = (event: React.KeyboardEvent) => {
    if (event.target !== event.currentTarget || event.nativeEvent.isComposing) return;
    const command = queueCommand(event);
    if (!command) return;
    const handled = (() => {
      if (command.kind === "export") {
        runExport();
        return true;
      }
      if (command.kind === "move") {
        move(command.step);
        return true;
      }
      if (!current) return false;
      open(current);
      return true;
    })();
    if (handled) event.preventDefault();
  };

  // The app's permission shortcuts reach the page as events once the host counted the key as the
  // person's (AgentPaneView+Commands `runPermissionAction`); they answer the selected row.
  const shortcut = useRef<(kind: "allow" | "deny") => void>(() => undefined);
  shortcut.current = (kind) => {
    if (!current || current.host) return;
    if (current.kind === "pr") {
      if (kind === "allow") sendVerdict(current, "accept");
      else setComment({ id: current.id, text: "" });
      return;
    }
    // An ask with no single-use answer of that kind (only a lasting grant, or a question) is
    // answered in its chat: the shortcut opens it rather than doing nothing.
    if (
      !give(
        current,
        queueAnswers(current).find((each) => each.tone === kind),
      )
    )
      open(current);
  };
  useEffect(() => {
    const events = [
      ["cmux-acpmux-permissionAllowOnce", () => shortcut.current("allow")],
      ["cmux-acpmux-permissionDeny", () => shortcut.current("deny")],
    ] as const;
    for (const [event, handler] of events) window.addEventListener(event, handler);
    return () => {
      for (const [event, handler] of events) window.removeEventListener(event, handler);
    };
  }, []);
  const allowKey = useShortcut(SHORTCUT_ACTIONS.permissionAllowOnce);
  const denyKey = useShortcut(SHORTCUT_ACTIONS.permissionDeny);

  const status =
    state.phase === "older"
      ? t("waiting.older")
      : state.phase === "failed" && !reply
        ? t("waiting.failed")
        : state.phase === "loading" && !reply
          ? t("waiting.loading")
          : items.length === 0
            ? t("waiting.empty")
            : // A read that failed while rows show: the rows stay, and the line says they may be old.
              state.phase === "failed"
              ? t("waiting.failed")
              : "";
  // acpmux cut the list at the read's limit: say how many more wait (`total` counts them all).
  const more = reply && reply.total > reply.items.length ? reply.total : undefined;

  return (
    <div className="wq" data-look={look}>
      <div className="wq-head">
        <span className="wq-fill" />
        {openReview && (
          <button type="button" className="wq-link" onClick={openReview}>
            {t("waiting.codeChanges")}
          </button>
        )}
        <button type="button" className="wq-link" onClick={runExport} aria-keyshortcuts="x">
          {t("waiting.export")}
        </button>
      </div>
      {/* The keys belong to the whole list (j/k, Return, x), so the list takes the focus
          and the selected row is marked current; each row's own buttons stay real buttons. */}
      {/* oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- the keyboard surface of the list below */}
      <div
        ref={list}
        className="wq-list"
        // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- one Tab stop for the list's keys
        tabIndex={0}
        aria-keyshortcuts="j k Enter x"
        onKeyDown={onKeyDown}
      >
        <ul className="wq-rows" aria-label={t("waiting.title")}>
          {/* An answered row stays until acpmux drops it, collapsed: it leaves over the settle and the
            rows below close up with it, never in a jump. */}
          {all.map((item) => (
            <Row
              key={item.id}
              item={item}
              leaving={answered.has(item.id)}
              enters={!firstRead.current?.has(item.id)}
              look={look}
              now={now ?? reply?.now}
              selected={item === current}
              failure={failures.get(item.id)}
              comment={comment?.id === item.id ? comment.text : undefined}
              onSelect={setSelected}
              onOpen={open}
              onAnswer={give}
              allowKey={allowKey}
              denyKey={denyKey}
              onVerdict={sendVerdict}
              onComment={setComment}
              onCancel={() => {
                setComment(undefined);
                list.current?.focus({ preventScroll: true });
              }}
            />
          ))}
        </ul>
        {/* One status line, always the same height, so the list never moves when a read lands. */}
        <div className="wq-status" aria-live="polite">
          {status}
          {more !== undefined && (
            <span className="wq-meta">{t("waiting.more", { shown: reply!.items.length, total: more })}</span>
          )}
          {state.phase === "failed" && (
            <button type="button" className="wq-link" onClick={refresh}>
              {t("waiting.retry")}
            </button>
          )}
          {reply && reply.peersOmitted.length > 0 && (
            <span className="wq-meta">{t("waiting.peersOmitted", { hosts: reply.peersOmitted.join(", ") })}</span>
          )}
        </div>
      </div>
      <div className="wq-foot">
        <div className="wq-keys">
          <span>
            <Keycap>j</Keycap>
            <Keycap>k</Keycap>
            {t("waiting.key.move")}
          </span>
          <span>
            <Keycap>↩</Keycap>
            {t("waiting.key.open")}
          </span>
          {allowKey && (
            <span>
              <Keycap>{allowKey}</Keycap>
              {t("waiting.key.allow")}
            </span>
          )}
          {denyKey && (
            <span>
              <Keycap>{denyKey}</Keycap>
              {t("waiting.key.deny")}
            </span>
          )}
          <span>
            <Keycap>x</Keycap>
            {t("waiting.key.export")}
          </span>
        </div>
        {unsent !== undefined && (
          <div className="wq-unsent" role="alert">
            <span className="wq-unsent-text">{t("waiting.commentNotCopied")}</span>
            <span className="wq-notice-detail">{unsent}</span>
            <button type="button" className="wq-link" onClick={() => setUnsent(undefined)}>
              {t("waiting.dismissComment")}
            </button>
          </div>
        )}
        <output className="wq-notice" data-tone={notice?.tone}>
          {notice?.text ?? ""}
        </output>
      </div>
    </div>
  );
}

function without<V>(map: ReadonlyMap<string, V>, key: string): ReadonlyMap<string, V> {
  if (!map.has(key)) return map;
  const next = new Map(map);
  next.delete(key);
  return next;
}

function withoutId(set: ReadonlySet<string>, id: string): ReadonlySet<string> {
  if (!set.has(id)) return set;
  const next = new Set(set);
  next.delete(id);
  return next;
}

export function reasonText(reason: QueueReason, t: Translate): string {
  switch (reason.kind) {
    case "blocksTurn":
      return t("waiting.reason.blocksTurn");
    case "queuedPrompts":
      return t("waiting.reason.queuedPrompts", { n: reason.n });
    case "subsessions":
      return t("waiting.reason.subsessions", { n: reason.n });
    case "costUsd":
      return t("waiting.reason.costUsd", { cost: formatCost(reason.usd, document.documentElement.lang || undefined) });
    case "age":
      return t("waiting.reason.age");
  }
}

type RowProps = {
  item: QueueItem;
  leaving: boolean;
  enters: boolean;
  look: QueueLook;
  now?: number;
  selected: boolean;
  failure?: string;
  comment?: string;
  onSelect(id: string): void;
  onOpen(item: QueueItem): void;
  onAnswer(item: QueueItem, choice: NeedsYouAnswer): boolean;
  /// The app's Allow Once and Deny shortcuts, shown on the selected row's answers.
  allowKey?: string | undefined;
  denyKey?: string | undefined;
  onVerdict(item: QueueItem, verdict: "accept" | "changes", comment?: string): void;
  onComment(comment: { id: string; text: string } | undefined): void;
  onCancel(): void;
};

/// One item. Memoized: moving the cursor redraws the two rows it leaves and enters, whatever the
/// number of items.
const Row = memo(function Row({
  item,
  leaving,
  enters,
  look,
  now,
  selected,
  failure,
  comment,
  onSelect,
  onOpen,
  onAnswer,
  allowKey,
  denyKey,
  onVerdict,
  onComment,
  onCancel,
}: RowProps) {
  const t = useT();
  const answers = queueAnswers(item);
  const reasons = queueReasons(item);
  const when = age(item.at, now, t);
  const where = item.host ?? t("waiting.thisMac");
  const showsAnswers = look === "cards" || selected;
  const acceptKey = selected ? allowKey : undefined;
  const changesKey = selected ? denyKey : undefined;
  return (
    // oxlint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-noninteractive-element-interactions -- a click picks the row; the list owns the keys (j/k, Return)
    <li
      id={rowId(item.id)}
      className="wq-row"
      aria-current={(selected && !leaving) || undefined}
      aria-hidden={leaving || undefined}
      data-selected={(selected && !leaving) || undefined}
      data-leaving={leaving || undefined}
      data-enters={enters || undefined}
      data-kind={item.kind}
      onClick={() => onSelect(item.id)}
      onDoubleClick={(event) => {
        // A double click in the comment box selects a word; only the row's own text opens the chat.
        if ((event.target as Element).closest?.("textarea, input, button, a")) return;
        onOpen(item);
      }}
    >
      <div className="wq-row-inner">
        <span className="wq-mark" aria-hidden="true">
          <AgentMark harness={item.harness} />
        </span>
        <div className="wq-body">
          <div className="wq-line">
            <span className="wq-kind">{t(`waiting.kind.${item.kind}`)}</span>
            <span className="wq-ask">{item.ask || item.title}</span>
            <span className="wq-fill" />
            {when && <span className="wq-meta wq-age">{when}</span>}
          </div>
          {look !== "compact" && (
            <div className="wq-line wq-sub">
              <span className="wq-who">{item.title}</span>
              <span className="wq-meta">{where}</span>
              {item.vendor && <span className="wq-meta">{item.vendor}</span>}
              {reasons.map((reason) => (
                <span key={reason.kind} className="wq-reason" data-reason={reason.kind}>
                  {reasonText(reason, t)}
                </span>
              ))}
            </div>
          )}
          {look !== "compact" && item.detail && (look === "cards" || item.kind === "plan" || selected) && (
            <div className="wq-detail" data-plan={item.kind === "plan" || undefined}>
              {item.detail}
            </div>
          )}
          {failure && <div className="wq-failure">{failure}</div>}
          {/* The answers keep their place on every row (hidden on the others), so selecting one
              never moves a line. */}
          {look !== "compact" && (
            <div className="wq-answers" data-shown={showsAnswers || undefined} aria-hidden={!showsAnswers}>
              {item.kind === "pr" && !item.host ? (
                <>
                  <button
                    type="button"
                    className="wq-button"
                    data-tone="allow"
                    tabIndex={-1}
                    aria-keyshortcuts={acceptKey}
                    onClick={() => onVerdict(item, "accept")}
                  >
                    {acceptKey && <Keycap>{acceptKey}</Keycap>}
                    {t("waiting.pr.accept")}
                  </button>
                  <button
                    type="button"
                    className="wq-button"
                    tabIndex={-1}
                    aria-keyshortcuts={changesKey}
                    onClick={() => onComment({ id: item.id, text: "" })}
                  >
                    {changesKey && <Keycap>{changesKey}</Keycap>}
                    {t("waiting.pr.changes")}
                  </button>
                </>
              ) : answers.length > 0 ? (
                answers.map((each) => {
                  const key = each.tone === "allow" ? acceptKey : each.tone === "deny" ? changesKey : undefined;
                  return (
                    <button
                      key={each.id}
                      type="button"
                      className="wq-button"
                      data-tone={each.tone}
                      tabIndex={-1}
                      aria-keyshortcuts={key}
                      onClick={() => onAnswer(item, each)}
                    >
                      {key && <Keycap>{key}</Keycap>}
                      {each.label}
                    </button>
                  );
                })
              ) : (
                <button type="button" className="wq-link" tabIndex={-1} onClick={() => onOpen(item)}>
                  {item.host ? t("waiting.answerThere", { host: item.host }) : t("waiting.answerInChat")}
                </button>
              )}
            </div>
          )}
          {comment !== undefined && (
            <CommentBox
              text={comment}
              onChange={(text) => onComment({ id: item.id, text })}
              onSend={(text) => onVerdict(item, "changes", text)}
              onCancel={onCancel}
            />
          )}
        </div>
      </div>
    </li>
  );
});

function CommentBox({
  text,
  onChange,
  onSend,
  onCancel,
}: {
  text: string;
  onChange(text: string): void;
  onSend(text: string): void;
  onCancel(): void;
}) {
  const t = useT();
  const field = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    field.current?.focus();
  }, []);
  return (
    <div className="wq-comment">
      <textarea
        ref={field}
        className="wq-comment-field"
        rows={2}
        value={text}
        placeholder={t("waiting.comment.placeholder")}
        aria-label={t("waiting.pr.changes")}
        onChange={(event) => onChange(event.target.value)}
        onKeyDown={(event) => {
          event.stopPropagation();
          if (event.nativeEvent.isComposing) return;
          if (event.key === "Escape") {
            event.preventDefault();
            onCancel();
          } else if (event.key === "Enter" && !event.shiftKey) {
            event.preventDefault();
            if (text.trim()) onSend(text);
          }
        }}
      />
      <div className="wq-comment-actions">
        <button type="button" className="wq-button" onClick={onCancel}>
          {t("waiting.comment.cancel")}
        </button>
        <button
          type="button"
          className="wq-button"
          data-tone="allow"
          disabled={!text.trim()}
          onClick={() => onSend(text)}
        >
          {t("waiting.comment.send")}
        </button>
      </div>
    </div>
  );
}

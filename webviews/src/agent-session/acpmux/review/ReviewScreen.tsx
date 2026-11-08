// The Review queue (Show Review Queue, `agentReview.show`): every agent's changes waiting on the
// person, one row per folder, newest needing you first (reviewModel.ts). Keyboard first: j/k or the
// arrows move, Return opens the folder in the diff viewer (the existing diff tab, beside this page),
// `a` accepts and moves on, `r` opens a comment under the row whose Return sends it to the folder's
// chat as a prompt. A row leaves the queue in the frame the person decides; the host's answer
// confirms it, and a refusal brings it back with the reason under it.
import React, { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { Listbox } from "../../../ui/Listbox";
import { Counts } from "../changes/Counts";
import { age } from "../homeListsModel";
import { useT } from "../i18n";
import { Keycap } from "../Keycap";
import { useNoEntryMotion } from "../newtab/noEntryMotion";
import type { AcpmuxSessionEntry } from "../sessionList";
import { changesPrompt, verdictTag, type ReviewRow, type ReviewVerdict } from "./reviewModel";
import { useReviewQueue, type ReadDiff } from "./useReviewQueue";

/// How much of a row shows (gallery `pages.review`): one line, the change and its turn, or that with
/// its first files. Detail is the shipped look.
export type ReviewLook = "compact" | "detail" | "files";

export type ReviewActions = {
  readDiff: ReadDiff;
  /// The folder in the diff viewer, beside this page (`pane.action openDiffViewer {cwd}`).
  openDiff(cwd: string): Promise<unknown>;
  /// Tags `sessionId` `review.done` = `tag` (the host's `review.accept`).
  accept(sessionId: string, tag: string): Promise<unknown>;
  /// Sends `text` to `sessionId` as a prompt, then tags it (the host's `review.send`).
  send(sessionId: string, text: string, tag: string, promptId: string): Promise<unknown>;
};

type Props = ReviewActions & {
  sessions: readonly AcpmuxSessionEntry[];
  look?: ReviewLook;
  now?: number;
  /// Gallery only: the row the comment opens under at first.
  initialComment?: string;
};

const SHOWN_FILES = 3;

const plain = (event: React.KeyboardEvent) => !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey;

const newPromptId = () =>
  typeof crypto !== "undefined" && "randomUUID" in crypto
    ? crypto.randomUUID()
    : `review-${Date.now()}-${Math.random().toString(16).slice(2)}`;

export function ReviewScreen({
  sessions,
  readDiff,
  openDiff,
  accept,
  send,
  look = "detail",
  now,
  initialComment,
}: Props) {
  const t = useT();
  // A New Tab page too: what it shows appears at once (noEntryMotion.ts).
  useNoEntryMotion();
  /// Verdicts given here that acpmux's tags may not carry yet: `<folder>:<signature>`.
  const [local, setLocal] = useState<ReadonlySet<string>>(() => new Set());
  const { rows, pending, extend } = useReviewQueue(sessions, readDiff, local, now);
  const [selected, setSelected] = useState<string | undefined>();
  const lastIndex = useRef(0);
  /// The open comment.
  const [comment, setComment] = useState<{ key: string; text: string } | undefined>(
    initialComment ? { key: initialComment, text: "" } : undefined,
  );
  /// Sends that failed, by row: their words and prompt id, kept whatever comment is open, so `r` on
  /// that row gives the words back and a retry of the same words reuses the id (acpmux delivers it
  /// once even if the first one got through).
  const [unsent, setUnsent] = useState<ReadonlyMap<string, { text: string; promptId: string }>>(() => new Map());
  const [failures, setFailures] = useState<ReadonlyMap<string, string>>(() => new Map());
  const list = useRef<HTMLDivElement>(null);

  // The cursor follows its row by folder; a row that left gives its place to the next one.
  const found = rows.findIndex((row) => row.key === selected);
  const index = rows.length === 0 ? -1 : found >= 0 ? found : Math.min(lastIndex.current, rows.length - 1);
  const current = index >= 0 ? rows[index] : undefined;
  // The cursor's place, for when its row leaves: a ref, so no render follows.
  useLayoutEffect(() => {
    if (index >= 0) lastIndex.current = index;
  });
  useEffect(() => {
    extend(Math.max(0, index));
  }, [index, extend]);

  const decide = useCallback(
    (
      row: ReviewRow,
      verdict: ReviewVerdict,
      run: (tag: string) => Promise<unknown>,
      failed: string,
      restore?: () => void,
    ) => {
      const mark = `${row.key}:${row.stat.signature}`;
      setLocal((previous) => new Set(previous).add(mark));
      setFailures((previous) => without(previous, row.key));
      run(verdictTag(verdict, row.stat)).catch(() => {
        setLocal((previous) => {
          const next = new Set(previous);
          next.delete(mark);
          return next;
        });
        setFailures((previous) => new Map(previous).set(row.key, failed));
        restore?.();
      });
    },
    [],
  );

  const acceptRow = (row: ReviewRow) =>
    decide(row, "accepted", (tag) => accept(row.owner.sessionId, tag), t("review.failed.accept"));

  const sendComment = (row: ReviewRow, text: string) => {
    if (!text.trim()) return;
    const retry = unsent.get(row.key);
    const promptId = retry && retry.text === text ? retry.promptId : newPromptId();
    setComment(undefined);
    setUnsent((previous) => without(previous, row.key));
    decide(
      row,
      "changes",
      (tag) => send(row.owner.sessionId, changesPrompt(row, text), tag, promptId),
      t("review.failed.send"),
      // A send that failed keeps the person's words, and opens them again unless another comment is open.
      () => {
        setUnsent((previous) => new Map(previous).set(row.key, { text, promptId }));
        setComment((open) => open ?? { key: row.key, text });
      },
    );
    list.current?.focus({ preventScroll: true });
  };

  const move = (step: number) => {
    const next = rows[Math.max(0, Math.min(rows.length - 1, index + step))];
    if (next) setSelected(next.key);
  };

  const open = (row: ReviewRow) => void openDiff(row.key).catch(() => undefined);

  // The list's own keys; the Listbox moves on the arrows and opens on Return.
  const onKeyDown = (event: React.KeyboardEvent) => {
    if (event.target !== event.currentTarget || !plain(event) || event.nativeEvent.isComposing) return;
    const handled = (() => {
      switch (event.key) {
        case "j":
          move(1);
          return true;
        case "k":
          move(-1);
          return true;
        case "a":
          if (current) acceptRow(current);
          return Boolean(current);
        case "r":
          if (current) setComment({ key: current.key, text: unsent.get(current.key)?.text ?? "" });
          return Boolean(current);
        default:
          return false;
      }
    })();
    if (handled) event.preventDefault();
  };

  return (
    <div className="rv" data-look={look}>
      <h1 className="rv-title">{t("review.title")}</h1>
      <Listbox
        items={rows}
        getKey={(row) => row.key}
        getItemId={(row) => rowId(row.key)}
        textValue={rowTitle}
        label={t("review.list")}
        className="rv-list"
        rowClassName="rv-row"
        listRef={list}
        activeIndex={Math.max(0, index)}
        onActiveIndexChange={(next) => setSelected(rows[next]?.key)}
        focusable
        onKeyDown={onKeyDown}
        onOpen={open}
        renderItem={(row) => (
          <Row
            row={row}
            look={look}
            now={now}
            failure={failures.get(row.key)}
            comment={comment?.key === row.key ? comment.text : undefined}
            onComment={(text) => setComment({ key: row.key, text })}
            onSend={(text) => sendComment(row, text)}
            onCancel={() => {
              setComment(undefined);
              list.current?.focus({ preventScroll: true });
            }}
          />
        )}
        footer={
          // One status line, always the same height, so the list never moves when reads finish.
          <div className="rv-status" aria-live="polite">
            {pending ? t("review.reading") : rows.length === 0 ? t("review.empty") : ""}
          </div>
        }
      />
      <div className="rv-keys">
        <span>
          <Keycap>j</Keycap>
          <Keycap>k</Keycap>
          {t("review.key.move")}
        </span>
        <span>
          <Keycap>↩</Keycap>
          {t("review.key.open")}
        </span>
        <span>
          <Keycap>a</Keycap>
          {t("review.key.accept")}
        </span>
        <span>
          <Keycap>r</Keycap>
          {t("review.key.changes")}
        </span>
      </div>
    </div>
  );
}

const rowId = (key: string) => `rv-row-${key.replace(/[^A-Za-z0-9_-]/g, "_")}`;

function without<V>(map: ReadonlyMap<string, V>, key: string): ReadonlyMap<string, V> {
  if (!map.has(key)) return map;
  const next = new Map(map);
  next.delete(key);
  return next;
}

const rowTitle = ({ owner, key }: ReviewRow) =>
  owner.displayTitle ?? owner.title ?? owner.name ?? key.split("/").pop() ?? key;

/// A row's content; the Listbox's option holds it (a click opens the folder's diff).
function Row({
  row,
  look,
  now,
  failure,
  comment,
  onComment,
  onSend,
  onCancel,
}: {
  row: ReviewRow;
  look: ReviewLook;
  now?: number;
  failure?: string;
  comment?: string;
  onComment(text: string): void;
  onSend(text: string): void;
  onCancel(): void;
}) {
  const t = useT();
  const { owner, stat } = row;
  const title = rowTitle(row);
  const checks = owner.pullRequest?.checks;
  const when = age(row.at, now, t);
  return (
    <>
      <div className="rv-line">
        <span className="rv-name">{title}</span>
        {owner.branch && <span className="rv-branch">{owner.branch}</span>}
        {row.working && <span className="rv-tag">{t("review.working")}</span>}
        {row.others > 0 && <span className="rv-meta">{t("review.others", { n: row.others })}</span>}
        <span className="rv-fill" />
        <span className="rv-meta">{t("review.files", { n: stat.totalFiles })}</span>
        <Counts additions={stat.additions} deletions={stat.deletions} />
        {when && <span className="rv-meta rv-age">{when}</span>}
      </div>
      {look !== "compact" && (
        <div className="rv-line rv-sub">
          <span className="rv-turn">{owner.lastMessage ?? row.key}</span>
          {checks && (
            <span className="rv-checks" data-checks={checks}>
              {t(`review.checks.${checks}`)}
            </span>
          )}
        </div>
      )}
      {look === "files" && (
        <ul className="rv-files">
          {stat.files.slice(0, SHOWN_FILES).map((file) => (
            <li key={file.path}>
              <span className="rv-path">{file.path}</span>
              <Counts additions={file.additions} deletions={file.deletions} />
            </li>
          ))}
          {stat.totalFiles > SHOWN_FILES && (
            <li className="rv-meta">{t("review.moreFiles", { n: stat.totalFiles - SHOWN_FILES })}</li>
          )}
        </ul>
      )}
      {failure && <div className="rv-failure">{failure}</div>}
      {comment !== undefined && <CommentBox text={comment} onChange={onComment} onSend={onSend} onCancel={onCancel} />}
    </>
  );
}

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
    // A press or key in the comment stays in it: the list around it would open the diff (Return,
    // Space, a press) or move (its own keys), and the buttons would not act.
    // oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- stops the press and keys, acts on nothing
    <div
      className="rv-comment"
      onMouseDown={(event) => event.stopPropagation()}
      onKeyDown={(event) => event.stopPropagation()}
    >
      <textarea
        ref={field}
        className="rv-comment-field"
        rows={2}
        value={text}
        placeholder={t("review.comment.placeholder")}
        aria-label={t("review.key.changes")}
        onChange={(event) => onChange(event.target.value)}
        onKeyDown={(event) => {
          event.stopPropagation();
          if (event.nativeEvent.isComposing) return;
          if (event.key === "Escape") {
            event.preventDefault();
            onCancel();
          } else if (event.key === "Enter" && !event.shiftKey) {
            event.preventDefault();
            onSend(text);
          }
        }}
      />
      <div className="rv-comment-actions">
        <button type="button" className="rv-button" onClick={onCancel}>
          {t("review.comment.cancel")}
        </button>
        <button type="button" className="rv-button" data-primary disabled={!text.trim()} onClick={() => onSend(text)}>
          {t("review.comment.send")}
        </button>
      </div>
    </div>
  );
}

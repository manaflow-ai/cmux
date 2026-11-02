// The global inbox on a new chat's home (Leo 2026-10-26: "I don't want to dig through every single
// puzzle thing, like find the needle in the haystack"): every ask waiting on the person, from every
// chat this pane's acpmux watches, answered in place. It replaces the home's "Needs input" list,
// which only named the chats and sent the person into each one to find its ask.
//
// The rows are Needs you's items (needsYou/model.ts): one per pending request acpmux reports, keyed
// by its permission id, so a row leaves as soon as acpmux says the ask was answered, wherever it
// was answered, and a chat that waits with no ask the page can read (a chat on another computer)
// is still one row, which opens it. An approval's Allow once and Deny answer it here, under the
// command or details it asks about; the first such row also takes the permission shortcuts (⌥⌘1,
// ⌥⌘3) unless the home's own chat shows a card that takes them. A refused answer says so on its
// row, and the row answers again.
import { useEffect, useRef, useState } from "react";
import { pressToOpen } from "../../ui/pressToOpen";
import { AgentMark } from "../shared/AgentMark";
import { age } from "./HomeLists";
import { type StringKey, useT } from "./i18n";
import { NativeError } from "./nativeError";
import { askText } from "./needsYou/NeedsYou";
import type { NeedsYouAnswer, NeedsYouItem, NeedsYouKind } from "./needsYou/model";
import { PermissionActionButton } from "./PermissionCard";
import { type AcpmuxSessionEntry, projectLabel } from "./sessionList";
import { SHORTCUT_ACTIONS, useShortcut } from "./shortcuts";

/// How the inbox lays its rows out: each ask with its chat under it and its answers (`list`, the
/// home's), one line per ask with its answers at its end (`compact`), or under its chat's folder
/// (`grouped`). The gallery shows all three.
export type HomeInboxLook = "list" | "compact" | "grouped";

/// What became of an answer given here: `answered` (the host answered it; the row hides until
/// acpmux takes it off) or `opened` (the host can't answer it here and opened its chat, whose card
/// answers it; the row stays).
export type HomeInboxOutcome = "answered" | "opened";

export type HomeInboxActions = {
  /// Answers `item` with `choice`; rejects when it was refused.
  answer(item: NeedsYouItem, choice: NeedsYouAnswer): Promise<HomeInboxOutcome>;
  /// Opens the chat the ask is in.
  open(item: NeedsYouItem): void;
};

/// Answers another chat's ask from the home's inbox (`chat.asks.answer`, CmuxNextAgentPane
/// AgentPaneAskAnswer): the host takes it only on the person's own click or key, for an ask still
/// pending in a chat on this Mac's acpmux, with that ask's allow once or deny once. A host that does
/// not answer it here opens the chat, whose card answers it: `unsupported` (another computer's chat
/// or daemon, or the pane's own host before the op), or the shared page host without the op
/// (`callPageHost` reports its `cmux.protocol.unknown_op` as `native.invalid_request` with the
/// protocol code in `details`). Any other refusal, a malformed request's `invalid_params` included,
/// rejects, and the row says so.
const notAnsweredHere = (error: NativeError) =>
  error.code === "unsupported" ||
  (error.code === "native.invalid_request" &&
    (error.details as { protocol?: unknown } | undefined)?.protocol === "cmux.protocol.unknown_op");

export async function answerFromHome(
  call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
  item: NeedsYouItem,
  choice: NeedsYouAnswer,
  open: (sessionId: string) => void,
): Promise<HomeInboxOutcome> {
  if (!item.permissionId) throw new Error("unanswerable");
  try {
    await call("chat.asks.answer", {
      sessionId: item.sessionId,
      permissionId: item.permissionId,
      optionId: choice.id,
    });
    return "answered";
  } catch (error) {
    if (!(error instanceof NativeError) || !notAnsweredHere(error)) throw error;
    open(item.sessionId);
    return "opened";
  }
}

const KINDS: Record<NeedsYouKind, StringKey> = {
  approval: "needsYou.kind.approval",
  decision: "needsYou.kind.decision",
  verify: "needsYou.kind.verify",
  held: "needsYou.kind.held",
  input: "needsYou.kind.input",
};

/// The answers a row gives in place: an approval's allow and deny. A question's choices, a held
/// pair and a chat with no ask read here open the chat, where the whole ask shows.
export const inlineAnswers = (item: NeedsYouItem) =>
  item.kind === "approval" || item.kind === "verify" ? item.answers.filter((a) => a.tone !== "choice") : [];

export function HomeInbox({
  items,
  sessions,
  actions,
  look = "list",
  shortcuts = true,
  now = Date.now(),
}: {
  /// The asks, newest first, without the home's own chat.
  items: readonly NeedsYouItem[];
  sessions: readonly AcpmuxSessionEntry[];
  actions: HomeInboxActions;
  look?: HomeInboxLook;
  /// False when something else on the page takes the permission shortcuts.
  shortcuts?: boolean;
  now?: number;
}) {
  const t = useT();
  // Asks answered here, hidden until acpmux's change takes them off the list.
  const [sent, setSent] = useState<ReadonlySet<string>>(new Set());
  const shown = items.filter((item) => !sent.has(item.id));
  const byId = new Map(sessions.map((session) => [session.sessionId, session]));
  // The first row an answer can be given on takes the keys.
  const keyed = shortcuts ? shown.find((item) => inlineAnswers(item).length > 0)?.id : undefined;
  if (shown.length === 0) return null;
  const row = (item: NeedsYouItem) => (
    <InboxRow
      key={item.id}
      item={item}
      session={byId.get(item.sessionId)}
      look={look}
      now={now}
      keyed={item.id === keyed}
      actions={actions}
      onAnswered={() => setSent((before) => new Set(before).add(item.id))}
      onRefused={() =>
        setSent((before) => {
          const next = new Set(before);
          next.delete(item.id);
          return next;
        })
      }
    />
  );
  const label = t("needsYou.title");
  return (
    <section className="acpmux-home-list acpmux-home-inbox" data-look={look} aria-label={label}>
      <h3 className="acpmux-home-label">
        {label}
        <span className="acpmux-home-inbox-count">{shown.length}</span>
      </h3>
      {look === "grouped" ? (
        groups(shown, byId, t).map(([folder, rows]) => (
          <section key={folder} className="acpmux-home-inbox-group" aria-label={folder}>
            <h4 className="acpmux-home-inbox-folder">{folder}</h4>
            <ul>{rows.map(row)}</ul>
          </section>
        ))
      ) : (
        <ul>{shown.map(row)}</ul>
      )}
    </section>
  );
}

/// The asks by their chat's folder, in the order each folder's newest ask came.
function groups(
  items: readonly NeedsYouItem[],
  byId: ReadonlyMap<string, AcpmuxSessionEntry>,
  t: ReturnType<typeof useT>,
): [string, NeedsYouItem[]][] {
  const folders = new Map<string, NeedsYouItem[]>();
  for (const item of items) {
    const folder = projectLabel(byId.get(item.sessionId)?.cwd, t);
    folders.set(folder, [...(folders.get(folder) ?? []), item]);
  }
  return [...folders];
}

function InboxRow({
  item,
  session,
  look,
  now,
  keyed,
  actions,
  onAnswered,
  onRefused,
}: {
  item: NeedsYouItem;
  session?: AcpmuxSessionEntry;
  look: HomeInboxLook;
  now: number;
  /// This row takes the permission shortcuts.
  keyed: boolean;
  actions: HomeInboxActions;
  onAnswered(): void;
  onRefused(): void;
}) {
  const t = useT();
  const [sending, setSending] = useState<string>();
  const [failed, setFailed] = useState(false);
  // Set before the answer goes out, so a second click or key in the same tick sends nothing.
  const inFlight = useRef(false);
  const answers = inlineAnswers(item);
  const allow = answers.find((a) => a.tone === "allow");
  const deny = answers.find((a) => a.tone === "deny");
  const answer = (choice: NeedsYouAnswer) => {
    if (inFlight.current) return;
    inFlight.current = true;
    setSending(choice.id);
    setFailed(false);
    let reply: Promise<HomeInboxOutcome>;
    try {
      reply = Promise.resolve(actions.answer(item, choice));
    } catch (error) {
      reply = Promise.reject(error);
    }
    reply.then(
      (outcome) => {
        if (outcome === "answered") return onAnswered();
        inFlight.current = false;
        setSending(undefined);
      },
      () => {
        inFlight.current = false;
        setSending(undefined);
        setFailed(true);
        onRefused();
      },
    );
  };
  const allowShortcut = useShortcut(SHORTCUT_ACTIONS.permissionAllowOnce);
  const denyShortcut = useShortcut(SHORTCUT_ACTIONS.permissionDeny);
  // The app's permission shortcuts arrive as page events; read the row's answer at the key.
  const onKey = useRef<(choice?: NeedsYouAnswer) => void>(() => undefined);
  onKey.current = (choice) => choice && answer(choice);
  useEffect(() => {
    if (!keyed) return;
    const events = [
      ["cmux-acpmux-permissionAllowOnce", () => onKey.current(allow)],
      ["cmux-acpmux-permissionDeny", () => onKey.current(deny)],
    ] as const;
    for (const [event, handler] of events) window.addEventListener(event, handler);
    return () => {
      for (const [event, handler] of events) window.removeEventListener(event, handler);
    };
  }, [keyed, allow, deny]);
  const project = session?.cwd ? projectLabel(session.cwd, t) : undefined;
  const machine = session?.peer ? session.host || session.peer : undefined;
  const when = age(item.at, now, t);
  const ask = askText(item, t);
  const chat = item.who.chief ? t("needsYou.chief") : item.who.name;
  const where = [chat, look === "grouped" ? undefined : project, machine].filter(Boolean).join(" · ");
  return (
    <li className="acpmux-home-inbox-row" data-kind={item.kind} data-sending={sending ? "" : undefined}>
      <button
        type="button"
        className="acpmux-home-inbox-open"
        aria-label={`${ask}, ${where}`}
        title={t("needsYou.goToSource")}
        {...pressToOpen(() => actions.open(item))}
      >
        <span className="acpmux-home-inbox-mark">
          <AgentMark agent={item.who.harness} size={14} reserve />
        </span>
        <span className="acpmux-home-inbox-text">
          <span className="acpmux-home-inbox-ask" title={ask}>
            {ask}
          </span>
          {item.detail && (
            <span className="acpmux-home-inbox-detail" data-code={item.command ? "" : undefined} title={item.detail}>
              {item.detail}
            </span>
          )}
          {look !== "compact" && (
            <span className="acpmux-home-inbox-where" title={where}>
              <span className="acpmux-home-inbox-kind">{t(KINDS[item.kind])}</span>
              {where && ` · ${where}`}
            </span>
          )}
        </span>
        {when && <span className="acpmux-home-meta">{when}</span>}
      </button>
      {answers.length > 0 && (
        <fieldset
          className="acpmux-home-inbox-answers"
          aria-label={[ask, item.detail, chat].filter(Boolean).join(", ")}
        >
          {allow && (
            <PermissionActionButton
              label={t("permission.allowOnce")}
              shortcut={keyed ? allowShortcut : undefined}
              className="acpmux-home-inbox-answer"
              data-tone="allow"
              disabled={sending !== undefined}
              aria-busy={sending === allow.id}
              onClick={() => answer(allow)}
            />
          )}
          {deny && (
            <PermissionActionButton
              label={t("permission.deny")}
              shortcut={keyed ? denyShortcut : undefined}
              className="acpmux-home-inbox-answer"
              data-tone="deny"
              disabled={sending !== undefined}
              aria-busy={sending === deny.id}
              onClick={() => answer(deny)}
            />
          )}
        </fieldset>
      )}
      {failed && (
        <p className="acpmux-home-inbox-error" role="alert">
          {t("permission.error.refused")}
        </p>
      )}
    </li>
  );
}

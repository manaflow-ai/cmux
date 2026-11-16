// A message this agent sent another one, drawn as another agent's message to this chat is
// (IncomingMessageCard.tsx; ask-64e107ccf0, Leo 2026-11-07: "it's just not good, compared to the
// normal ones"): the one message row every message between agents draws (AgentMessageRow.tsx; Leo,
// 2026-11-07, on a "Sent to" row beside a received one: "why is it formatted differently from
// everything else?"), the envelope in the icon column where a sender's mark sits, "Sent to"
// ("Sending to" while it goes out, "Couldn't send to" when it failed), the recipient's chip with its
// machine after it, muted, as a sender's is, then the message's first line muted, how it was
// delivered in the trailing column ("queued"), and the chevron. Direction is the words, never
// another look.
// The row opens to the received message's card: the whole message as Markdown, its first line then
// gone from the line (Leo 2026-10-29: "this rendering can be better for sent stuff"), Copy in the
// card's corner, and Raw under it as a received message's Details is, closed until asked for and
// closed again whenever the row draws anew. Raw holds the call as it was made: a shell call's plain
// command row (ToolRow.tsx), never a Shell card in the message, or an MCP call's request and
// response. A failed send starts with Raw open: its output says why. A send whose words the
// transcript does not hold opens straight to the call. Both ways of sending draw this one row: a
// cmux-subsessions `send_message` (SubsessionCallCard.tsx) and a shell `acpmux send`
// (acpmuxSends.ts, `AcpmuxSendLine` below). Whether the row is open lasts across the virtualized
// transcript (transcriptDisclosure.tsx). The recipient opens its chat beside this one when the
// session list knows it (by id, or by `name`, `host/name` or `host:name`); otherwise it is the
// neutral chip. A shell call that also ran other commands says so ("· and 2 more commands"), its
// whole command behind Raw: no work is hidden.
import { Children, type ReactNode, useContext, useEffect, useId, useMemo, useState, useSyncExternalStore } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import type { AcpmuxSendCallPart, SendState } from "./acpmuxSends";
import { AgentMessageRow } from "./AgentMessageRow";
import { messagePreview } from "./agentMessageRowModel";
import { messageDelivery } from "./agentMessages";
import { activityText, FindReveal, foldFind, useFindReveal } from "./chatFind";
import { plainText } from "./messageMenu";
import { AlertCircle, Envelope, ChevronRight } from "./icons";
import { AgentMessageBody } from "./AgentMessageBody";
import { AgentTag } from "./AgentTag";
import { CardCopy } from "./CardCopy";
import { MessageGroupHead } from "./MessageGroupHead";
import { messageRunSummary } from "./messageRuns";
import { AgentNamesContext, recipientName, shortId } from "./agentNames";
import { isFailed, isRunning, type SentEntry } from "./toolGroups";
import { acpmuxMcpSendCall } from "./acpmuxMcpSends";
import { McpCallDetails } from "./McpCallRows";
import { mcpCall, mcpRawName } from "./mcpCalls";
import { useTranscriptDisclosure } from "./transcriptDisclosureModel";
import { ToolRow } from "./ToolRow";
import { useMessageLineLook } from "./messageLineLook";
import { sentMessageLook } from "./sentMessageLook.experiment";
import { SubsessionContext, SubsessionStore } from "../subagents/subsessions";
import "./AgentMessageRow.css";
import "./SubsessionCallCard.css";
import { look, listeners, recipientPlace, targetChat, sendKey } from "./sentMessageLineModel";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => look;

const NO_STORE = new SubsessionStore();
/// Each state's sentence, the words every message row uses ("Sent to", "Sending to"); `ended`:
/// the call does not say whether the message went.
function sendLabel(t: ReturnType<typeof useT>, state: SendState): string {
  switch (state) {
    case "sending":
      return t("message.sendingTo", { to: MARK });
    case "sent":
      return t("message.sentTo", { to: MARK });
    case "failed":
      return t("send.failed", { target: MARK });
    case "ended":
      return t("send.ended", { target: MARK });
  }
}

/// Where the target placeholder sits in the translated line, so the name can be a link.
const MARK = "\u0001";

export function SentMessageLine({
  tool,
  state,
  target,
  targetSession,
  text,
  file,
  detail,
  others = 0,
  disclosureKey,
  raw,
  rawOpen = false,
}: {
  /// The call: Find in Chat opens the row when its match is in it.
  tool: Tool;
  state: SendState;
  /// Who it went to, by name.
  target: string;
  /// The chat's id, when the call gives it (a sub-session `send_message`).
  targetSession?: string;
  /// Other commands the same shell call ran (acpmuxSends.ts `others`).
  others?: number;
  /// The message, when the call holds it; without it the row names only the target.
  text?: string;
  /// The file the message was read from, when the call names it but not the words in it
  /// (`"$(cat note.md)"`, the MCP send's `file`): the row names it where the first line would be.
  file?: string;
  /// How it was delivered, after the line ("queued", "read at its next step").
  detail?: string;
  disclosureKey: string;
  /// The call as it was made, behind the Raw toggle while open; `reveal` bumps when Find in Chat
  /// shows the call, so its output shows whole.
  raw: (reveal: number) => ReactNode;
  /// Raw starts open (a failed send: its output says why).
  rawOpen?: boolean;
}) {
  const t = useT();
  const shape = useSyncExternalStore(subscribe, snapshot, snapshot);
  // Single (the default, messageLineLook.ts): one line, the verb, the recipient, the count, the first
  // line muted and cut, then the chevron. Stacked (a gallery version) puts the first line under it,
  // on a line of its own; `quiet` draws no first line until the row opens. The arrow and quote shapes
  // keep their one line.
  const lineLook = useMessageLineLook();
  const stacked = shape === "sentence" && lineLook !== "single";
  const [open, setOpen] = useTranscriptDisclosure(disclosureKey);
  // Raw is the row's own, closed each time the row draws (a remount, a reload, the virtualized
  // transcript drawing it again), whatever the row's saved state: the message is what the row is
  // for, the call a click further (Leo, 2026-11-07, on a Raw found open on its Shell card: "Did we
  // not fix this formatting yet? Um, like the raw thing?"). Only a failed send starts it open.
  const [rawShown, setRawShown] = useState(rawOpen);
  // A send that fails while it shows opens its Raw then: the output says why.
  useEffect(() => {
    if (rawOpen) setRawShown(true);
  }, [rawOpen]);
  const [reveal, setReveal] = useState(0);
  // Find in Chat opens the row. It opens Raw only for a match that is not in the message's words
  // (the command's other parts, its output), as a received message opens its Details.
  const find = useContext(FindReveal);
  const findItems = useMemo((): AcpmuxActivity[] => [{ kind: "tool", text: tool.title, tool }], [tool]);
  const callText = () => foldFind(findItems.map(activityText).join("\n"));
  useFindReveal(findItems, () => {
    setOpen(true);
    // A command link names this call: the call is behind Raw, so Raw opens to show it.
    if (find?.toolId !== undefined) {
      if (find.toolId === tool.id) setRawShown(true);
    } else {
      const needle = find?.needle ?? "";
      // Find counts the call's matches (its command and output, chatFind.ts `activityText`); the
      // message's words, as they draw, hold some of them. Any more are outside the message (the
      // output, the rest of the command, a link's address in the Markdown source), behind Raw, so
      // Raw opens and Next steps into them (`acpmux send lane 'ready'` printing "ready").
      if (!text || (needle && occurrences(foldFind(plainText(text)), needle) < occurrences(callText(), needle)))
        setRawShown(true);
    }
    setReveal((value) => value + 1);
  });
  const look = experimentArm(sentMessageLook);
  const chats = useContext(SubsessionContext);
  const store = chats?.store ?? NO_STORE;
  const readChat = () => targetChat(store, target, targetSession);
  const chat = useSyncExternalStore(store.subscribeNames, readChat, readChat);
  const place = recipientPlace(target, chat ? store.host(chat) : undefined);
  const preview = text ? messagePreview(text) : "";
  // The open row shows the whole message under it: its first line on the row would say it twice.
  const shown = preview && state !== "failed" && !(open && text) ? preview : "";
  // No words to show, only where they came from: the file's path, as code, after the line.
  const fileShown = !text && file && state !== "failed" ? file : "";
  // Stacked, they take the line under the row instead (`below`); `quiet` shows neither while shut.
  const arrowSaysIt = shape === "arrow" && (state === "sending" || state === "sent") && Boolean(preview);
  // The arrow look's label already carries the preview ("To X: words"); not again after it.
  const trailing = stacked || arrowSaysIt ? "" : shown;
  const source = stacked ? "" : fileShown;
  const below = stacked && lineLook === "stacked" && !open ? shown || fileShown : "";
  const label = arrowSaysIt
    ? t(state === "sending" ? "subsession.sending" : "subsession.to", { name: MARK, text: preview })
    : sendLabel(t, state);
  const [before, after = ""] = label.split(MARK);
  // The recipient as a received message's sender draws: its chip (the session link chip when its
  // chat is known), then the machine it runs on, muted, after it.
  const name =
    chat && chats ? (
      <AgentTag
        name={place.name}
        className="cv-received__from cv-received__from--open cv-recipient cv-sent__target"
        title={t("subagents.open", { name: target })}
        ariaLabel={t("subagents.open", { name: target })}
        onClick={(event) => {
          event.stopPropagation();
          (chats.openSender ?? chats.open)(chat);
        }}
      />
    ) : (
      <AgentTag name={place.name} className="cv-received__from cv-recipient cv-sent__name" title={target} />
    );
  const more = others === 1 ? t("send.moreOne") : others > 1 ? t("send.more", { n: others }) : undefined;
  const icon = state === "failed" ? <AlertCircle /> : <Envelope />;
  const words = [before.trim(), target, after.trim()].filter(Boolean).join(" ");
  // The one message row (AgentMessageRow.tsx), as a received message's (`cv-received`): the
  // envelope in the icon column, "Sent to", the recipient's chip and machine in the sender span, the
  // count, the first line; opened, the message in the same card as theirs with Copy in its corner,
  // Raw under it.
  const quoted =
    shape === "quote" && trailing
      ? // l10n-allow: punctuation around the message's own words.
        `“${trailing}”`
      : trailing;
  return (
    <AgentMessageRow
      direction="sent"
      className={`cv-received cv-sent-msg look-${look}${state === "sending" ? " is-live" : ""}`}
      attributes={{ "data-send-state": state }}
      lineClassName="cv-sent"
      // Find counts the send, never the line that sums it up, as DisclosureRow's line added no
      // matches (IncomingMessageCard.tsx).
      lineAttributes={{ "data-find-skip": "" }}
      previewClassName="cv-received__preview cv-sent__preview"
      belowClassName="cv-sent__below"
      icon={
        <span className={`cv-received__mark${state === "failed" ? " cv-tool__failed" : ""}`} aria-hidden="true">
          {icon}
        </span>
      }
      sentence={"\u0000"}
      name={target}
      nameSlot={
        <span className="cv-received__sender cv-sent__sender">
          {/* The spaces are part of the accessible sentence; flex gap supplies their visual spacing. */}
          {before.trim() && <span className="cv-sent__words">{before.trim()}</span>}
          {before.trim() && " "}
          {name}
          {place.host && " "}
          {place.host && <span className="cv-received__host">{place.host}</span>}
          {after.trim() && " "}
          {after.trim() && <span className="cv-sent__words">{after.trim()}</span>}
        </span>
      }
      detail={
        <>
          {more && " "}
          {more && (
            <span className="cv-tool__detail cv-sent__more" data-find-skip="">
              {`· ${more}`}
            </span>
          )}
          {source && " "}
          {source && (
            // tooltip-allow: the whole path, which the line cuts with an ellipsis in a narrow pane
            <code className="cv-tool__detail cv-sent__file" title={source} data-find-skip="">
              {source}
            </code>
          )}
        </>
      }
      // Stacked, the first line (or the file) takes the line under the row (`below`).
      preview={stacked ? below : quoted}
      label={[words, more, trailing || source].filter(Boolean).join(" · ")}
      open={open}
      onToggle={() => setOpen((value) => !value)}
      failed={state === "failed"}
      live={state === "sending"}
      meta={
        detail ? (
          <span className="cv-command__meta cv-agentmsg__status cv-sent__status">
            <span className="cv-row-status">{detail}</span>
          </span>
        ) : undefined
      }
      body={
        text ? (
          <>
            {/* No Copy on the line (Leo, 2026-11-04: "let's remove copy button"); the card's corner
                copies the words, as a received message's does. */}
            <CardCopy text={text} />
            <div className="cv-received__text selectable">
              <AgentMessageBody text={text} commits="quiet" />
            </div>
          </>
        ) : (
          // No words to render: the call is all there is, so it shows at once, not behind a
          // second "Raw" click (Leo 2026-10-26: "EITHER SHOW IT DIRECT WITHOUT OR ... RENDER IT").
          <div className="cv-sent__call">{raw(reveal)}</div>
        )
      }
      under={
        text ? (
          <RawDetails open={rawShown} onOpenChange={setRawShown}>
            {raw(reveal)}
          </RawDetails>
        ) : undefined
      }
    />
  );
}

/// How many times `needle` occurs in `text`, counted as Find counts (chatFind.ts: no overlaps).
function occurrences(text: string, needle: string): number {
  let count = 0;
  for (let at = text.indexOf(needle); at >= 0; at = text.indexOf(needle, at + needle.length)) count += 1;
  return count;
}

/// Raw under an opened sent message, closed until asked for: a quiet link as a received message's
/// Details (the default arm), a bare chevron, or a link shown on hover (sentMessageLook.experiment.ts).
function RawDetails({
  open,
  onOpenChange,
  children,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  children: ReactNode;
}) {
  const t = useT();
  const id = useId();
  const look = experimentArm(sentMessageLook);
  return (
    <div className="cv-received__details cv-sent__raw" data-find-skip={open ? undefined : ""}>
      <button
        type="button"
        className="cv-received__more"
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        aria-label={look === "chevron" ? t("subsession.raw") : undefined}
        onClick={() => onOpenChange(!open)}
      >
        {look !== "chevron" && t("subsession.raw")}
        <ChevronRight size={12} className={`cv-rotor${open ? " is-open" : ""}`} />
      </button>
      {open && (
        <div id={id} className="cv-sent__raw-body">
          {children}
        </div>
      )}
    </div>
  );
}

/// "Raw" and the call under it while open: its own state, or the caller's (`open`, `onOpenChange`).
export function RawToggle({
  children,
  icon,
  actions,
  startOpen = false,
  open: shown,
  onOpenChange,
}: {
  children: ReactNode;
  icon?: ReactNode;
  /// Quiet actions on the opened message (its Copy), on Raw's line before it.
  actions?: ReactNode;
  startOpen?: boolean;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
}) {
  const t = useT();
  const [own, setOwn] = useState(startOpen);
  const open = shown ?? own;
  const setOpen = (next: (value: boolean) => boolean) => (onOpenChange ? onOpenChange(next(open)) : setOwn(next));
  const id = useId();
  const button = (
    <button
      type="button"
      className="cv-subsession__toggle"
      aria-expanded={open}
      aria-controls={open ? id : undefined}
      onClick={() => setOpen((value) => !value)}
    >
      {icon}
      {t("subsession.raw")}
      <ChevronRight size={12} className={`cv-rotor${open ? " is-open" : ""}`} />
    </button>
  );
  return (
    <div className="cv-subsession__raw">
      {actions ? (
        <div className="cv-subsession__actions">
          {actions}
          {button}
        </div>
      ) : (
        button
      )}
      {open && <div id={id}>{children}</div>}
    </div>
  );
}

/// A message sent by a shell `acpmux send` (acpmuxSends.ts), one of a shell batch's, or one of an
/// acpmux MCP send's batch (acpmuxMcpSends.ts), as the sent-message row; Raw holds the call as it
/// was made: its Shell card, the whole command line for every message of a batch, or the MCP
/// request and response.
export function AcpmuxSendLine({
  tool,
  send,
  grouped = false,
}: {
  tool: Tool;
  send: AcpmuxSendCallPart;
  /// Inside a group of sends (`SentMessageGroup`): the group's line says what else the call ran.
  grouped?: boolean;
}) {
  const t = useT();
  // `--no-wait` prints how the daemon took the message; a send that waits prints the reply. A
  // batch's message reads its own line of the output (`delivery`).
  const delivery =
    send.state !== "sent"
      ? undefined
      : send.index !== undefined
        ? send.delivery
        : send.noWait
          ? messageDelivery(tool)
          : undefined;
  const detail =
    delivery === "queued"
      ? t("subsession.delivery.queuedBare")
      : delivery === "delivered"
        ? t("subsession.delivery.nextStep")
        : undefined;
  return (
    <SentMessageLine
      tool={tool}
      state={send.state}
      target={send.target}
      text={send.text}
      file={send.file}
      detail={detail}
      disclosureKey={`send:${sendKey(tool.id, send.index)}`}
      others={grouped ? 0 : send.others}
      rawOpen={send.state === "failed"}
      raw={(reveal) => <SendRaw tool={tool} reveal={reveal} />}
    />
  );
}

/// The call behind a send row's Raw: a shell call's command and output, an MCP call's request and
/// response.
function SendRaw({ tool, reveal }: { tool: Tool; reveal: number }) {
  const id = useId();
  const call = useMemo(() => (tool.command ? undefined : (mcpCall(tool) ?? acpmuxMcpSendCall(tool))), [tool]);
  const item = useMemo((): AcpmuxActivity => ({ kind: "tool", text: tool.title, tool }), [tool]);
  if (call)
    return (
      <McpCallDetails
        id={id}
        call={call}
        raw={mcpRawName(tool, call)}
        output={tool.output}
        tool={tool}
        strip={false}
        reveal={reveal}
      />
    );
  // A shell call is the plain command row every other command draws (ToolRow.tsx), closed until
  // opened, never a Shell card inside the message (ask-64e107ccf0). It reads as its command line,
  // not as what it did or its description: Raw is the call as it was made.
  return (
    <div className="cv-tools">
      <ToolRow item={item} asRun />
    </div>
  );
}

/// Two or more sent messages in a row (toolGroups.ts `sendGroup`: a shell loop of `acpmux send`, a
/// batch, adjacent sends of any kind) as one closed line, as a group of received messages is
/// (MessageGroupHead.tsx): "Sent 8 messages", the recipients muted after it, and once "· and 1
/// more command" for what else those calls ran, never on every message. It opens to each message's
/// own row (`children`; Leo, 2026-11-04: "why arent these collapsed/collapsible"; each message still
/// opens on its own, cmux#29800). The open state lasts across the virtualized transcript.
export function SentMessageGroup({
  entries,
  disclosureKey,
  children,
}: {
  entries: readonly SentEntry[];
  disclosureKey: string;
  /// Each message's row, drawn while the group is open.
  children: ReactNode;
}) {
  const t = useT();
  const names = useContext(AgentNamesContext);
  const [open, setOpen] = useTranscriptDisclosure(disclosureKey);
  const bodyId = useId();
  const tools = useMemo(() => [...new Set(entries.map(({ item }) => item))], [entries]);
  // Find in Chat opens the group when its match is in one of its messages.
  useFindReveal(tools, () => setOpen(true));
  const running = entries.some((entry) =>
    entry.type === "send"
      ? entry.send.state === "sending"
      : entry.type === "subsession"
        ? entry.call.running
        : isRunning(entry.item.tool!),
  );
  const failed = entries.filter((entry) =>
    entry.type === "send" ? entry.send.state === "failed" : entry.type === "message" && isFailed(entry.item.tool!),
  ).length;
  // Each call's other commands once: a batch's messages all carry its count.
  const others = [
    ...new Map(entries.map((entry) => [entry.item, entry.type === "send" ? (entry.send.others ?? 0) : 0])).values(),
  ].reduce((sum, n) => sum + n, 0);
  const summary = messageRunSummary(t, { sent: entries.length, received: 0, work: [], failed, running, rows: [] });
  const more = others === 1 ? t("send.moreOne") : others > 1 ? t("send.more", { n: others }) : undefined;
  const failedText = failed > 0 ? ` (${t("tools.failedCount", { n: failed })})` : "";
  const count = `${summary}${failedText}${more ? ` · ${more}` : ""}`;
  const recipients = [
    ...new Set(
      entries.map((entry) =>
        entry.type === "send"
          ? entry.send.target
          : entry.type === "subsession"
            ? shortId(entry.call.sessionId)
            : entry.message.to
              ? (recipientName(entry.message.to, names) ?? shortId(entry.message.to))
              : t("message.unknown"),
      ),
    ),
  ].join(", ");
  return (
    <div className="cv-sent-group" data-open={open || undefined} data-live={running || undefined}>
      <MessageGroupHead
        count={count}
        senders={recipients}
        open={open}
        bodyId={bodyId}
        onToggle={() => setOpen((value) => !value)}
        className={`cv-sent-group__head${running ? " is-live" : ""}`}
        ariaLabel={[count, recipients].join(". ")}
        mark={failed ? <AlertCircle /> : <Envelope />}
      />
      {open && (
        <div className="cv-sent-group__body" id={bodyId}>
          {entries.length > SEND_PAGE_SIZE ? <SentPages entries={entries}>{children}</SentPages> : children}
        </div>
      )}
    </div>
  );
}

/// Rendering page size only: a large group keeps every message (an MCP send's receipt is complete,
/// acpmuxMcpSends.ts) and mounts one page of their rows at a time.
export const SEND_PAGE_SIZE = 32;

/// An open group of more than SEND_PAGE_SIZE messages: one page of their rows and a pager on the
/// rows' grid. While Find has matches here, the group mounts exactly the rows that hold them, each
/// given the match, so Find's Next walks every one as it does in an unpaged group; a match only in a
/// call's receipt goes to that call's first message alone, so one Raw opens, not one per message.
function SentPages({ entries, children }: { entries: readonly SentEntry[]; children: ReactNode }) {
  const t = useT();
  const rows = Children.toArray(children);
  const [page, setPage] = useState(0);
  const reveal = useContext(FindReveal);
  const matches = useMemo((): number[] => {
    if (!reveal) return [];
    const firsts = new Map<AcpmuxActivity, number>();
    for (const [at, { item }] of entries.entries()) if (!firsts.has(item)) firsts.set(item, at);
    if (reveal.toolId !== undefined)
      return [...firsts].filter(([item]) => item.tool?.id === reveal.toolId).map(([, at]) => at);
    const own = (entry: SentEntry) =>
      entry.type === "send" &&
      [entry.send.target, entry.send.text, entry.send.file].some(
        (value) => value !== undefined && foldFind(value).includes(reveal.needle),
      );
    // Every message of a batch shares its call: each call's text is folded once, not per message.
    const calls = new Map<AcpmuxActivity, boolean>();
    const inCall = (item: AcpmuxActivity) => {
      let hit = calls.get(item);
      if (hit === undefined) calls.set(item, (hit = foldFind(activityText(item)).includes(reveal.needle)));
      return hit;
    };
    const out = new Set<number>();
    const reached = new Set<AcpmuxActivity>();
    for (const [at, entry] of entries.entries())
      if (own(entry) || (entry.type !== "send" && inCall(entry.item))) {
        out.add(at);
        reached.add(entry.item);
      }
    for (const [item, at] of firsts) if (!reached.has(item) && inCall(item)) out.add(at);
    return [...out].sort((x, y) => x - y);
  }, [reveal, entries]);
  if (matches.length)
    return (
      <>
        {matches.map((at) => (
          <FindReveal.Provider key={at} value={reveal}>
            {rows[at]}
          </FindReveal.Provider>
        ))}
      </>
    );
  const lastPage = Math.max(0, Math.ceil(rows.length / SEND_PAGE_SIZE) - 1);
  const current = Math.min(page, lastPage);
  const start = current * SEND_PAGE_SIZE;
  const end = Math.min(start + SEND_PAGE_SIZE, rows.length);
  return (
    <>
      {rows.slice(start, end).map((row, at) => (
        <FindReveal.Provider key={start + at} value={undefined}>
          {row}
        </FindReveal.Provider>
      ))}
      <div className="cv-send-batch__pages" data-find-skip="">
        <button
          type="button"
          className="cv-subsession__toggle"
          data-send-page="previous"
          disabled={current === 0}
          onClick={() => setPage(current - 1)}
        >
          {t("find.previous")}
        </button>
        <span aria-live="polite">
          {/* l10n-allow: the range's punctuation; its surrounding sentence is localized. */}
          {t("find.count", { current: `${start + 1}–${end}`, total: rows.length })}
        </span>
        <button
          type="button"
          className="cv-subsession__toggle"
          data-send-page="next"
          disabled={current === lastPage}
          onClick={() => setPage(current + 1)}
        >
          {t("find.next")}
        </button>
      </div>
    </>
  );
}

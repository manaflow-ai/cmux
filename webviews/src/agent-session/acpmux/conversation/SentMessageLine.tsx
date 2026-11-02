// A message this agent sent another one, as one tool row: "Sending message to tests" with the
// working spinner while it goes out, "Sent message to tests" with the envelope once it went, and
// "Couldn't send to tests" when it failed; then how it was delivered, when the call says ("· queued"),
// and the message's first line, muted, while the row is shut. The row opens to the whole message as
// Markdown, its first line then gone from the row (Leo 2026-10-29, on the line and the body under it
// saying the same thing: "this rendering can be better for sent stuff"), and, behind Raw, the call itself (its command and output, or its MCP request and response); a failed send
// opens to its output. A send whose words the transcript does not hold opens straight to the call,
// with no Raw toggle. Both ways of sending draw this one row: a cmux-subsessions `send_message`
// (SubsessionCallCard.tsx) and a shell `acpmux send` (acpmuxSends.ts, `AcpmuxSendLine` below).
// Whether a row is open lasts across the virtualized transcript (transcriptDisclosure.tsx). The
// target opens its chat beside this one when the session list knows it (by id, or by `name`,
// `host/name` or `host:name`); otherwise it is plain text. A shell call that also ran other
// commands says so ("· and 2 more commands"), its whole command behind Raw: no work is hidden.
import {
  type KeyboardEvent,
  type ReactNode,
  useContext,
  useEffect,
  useId,
  useMemo,
  useState,
  useSyncExternalStore,
} from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import type { AcpmuxSendCallPart, SendState } from "./acpmuxSends";
import { messagePreview } from "./AgentMessageRow";
import { messageDelivery } from "./agentMessages";
import { useFindReveal } from "./chatFind";
import { AlertCircle, ChevronRight, Envelope } from "./icons";
import { AgentMessageBody } from "./AgentMessageBody";
import { AgentTag } from "./AgentTag";
import { SentActions } from "./MessageActions";
import { acpmuxMcpSendCall } from "./acpmuxMcpSends";
import { McpCallDetails } from "./McpCallRows";
import { mcpCall, mcpRawName } from "./mcpCalls";
import { ShellBlock } from "./ShellBlock";
import { useTranscriptDisclosure } from "./transcriptDisclosure";
import { SubsessionContext, SubsessionStore } from "../subagents/subsessions";
import "./AgentMessageRow.css";
import "./SubsessionCallCard.css";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// How the line reads. `sentence`, the default: "Sent to tests", then the first line muted
/// (Leo 2026-10-24: "sending message or sent message to X or Y"). The others are gallery versions
/// kept beside it (SentMessageLine.gallery.ts): `arrow`, "→ tests: <first line>" (#24977's line),
/// and `quote`, "Sent to tests: “<first line>”". The native host sends no value.
export type SentLook = "sentence" | "arrow" | "quote";

const LOOKS: readonly SentLook[] = ["sentence", "arrow", "quote"];
let look: SentLook = "sentence";
const listeners = new Set<() => void>();

/// The theme carried a look: the transcript follows at once. Anything else keeps the default.
export function configureSentLook(value: unknown): void {
  const next = LOOKS.find((one) => one === value) ?? "sentence";
  if (next === look) return;
  look = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => look;

/// The listed chat a send's target names: its id when the call gives it, else the chat with that
/// name, on that host for `host/name` or `host:name` (a basket such as `reports:leo` is no chat).
export function targetChat(store: SubsessionStore, target: string, sessionId?: string): string | undefined {
  if (sessionId) return store.has(sessionId) ? sessionId : undefined;
  // A peer's chat is listed as `host/name` (acpmux hub/peers.rs); a send may name a chat by its id.
  const listed = store.find(target);
  if (listed) return listed;
  if (store.has(target)) return target;
  const split = /^([^/:]+)[/:](.+)$/.exec(target);
  if (!split) return undefined;
  const id = store.find(`${split[1]}/${split[2]}`) ?? store.find(split[2]!);
  return id && (store.find(`${split[1]}/${split[2]}`) === id || store.host(id) === split[1]) ? id : undefined;
}

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
  const [open, setOpen] = useTranscriptDisclosure(disclosureKey);
  const [rawShown, setRawShown] = useState(rawOpen);
  // A send that fails while it shows opens its Raw then: the output says why.
  useEffect(() => {
    if (rawOpen) setRawShown(true);
  }, [rawOpen]);
  const [reveal, setReveal] = useState(0);
  // Find in Chat opens the row and its Raw: the match may be in the command or its output.
  useFindReveal(
    useMemo((): AcpmuxActivity[] => [{ kind: "tool", text: tool.title, tool }], [tool]),
    () => {
      setOpen(true);
      setRawShown(true);
      setReveal((value) => value + 1);
    },
  );
  const id = useId();
  const chats = useContext(SubsessionContext);
  const store = chats?.store ?? NO_STORE;
  const readChat = () => targetChat(store, target, targetSession);
  const chat = useSyncExternalStore(store.subscribeNames, readChat, readChat);
  const preview = text ? messagePreview(text) : "";
  // The open row shows the whole message under it: its first line on the row would say it twice.
  const trailing = preview && state !== "failed" && !(open && text) ? preview : "";
  // No words to show, only where they came from: the file's path, as code, after the line.
  const source = !text && file && state !== "failed" ? file : "";
  const label =
    shape === "arrow" && (state === "sending" || state === "sent") && preview
      ? t(state === "sending" ? "subsession.sending" : "subsession.to", { name: MARK, text: preview })
      : sendLabel(t, state);
  const [before, after = ""] = label.split(MARK);
  // The recipient as every message row draws it: a chip, and a button when its chat is known.
  const name =
    chat && chats ? (
      <AgentTag
        name={target}
        className="cv-agentmsg__name cv-recipient cv-sent__target"
        title={t("subagents.open", { name: target })}
        onClick={(event) => {
          event.stopPropagation();
          (chats.openSender ?? chats.open)(chat);
        }}
      />
    ) : (
      <span className="cv-agentmsg__name cv-recipient is-plain">{target}</span>
    );
  const more = others === 1 ? t("send.moreOne") : others > 1 ? t("send.more", { n: others }) : undefined;
  const toggle = () => setOpen((value) => !value);
  const icon = state === "failed" ? <AlertCircle /> : <Envelope />;
  return (
    <>
      {/* A div, not a button: the target inside it is a button of its own. */}
      <div
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        role="button"
        tabIndex={0}
        className={`cv-tool is-toggle cv-subsession cv-sent${state === "sending" ? " is-live" : " is-strong"}`}
        data-send-state={state}
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        onClick={toggle}
        onKeyDown={(event: KeyboardEvent) => {
          if (event.target !== event.currentTarget || (event.key !== "Enter" && event.key !== " ")) return;
          event.preventDefault();
          toggle();
        }}
      >
        <span className={`cv-tool__icon${state === "failed" ? " cv-tool__failed" : ""}`}>{icon}</span>
        {/* The spaces are part of the accessible sentence; flex gap supplies their visual spacing. */}
        <span className="cv-agentmsg__sentence">
          {before.trim() && <span className="cv-agentmsg__words">{before.trim()}</span>}
          {before.trim() && " "}
          {name}
          {after.trim() && " "}
          {after.trim() && <span className="cv-agentmsg__words">{after.trim()}</span>}
          {more && " "}
          {more && <span className="cv-tool__detail cv-sent__more">{`· ${more}`}</span>}
          {shape !== "arrow" && trailing && " "}
          {shape === "quote" && trailing && (
            // l10n-allow: punctuation around the message's own words.
            <span className="cv-agentmsg__preview cv-sent__preview">{`“${trailing}”`}</span>
          )}
          {shape === "sentence" && trailing && (
            <span className="cv-agentmsg__preview cv-sent__preview">{trailing}</span>
          )}
          {source && (
            <>
              {" "}
              <code className="cv-tool__detail cv-sent__preview cv-sent__file" title={source}>
                {source}
              </code>
            </>
          )}
        </span>
        {/* Copy takes the message's text, shown while the row is pointed at, as a SendMessage
            row's is (MessageCard.tsx); its click never toggles the row. */}
        {text && (
          // oxlint-disable-next-line jsx-a11y/no-static-element-interactions, jsx-a11y/click-events-have-key-events
          <span onClick={(event) => event.stopPropagation()}>
            <SentActions text={text} />
          </span>
        )}
        {detail && " "}
        {detail && (
          <span className="cv-tool__trail">
            <span className="cv-command__meta cv-agentmsg__status">
              <span className="cv-row-status">{detail}</span>
            </span>
          </span>
        )}
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </div>
      {open && (
        <div id={id} className="cv-subsession__under">
          {text ? (
            <>
              <div className="cv-subsession__markdown selectable">
                <AgentMessageBody text={text} commits="quiet" />
              </div>
              <RawToggle open={rawShown} onOpenChange={setRawShown}>
                {raw(reveal)}
              </RawToggle>
            </>
          ) : (
            // No words to render: the call is all there is, so it shows at once, not behind a
            // second "Raw" click (Leo 2026-10-26: "EITHER SHOW IT DIRECT WITHOUT OR ... RENDER IT").
            <div className="cv-subsession__raw">{raw(reveal)}</div>
          )}
        </div>
      )}
    </>
  );
}

/// "Raw" and the call under it while open: its own state, or the caller's (`open`, `onOpenChange`).
export function RawToggle({
  children,
  startOpen = false,
  open: shown,
  onOpenChange,
}: {
  children: ReactNode;
  startOpen?: boolean;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
}) {
  const t = useT();
  const [own, setOwn] = useState(startOpen);
  const open = shown ?? own;
  const setOpen = (next: (value: boolean) => boolean) => (onOpenChange ? onOpenChange(next(open)) : setOwn(next));
  const id = useId();
  return (
    <div className="cv-subsession__raw">
      <button
        type="button"
        className="cv-subsession__toggle"
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        onClick={() => setOpen((value) => !value)}
      >
        {t("subsession.raw")}
        <ChevronRight size={12} strokeWidth={1.4} className={`cv-rotor${open ? " is-open" : ""}`} />
      </button>
      {open && <div id={id}>{children}</div>}
    </div>
  );
}

/// A message's disclosure and React key: the call's id, and for one message of a batch its place
/// in the batch, so each message of one call opens on its own.
export function sendKey(id: string, index?: number): string {
  return index === undefined ? id : `${id}#${index}`;
}

/// A message sent by a shell `acpmux send` (acpmuxSends.ts), one of a shell batch's, or one of an
/// acpmux MCP send's batch (acpmuxMcpSends.ts), as the sent-message row; Raw holds the call as it
/// was made: its Shell card, the whole command line for every message of a batch, or the MCP
/// request and response.
export function AcpmuxSendLine({ tool, send }: { tool: Tool; send: AcpmuxSendCallPart }) {
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
      others={send.others}
      rawOpen={send.state === "failed"}
      raw={(reveal) => <SendRaw tool={tool} reveal={reveal} live={send.state === "sending"} />}
    />
  );
}

/// The call behind a send row's Raw: a shell call's command and output, an MCP call's request and
/// response.
function SendRaw({ tool, reveal, live }: { tool: Tool; reveal: number; live: boolean }) {
  const id = useId();
  const call = useMemo(() => (tool.command ? undefined : (mcpCall(tool) ?? acpmuxMcpSendCall(tool))), [tool]);
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
  return (
    <ShellBlock command={tool.command} output={tool.output} exitCode={tool.exitCode} live={live} reveal={reveal} />
  );
}

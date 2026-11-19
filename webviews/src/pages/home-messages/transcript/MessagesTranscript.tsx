// One conversation of the Messages view: the header, the transcript and the compose bar (a port of
// HomeNativeTranscriptView over MessagesLabHomeView; data contract: plans/cmux-next/home-mac.md).
//
// What it reads: the conversation, me, its confirmed messages and my pending sends, the others' read
// cursors, who types, who views, whether older messages exist, the connection. What it emits: a
// send, the read cursor (only forward, only while the newest message shows in a visible, focused
// window), "load older" once per page when the reader reaches the top, retry and discard of a
// failed send, and tapbacks. It writes no model of its own.
//
// Cost: the rows derive in one pass over the loaded window (rows.ts), and only the rows near the
// viewport render (useTimelineWindow), so a chat of 10,000 messages opens as one of 10 does. A send
// moves the rows above it together: the stack is moved by the new row's height in the same frame
// the window scrolls, then eases back to rest, so nothing jumps and nothing pops in after.
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { MOTION_MS } from "../../../motion/scale.generated";
import { AttachmentContext } from "../../home-channels/AttachmentViews";
import type { AttachmentService } from "../../home-channels/attachmentService";
import { conversationName } from "../../home-channels/model";
import type { Connection } from "../../home-channels/store";
import type { HomeAttachment, HomeMessage } from "../../home-channels/types";
import { useTimelineWindow } from "../../home-channels/useTimelineWindow";
import type { Strings } from "../../shared/i18n";
import { WEB_SWAP_KEPT_SCROLL } from "../../shared/webSwap";
import { bubbleStyle, type BubbleLook, type ChatColors } from "./colors";
import { historyEntries } from "./history";
import { MessageComposer, dragOffersFiles, type DictationCall, type MessageComposerHandle } from "./MessageComposer";
import { estimateRow, RowCache, transcriptRows, type TranscriptData, type TranscriptRow } from "./rows";
import { TranscriptHeader, alsoHereNames, type HeaderPanelItem } from "./TranscriptHeader";
import { TranscriptRowView, type RowActions } from "./TranscriptRows";
import "./transcript.css";

/** The room the header takes over the rows (its avatar, pill and padding). */
const HEADER_ROOM = 76;
const TOP_KEY = "top";

export interface MessagesTranscriptProps extends TranscriptData {
  strings: Strings;
  connection: Connection;
  /** Participant ids viewing the conversation (presence). */
  viewing?: readonly string[];
  look?: BubbleLook;
  /** This chat's own colours (Chat Colors) over the look's. */
  colors?: ChatColors;
  panels?: readonly HeaderPanelItem[];
  onPanel?(id: string): void;
  onContact?(): void;
  /** A section pinned under the header (Needs you); it lies over the rows. */
  pinned?: ReactNode;
  /** The page's attachment service: images draw, files attach. Absent: named rows only, no +. */
  attachments?: AttachmentService;
  dictation?: DictationCall;
  initialDraft?: string;
  onDraftChange?(text: string): void;
  onSend(text: string, attachments?: readonly HomeAttachment[]): Promise<boolean>;
  onLoadOlder(): void;
  /** My read cursor moves forward to `seq`. */
  onRead?(seq: number): void;
  onRetry?(key: string): void;
  onDiscard?(key: string): void;
  onReact?(message: HomeMessage, partIndex: number, value: string, tapback: string): void;
  onCopy?(text: string): void;
  /** The clock for day labels (the gallery's); default: now. */
  now?: number;
}

const reducedMotion = () => {
  const gate = document.documentElement.dataset.cmuxMotion;
  return gate === "off" || gate === "reduced" || window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
};

export function MessagesTranscript(props: MessagesTranscriptProps) {
  const {
    strings,
    me,
    conversation,
    messages,
    connection,
    look = "imessage",
    colors,
    attachments,
    pinned,
    onLoadOlder,
    onRead,
  } = props;
  const [clock] = useState(() => Date.now());
  const now = props.now ?? clock;
  // Unchanged messages keep their rows and their window entries: a change costs the messages it touches.
  const [cache] = useState(() => new RowCache());
  const [estimates] = useState(() => new WeakMap<TranscriptRow, { key: string; estimate: number }>());
  const rows = useMemo(
    () =>
      transcriptRows(
        {
          me,
          conversation,
          messages,
          pending: props.pending,
          readCursors: props.readCursors,
          typing: props.typing,
          draft: props.draft,
          hasOlder: props.hasOlder,
          loadingOlder: props.loadingOlder,
        },
        now,
        cache,
      ),
    [
      cache,
      me,
      conversation,
      messages,
      props.pending,
      props.readCursors,
      props.typing,
      props.draft,
      props.hasOlder,
      props.loadingOlder,
      now,
    ],
  );
  const [pinnedHeight, setPinnedHeight] = useState(0);
  const sized = useMemo(() => {
    const out = [{ key: TOP_KEY, estimate: HEADER_ROOM + pinnedHeight }];
    for (const row of rows) {
      let entry = estimates.get(row);
      if (!entry) {
        entry = { key: row.key, estimate: estimateRow(row) };
        estimates.set(row, entry);
      }
      out.push(entry);
    }
    return out;
  }, [rows, pinnedHeight, estimates]);
  const { items, total, scroller, measure, onScroll } = useTimelineWindow(sized, conversation.id);
  const people = useMemo(() => new Map(conversation.participants.map((p) => [p.id, p])), [conversation.participants]);
  const composer = useRef<MessageComposerHandle | null>(null);
  const stack = useRef<HTMLDivElement | null>(null);
  const [dropping, setDropping] = useState(false);

  const actions = useMemo<RowActions>(
    () => ({
      onRetry: props.onRetry,
      onDiscard: props.onDiscard,
      onReact: props.onReact,
      onCopy: props.onCopy ?? ((text) => void navigator.clipboard?.writeText(text)),
    }),
    [props.onRetry, props.onDiscard, props.onReact, props.onCopy],
  );

  // A send (new rows at the end while the reader is at the newest): the window already scrolled by
  // the new rows' height this frame; the stack starts that far down and eases up, so every row above
  // moves together with the new one.
  const motion = useRef({ lastKey: "", total: 0, atBottom: true, conversation: "" });
  useLayoutEffect(() => {
    const state = motion.current;
    const element = scroller.current;
    const lastKey = rows.at(-1)?.key ?? "";
    const delta = total - state.total;
    const sameConversation = state.conversation === conversation.id;
    if (sameConversation && state.atBottom && lastKey !== state.lastKey && delta > 0 && delta < 600 && !reducedMotion())
      stack.current?.animate?.([{ transform: `translateY(${delta}px)` }, { transform: "translateY(0)" }], {
        // A structural move: the standard step (a raw 240 ms until Leo 2026-11-10: "the slow animations").
        duration: MOTION_MS.standard,
        easing: "cubic-bezier(0.2, 0.9, 0.3, 1)",
      });
    state.lastKey = lastKey;
    state.total = total;
    state.conversation = conversation.id;
    if (element) state.atBottom = element.scrollHeight - element.scrollTop - element.clientHeight < 48;
  });

  // The read cursor: forward only, while the newest confirmed message shows in a visible, focused window.
  const lastSeq = messages.at(-1)?.seq ?? 0;
  const lastId = messages.at(-1)?.id;
  const sentRead = useRef<{ conversation: string; seq: number }>({ conversation: "", seq: 0 });
  const readIfShown = () => {
    const element = scroller.current;
    if (!onRead || !element || !lastId || document.visibilityState !== "visible" || !document.hasFocus()) return;
    const sent = sentRead.current;
    if (sent.conversation === conversation.id && sent.seq >= lastSeq) return;
    const row = element.querySelector(`[data-key^="part:${CSS.escape(lastId)}:"]`);
    if (!row) return;
    const box = row.getBoundingClientRect();
    const view = element.getBoundingClientRect();
    if (box.bottom <= view.top || box.top >= view.bottom) return;
    sentRead.current = { conversation: conversation.id, seq: lastSeq };
    onRead(lastSeq);
  };
  const readRef = useRef(readIfShown);
  readRef.current = readIfShown;
  useEffect(() => readRef.current());
  useEffect(() => {
    const check = () => readRef.current();
    window.addEventListener("focus", check);
    document.addEventListener("visibilitychange", check);
    return () => {
      window.removeEventListener("focus", check);
      document.removeEventListener("visibilitychange", check);
    };
  }, []);

  // The pinned section's height: the top row grows by it, so the oldest message scrolls clear of it.
  const pinnedBox = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    const element = pinnedBox.current;
    if (!element) return setPinnedHeight(0);
    const observer = new ResizeObserver(() => setPinnedHeight(element.offsetHeight ? element.offsetHeight + 8 : 0));
    observer.observe(element);
    return () => observer.disconnect();
  }, [pinned]);

  const title = conversationName(conversation, me);
  const other = conversation.kind === "group" ? undefined : conversation.participants.find((p) => p.id !== me);
  const alsoHere = alsoHereNames(props.viewing ?? [], conversation.participants, me, strings.language);
  const history = () => historyEntries(messages, me);
  const style = { ...bubbleStyle(colors), "--mt-top-room": `${HEADER_ROOM + pinnedHeight}px` } as CSSProperties;

  return (
    <AttachmentContext.Provider value={attachments}>
      <section
        className={`mt-transcript look-${look}${dropping ? " dropping" : ""}`}
        style={style}
        aria-label={strings.t("ax.messages")}
        onDragOver={(event) => {
          if (!attachments || !dragOffersFiles(event.dataTransfer.types)) return;
          event.preventDefault();
          event.dataTransfer.dropEffect = "copy";
          setDropping(true);
        }}
        onDragLeave={(event) => {
          if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setDropping(false);
        }}
        onDrop={(event) => {
          setDropping(false);
          if (!attachments || event.dataTransfer.files.length === 0) return;
          event.preventDefault();
          composer.current?.addFiles(event.dataTransfer.files);
        }}
      >
        <div
          ref={scroller}
          className="mt-scroller"
          {...{ [WEB_SWAP_KEPT_SCROLL]: "end" }}
          onScroll={() => {
            if (onScroll() && props.hasOlder && !props.loadingOlder) onLoadOlder();
            readRef.current();
          }}
          role="log"
          aria-live="polite"
        >
          <div ref={stack} className="mt-stack" style={{ height: total }}>
            {items.map((item) => {
              const row = item.index > 0 ? rows[item.index - 1]! : undefined;
              return (
                <div
                  key={item.key}
                  data-key={item.key}
                  ref={measure}
                  className="mt-slot"
                  style={{ transform: `translateY(${item.start}px)` }}
                >
                  {row ? (
                    <TranscriptRowView
                      row={row}
                      me={me}
                      strings={strings}
                      now={now}
                      people={people}
                      actions={actions}
                    />
                  ) : (
                    <div className="mt-top" style={{ height: HEADER_ROOM + pinnedHeight }} />
                  )}
                </div>
              );
            })}
          </div>
        </div>
        <TranscriptHeader
          title={title}
          participant={other}
          alsoHere={alsoHere}
          panels={props.panels}
          onPanel={props.onPanel}
          onContact={props.onContact}
          strings={strings}
        />
        {pinned && (
          <div ref={pinnedBox} className="mt-pinned">
            {pinned}
          </div>
        )}
        {dropping && <div className="mt-drop-highlight" aria-hidden />}
        <MessageComposer
          ref={composer}
          strings={strings}
          sendEnabled={connection === "online"}
          onSend={props.onSend}
          attachments={attachments ? { service: attachments, conversation: conversation.id } : undefined}
          history={history}
          dictation={props.dictation}
          initialText={props.initialDraft}
          onDraftChange={props.onDraftChange}
          key={conversation.id}
        />
      </section>
    </AttachmentContext.Provider>
  );
}

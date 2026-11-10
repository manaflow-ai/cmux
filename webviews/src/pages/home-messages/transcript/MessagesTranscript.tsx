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
import type { PrepareFile } from "./prepareAttachment";
import {
  useEffect,
  useImperativeHandle,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode,
  type Ref,
} from "react";
import type { ToastAvoidanceReports } from "../../../agent-session/acpmux/toastAvoidance";
import { AttachmentContext } from "../../home-channels/AttachmentViews";
import type { AttachmentService } from "../../home-channels/attachmentService";
import { conversationName } from "../../home-channels/model";
import type { Connection } from "../../home-channels/store";
import type { HomeAttachment, HomeMessage } from "../../home-channels/types";
import { useTimelineWindow } from "../../home-channels/useTimelineWindow";
import type { Strings } from "../../shared/i18n";
import { WEB_SWAP_KEPT_SCROLL } from "../../shared/webSwap";
import type { FileDropTarget } from "../nav";
import type { AttachmentDrafts } from "./attachmentDrafts";
import { bubbleStyle, type BubbleLook, type ChatColors } from "./colors";
import { historyEntries } from "./history";
import { withExtras, type ShownRow, type TranscriptExtras } from "./extras";
import {
  MessageComposer,
  dragOffersFiles,
  type ComposerChief,
  type DictationCall,
  type MessageComposerHandle,
} from "./MessageComposer";
import { pinnedLayout, PINNED_GAP } from "./pinnedLayout";
import { estimateRow, RowCache, transcriptRows, type TranscriptData, type TranscriptRow } from "./rows";
import { TranscriptHeader, alsoHereNames, type HeaderPanelItem, type TranscriptHeaderProps } from "./TranscriptHeader";
import type { ReplyQuote } from "./replyQuote";
import { TranscriptRowView, type RowActions, type RowLinks } from "./TranscriptRows";
import type { BubbleContext, BubbleHostFacts, FileAction, FileTarget } from "./bubbleMenu";
import { NO_BUBBLE_HOST } from "./bubbleMenu";
import { MediaViewerHost } from "../viewer/MediaViewer";
import { useWidgetKeep } from "../cards/widget/widgetService";
import "./transcript.css";

/** The room the header takes over the rows (its avatar, pill and padding). */
const HEADER_ROOM = 76;
const TOP_KEY = "top";

/** What the page asks of a shown transcript. */
export interface MessagesTranscriptHandle {
  /** The message box takes the keyboard; true when it did. */
  focusComposer(): boolean;
  /** The compose bar, for what the app hands over (composerHandoff.ts). */
  composer(): MessageComposerHandle | null;
  /** Files dragged over the conversation list come here, with this transcript's drop highlight;
   * undefined when it takes no files. */
  fileDrop: FileDropTarget | undefined;
}

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
  onContact?(anchor: { x: number; y: number; width: number; height: number }): void;
  /** A Chief chat's face and location chip in the header (``TranscriptHeader``). */
  face?: TranscriptHeaderProps["face"];
  place?: TranscriptHeaderProps["place"];
  onPlace?: TranscriptHeaderProps["onPlace"];
  /** A section pinned under the header (Needs you); it lies over the rows. */
  pinned?: ReactNode;
  /** A Chief's Set Up cmux card (cards/setup/setupHost.tsx), under `pinned` and over the rows; both stop
   * above the message box and keep it its room (pinnedLayout.ts). */
  setupCard?: ReactNode;
  /** The page's attachment service: images draw, files attach. Absent: named rows only, no +. */
  attachments?: AttachmentService;
  /** What each attached file goes through before it uploads (the app's location removal). */
  prepareFile?: PrepareFile;
  dictation?: DictationCall;
  /** The app's toasts rest above the composer (MessageComposer `toastAvoidance`). */
  toastAvoidance?: ToastAvoidanceReports | undefined;
  /** The page's files per conversation (they outlive this conversation's composer); absent: the composer's own. */
  attachmentDrafts?: AttachmentDrafts;
  initialDraft?: string;
  onDraftChange?(text: string): void;
  onSend(text: string, attachments?: readonly HomeAttachment[]): Promise<boolean>;
  onLoadOlder(): void;
  /** My read cursor moves forward to `seq`. */
  onRead?(seq: number): void;
  onRetry?(key: string): void;
  onDiscard?(key: string): void;
  /** Cancel Upload on a send still going (its row's menu). */
  canCancelUpload?(key: string): boolean;
  onCancelUpload?(key: string): void;
  onReact?(message: HomeMessage, partIndex: number, value: string, tapback?: string): void;
  onCopy?(text: string): void;
  /** Reply… on a message (its thread opens, the reply answering it); absent: no Reply. */
  onReply?(message: HomeMessage): void;
  /** Delete on my committed message in a Chief chat (bubbleMenu `canDeleteMessage`). */
  onDelete?(message: HomeMessage): void;
  /** Retry Reply: the Chief answers my message again. */
  onRetryReply?(message: HomeMessage): void;
  onForward?(text: string): void;
  onShare?(item: { text: string } | { url: string }): void;
  /** A path link's or an attachment's file row (the host runs it). */
  onFile?(action: FileAction, target: FileTarget): void;
  /** What the app offers the bubbles' menus (Copy Link's scheme, Forward…, Share…, Retry Reply, file rows). */
  bubbleHost?: BubbleHostFacts;
  /** Reply to Selection on a message's selected words (its thread opens with the quote). */
  onReplyToSelection?(message: HomeMessage, quote: ReplyQuote): void;
  /** "N Replies" under a message: its thread, or in a thread its branch, opens. */
  onOpenReplies?(message: string): void;
  /** The quote the next send carries, on its card above the field. */
  quote?: { text: string; name?: string };
  onRemoveQuote?(): void;
  /** The composer's placeholder (a thread's says Reply). */
  composerPlaceholder?: string;
  /** The message box checks spelling (Settings). */
  spellChecking?: boolean;
  /** The clock for day labels (the gallery's); default: now. */
  now?: number;
  /** A message a link or the host opened at: it scrolls into view, marked. */
  highlight?: string;
  /** What shows in place of the rows while the conversation has none (a Chief's first run). */
  empty?: ReactNode;
  /** A new value starts the message box again from `initialDraft` (a draft set from outside). */
  composerKey?: string;
  /** Link chips in people's text: their previews and opening. Absent: plain text. */
  links?: RowLinks;
  /** A Chief's permission cards: their state and the app's decision. Absent: cards without buttons. */
  approvals?: RowActions["approvals"];
  /** Rows the page adds (an agents row under its message, the Chief's status line at the end). */
  extras?: TranscriptExtras;
  /** A Chief's Stop, Escape and Continue in the message box (chiefTurn.ts). */
  chief?: ComposerChief;
  /** A toast over the message box; the newest message keeps clear of it (the toast room). */
  toast?: ReactNode;
  ref?: Ref<MessagesTranscriptHandle>;
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
    setupCard,
    onLoadOlder,
    onRead,
    highlight,
    empty,
    links,
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
          ...(props.replyCounts ? { replyCounts: props.replyCounts } : {}),
          ...(props.threadMode ? { threadMode: true } : {}),
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
      props.replyCounts,
      props.threadMode,
      now,
    ],
  );
  useWidgetKeep(messages);
  const [pinnedHeight, setPinnedHeight] = useState(0);
  // A toast over the message box takes room under the newest message (+ToastRoom.swift): a row of
  // its height ends the transcript while it shows, so the rows move up with it and back down after.
  const [toastHeight, setToastHeight] = useState(0);
  const toastBox = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    const element = toastBox.current;
    if (!element) return setToastHeight(0);
    const observer = new ResizeObserver(() => setToastHeight(element.offsetHeight ? element.offsetHeight + 8 : 0));
    observer.observe(element);
    return () => observer.disconnect();
  }, [props.toast]);
  const extras = useMemo<TranscriptExtras | undefined>(() => {
    if (!toastHeight) return props.extras;
    const room = {
      key: "toast-room",
      estimate: toastHeight,
      node: <div style={{ height: toastHeight }} aria-hidden />,
    };
    return { ...props.extras, tail: [...(props.extras?.tail ?? []), room] };
  }, [props.extras, toastHeight]);
  const shown = useMemo(() => withExtras(rows, extras), [rows, extras]);
  const sized = useMemo(() => {
    const out = [{ key: TOP_KEY, estimate: HEADER_ROOM + pinnedHeight }];
    for (const row of shown) {
      if (row.kind === "extra") {
        out.push({ key: row.key, estimate: row.estimate });
        continue;
      }
      let entry = estimates.get(row);
      if (!entry) {
        entry = { key: row.key, estimate: estimateRow(row) };
        estimates.set(row, entry);
      }
      out.push(entry);
    }
    return out;
  }, [shown, pinnedHeight, estimates]);
  // The highlighted message's first row: the window scrolls it to the middle once.
  const focusKey = useMemo(
    () => (highlight ? rows.find((row) => row.kind === "bubble" && row.message.id === highlight)?.key : undefined),
    [rows, highlight],
  );
  const { items, total, scroller, measure, onScroll } = useTimelineWindow(sized, conversation.id, focusKey);
  const people = useMemo(() => new Map(conversation.participants.map((p) => [p.id, p])), [conversation.participants]);
  const composer = useRef<MessageComposerHandle | null>(null);
  const stack = useRef<HTMLDivElement | null>(null);
  const [dropping, setDropping] = useState(false);

  // The menus read the conversation's facts as they open: a typing change or a reconnect re-renders no row.
  const facts = useRef<BubbleContext>(undefined as unknown as BubbleContext);
  facts.current = {
    me,
    conversation,
    online: connection === "online",
    typing: (props.typing ?? []).some((person) => person !== me) || props.draft !== undefined,
    host: props.bubbleHost ?? NO_BUBBLE_HOST,
  };
  const actions = useMemo<RowActions>(
    () => ({
      onRetry: props.onRetry,
      onDiscard: props.onDiscard,
      ...(props.canCancelUpload ? { canCancelUpload: props.canCancelUpload } : {}),
      ...(props.onCancelUpload ? { onCancelUpload: props.onCancelUpload } : {}),
      onReact: props.onReact,
      onCopy: props.onCopy ?? ((text) => void navigator.clipboard?.writeText(text)),
      ...(props.onReply ? { onReply: props.onReply } : {}),
      ...(props.onDelete ? { onDelete: props.onDelete } : {}),
      ...(props.onRetryReply ? { onRetryReply: props.onRetryReply } : {}),
      ...(props.onForward ? { onForward: props.onForward } : {}),
      ...(props.onShare ? { onShare: props.onShare } : {}),
      ...(props.onFile ? { onFile: props.onFile } : {}),
      ...(props.onReplyToSelection ? { onReplyToSelection: props.onReplyToSelection } : {}),
      ...(props.onOpenReplies ? { onOpenReplies: props.onOpenReplies } : {}),
      ...(links ? { links } : {}),
      ...(props.approvals ? { approvals: props.approvals } : {}),
      context: () => facts.current,
    }),
    [
      props.onRetry,
      props.onDiscard,
      props.canCancelUpload,
      props.onCancelUpload,
      props.onReact,
      props.onCopy,
      props.onReply,
      props.onDelete,
      props.onRetryReply,
      props.onForward,
      props.onShare,
      props.onFile,
      props.onReplyToSelection,
      props.onOpenReplies,
      links,
      props.approvals,
    ],
  );
  const fileDrop: FileDropTarget | undefined = attachments
    ? {
        over: (types) => {
          if (!dragOffersFiles(types)) return false;
          setDropping(true);
          return true;
        },
        leave: () => setDropping(false),
        drop: (files) => {
          setDropping(false);
          composer.current?.addFiles(files);
        },
      }
    : undefined;
  useImperativeHandle(props.ref, () => ({
    focusComposer: () => {
      if (!composer.current) return false;
      composer.current.focus();
      return true;
    },
    composer: () => composer.current,
    fileDrop,
  }));

  // A send (new rows at the end while the reader is at the newest): the window already scrolled by
  // the new rows' height this frame; the stack starts that far down and eases up, so every row above
  // moves together with the new one.
  const motion = useRef({ lastKey: "", total: 0, atBottom: true, conversation: "" });
  useLayoutEffect(() => {
    const state = motion.current;
    const element = scroller.current;
    const lastKey = shown.at(-1)?.key ?? "";
    const delta = total - state.total;
    const sameConversation = state.conversation === conversation.id;
    if (sameConversation && state.atBottom && lastKey !== state.lastKey && delta > 0 && delta < 600 && !reducedMotion())
      stack.current?.animate?.([{ transform: `translateY(${delta}px)` }, { transform: "translateY(0)" }], {
        duration: 240,
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
  }, [pinned, setupCard]);
  // The room above the message box, and the natural heights of the pinned section and the card:
  // pinnedLayout.ts shares that room out (the native layoutPinnedSection).
  const pinnedContent = useRef<HTMLDivElement | null>(null);
  const cardContent = useRef<HTMLDivElement | null>(null);
  const [heights, setHeights] = useState({ room: 0, pinned: 0, card: 0 });
  useEffect(() => {
    const parts = [scroller.current, pinnedContent.current, cardContent.current];
    const read = () =>
      setHeights((last) => {
        const next = {
          room: Math.max(0, (scroller.current?.clientHeight ?? 0) - HEADER_ROOM),
          pinned: pinnedContent.current?.offsetHeight ?? 0,
          card: cardContent.current?.offsetHeight ?? 0,
        };
        return next.room === last.room && next.pinned === last.pinned && next.card === last.card ? last : next;
      });
    read();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(read);
    for (const part of parts) if (part) observer.observe(part);
    return () => observer.disconnect();
  }, [scroller, pinned, setupCard]);
  // Before the room is measured nothing is capped (a first frame shows the parts whole).
  const shares = heights.room
    ? pinnedLayout(heights.room, pinned ? heights.pinned : undefined, setupCard ? heights.card : undefined)
    : undefined;

  const title = conversationName(conversation, me);
  const other = conversation.kind === "group" ? undefined : conversation.participants.find((p) => p.id !== me);
  const alsoHere = alsoHereNames(props.viewing ?? [], conversation.participants, me, strings.language);
  const history = () => historyEntries(messages, me);
  const style = {
    ...bubbleStyle(colors),
    "--mt-top-room": `${HEADER_ROOM + pinnedHeight}px`,
    "--mt-header-room": `${HEADER_ROOM}px`,
  } as CSSProperties;

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
        <MediaViewerHost
          strings={strings}
          onClosed={() => composer.current?.focus()}
          {...(attachments ? { onSend: (file: File) => composer.current?.addFiles([file]) } : {})}
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
                const row: ShownRow | undefined = item.index > 0 ? shown[item.index - 1]! : undefined;
                return (
                  <div
                    key={item.key}
                    data-key={item.key}
                    ref={measure}
                    className="mt-slot"
                    style={{ transform: `translateY(${item.start}px)` }}
                  >
                    {row?.kind === "extra" ? (
                      row.node
                    ) : row ? (
                      <TranscriptRowView
                        row={row}
                        me={me}
                        strings={strings}
                        now={now}
                        people={people}
                        actions={actions}
                        highlight={highlight}
                      />
                    ) : (
                      <div className="mt-top" style={{ height: HEADER_ROOM + pinnedHeight }} />
                    )}
                  </div>
                );
              })}
            </div>
            {empty && rows.length === 0 && <div className="mt-empty">{empty}</div>}
          </div>
          <TranscriptHeader
            title={title}
            participant={other}
            {...(props.face ? { face: props.face } : {})}
            {...(props.place ? { place: props.place } : {})}
            {...(props.onPlace ? { onPlace: props.onPlace } : {})}
            alsoHere={alsoHere}
            panels={props.panels}
            onPanel={props.onPanel}
            onContact={props.onContact}
            strings={strings}
          />
          {(pinned || setupCard) && (
            <div ref={pinnedBox} className="mt-pinned">
              {pinned && (
                <div className="mt-pinned-section" style={shares ? { maxHeight: shares.pinned } : undefined}>
                  <div ref={pinnedContent}>{pinned}</div>
                </div>
              )}
              {setupCard && (
                <div
                  className="mt-setup-slot"
                  style={{
                    ...(shares ? { maxHeight: shares.card } : {}),
                    ...(pinned && (!shares || shares.pinned > 0) ? { marginTop: PINNED_GAP } : {}),
                  }}
                >
                  <div ref={cardContent} className="mt-setup-card">
                    {setupCard}
                  </div>
                </div>
              )}
            </div>
          )}
          {dropping && <div className="mt-drop-highlight" aria-hidden />}
        </MediaViewerHost>
        <MessageComposer
          ref={composer}
          strings={strings}
          sendEnabled={connection === "online"}
          onSend={props.onSend}
          attachments={
            attachments
              ? {
                  service: attachments,
                  conversation: conversation.id,
                  ...(props.prepareFile ? { prepare: props.prepareFile } : {}),
                }
              : undefined
          }
          history={history}
          dictation={props.dictation}
          toastAvoidance={props.toastAvoidance}
          initialText={props.initialDraft}
          onDraftChange={props.onDraftChange}
          {...(props.attachmentDrafts ? { drafts: props.attachmentDrafts } : {})}
          {...(props.composerPlaceholder ? { placeholder: props.composerPlaceholder } : {})}
          spellChecking={props.spellChecking === true}
          {...(props.quote ? { quote: props.quote } : {})}
          {...(props.onRemoveQuote ? { onRemoveQuote: props.onRemoveQuote } : {})}
          {...(props.chief ? { chief: props.chief } : {})}
          toast={
            props.toast ? (
              <div ref={toastBox} className="mt-toast-room">
                {props.toast}
              </div>
            ) : undefined
          }
          key={`${conversation.id}:${props.composerKey ?? ""}`}
        />
      </section>
    </AttachmentContext.Provider>
  );
}

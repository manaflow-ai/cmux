// The Messages page's detail slot (TopHomePageView's transcript column): the open conversation's
// transcript and composer with its header toggles and link chips, a Chief's first run while its
// chat is empty, New Message in place of the conversation while it shows, and the sheets over the
// page (Requests, Group Info, New Chief, Invite, Team Invite). The conversation's data is the
// Channels store's; the app adds only what it knows (detailHost.ts) and runs the sheets' actions
// (sheets/actions.ts). Nothing here keeps a model of its own beyond the page's view state (nav.ts).
import { hostPrepareFile, type PrepareFile } from "../transcript/prepareAttachment";
import { useEffect, useMemo, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import { Icon } from "../../../agent-session/acpmux/icons/Icon";
import { mergeMessages, parseConversationLink, threadMessages, threadOf } from "../../home-channels/model";
import type { HomeChannelsStore, HomeSnapshot } from "../../home-channels/store";
import type { HomeAttachment, HomeConversation, HomeMessage, HomeParticipant } from "../../home-channels/types";
import { Button } from "../../../ui/Button";
import { createStrings, type Strings } from "../../shared/i18n";
import { pageError, type PageClient } from "../../shared/pageClient";
import { APPROVAL_DECIDE_OP, ApprovalDecisions } from "../cards/approval/approval";
import { FirstRunPanel } from "../cards/firstRun/FirstRunPanel";
import { chiefIntroText, FIRST_RUN_OPS, starterPrompts } from "../cards/firstRun/firstRunModel";
import { HEADER_PANELS, headerPanelItems } from "../cards/header/HeaderPanelBar";
import { useSetupCard } from "../cards/setup/setupHost";
import { FeedNeedsYou, parseNeedsYouRoute } from "../cards/needsYou/FeedNeedsYou";
import { parseChiefFace, parseChiefPlace, type ChiefFace, type ChiefPlace } from "../transcript/ChiefPlace";
import { cardStrings } from "../cards/strings";
import { pageDebug } from "../debugCommands";
import type { MessagesNav, NavState } from "../nav";
import { closeNewMessage } from "../pageCommands";
import { hostActions, type GroupInfoActions } from "../sheets/actions";
import { GroupInfoSheet } from "../sheets/GroupInfoSheet";
import { InviteSheet, TeamInviteSheet } from "../sheets/InviteSheets";
import type { GroupInfo } from "../sheets/model";
import { NewChiefSheet } from "../sheets/NewChiefSheet";
import { NewMessage } from "../sheets/NewMessage";
import { contactLook, existingConversation, type HomeContact } from "../sheets/recipients";
import { RequestsSheet } from "../sheets/RequestsSheet";
import sheetsTable from "../sheets/generated/strings.json";
import { isGone, MessagesDataOps, parseContactsAnswer, parseGroupInfoAnswer, parseRequests } from "../sheets/wire";
import { MessageComposer, type DictationCall, type MessageComposerHandle } from "../transcript/MessageComposer";
import {
  MessagesTranscript,
  type MessagesTranscriptHandle,
  type MessagesTranscriptProps,
} from "../transcript/MessagesTranscript";
import { createTranscriptStrings } from "../transcript/strings";
import type { HeaderPanelItem } from "../transcript/TranscriptHeader";
import type { RowLinks } from "../transcript/TranscriptRows";
import { quotedReply, selectionQuote, type ReplyQuote } from "../transcript/replyQuote";
import { timelineReplyCounts } from "../transcript/rows";
import { threadBranch, threadPath } from "../transcript/threadBranch";
import type { MessagesDetailProps } from "../types";
import { useChiefTurn } from "../transcript/useChiefTurn";
import { ChiefStatusLine, useChiefActivity } from "../transcript/ChiefStatusLine";
import type { TranscriptExtras } from "../transcript/extras";
import { OutgoingTyping } from "../transcript/outgoingTyping";
import { useAgents } from "../cards/pills/useAgents";
import { hostWidgets, WidgetContext } from "../cards/widget/widgetService";
import {
  bubbleHostActions,
  chatAppearance,
  DEFAULT_APPEARANCE,
  DetailOps,
  homeToastAvoidance,
  linkPreviewFetch,
  NO_FIRST_RUN,
  NO_HEADER_PANELS,
  parseAppearance,
  parseFirstRun,
  parseHeaderPanels,
  useBubbleFacts,
  useHostDictation,
  useHostStream,
  type FirstRunFacts,
} from "./detailHost";
import type { ToastAvoidanceReports } from "../../../agent-session/acpmux/toastAvoidance";
import "../sheets/sheets.css";
import "../cards/cards.css";
import "./detail.css";

/** A host that answers nothing (a browser, the gallery): every sheet action reads as refused. */
const NO_HOST: PageClient = {
  call: () => Promise.reject(pageError("cmux.protocol.unknown_op", "no host")),
  subscribe: () => Promise.reject(pageError("cmux.protocol.unknown_op", "no host")),
  handle: () => () => {},
};

interface Contacts {
  contacts: readonly HomeContact[];
  inviteTeam: string | null;
  pendingInvites: readonly string[];
}

const NO_CONTACTS: Contacts = { contacts: [], inviteTeam: null, pendingInvites: [] };

/** The page's detail slot. */
export function MessagesDetail(props: MessagesDetailProps) {
  const { store, snapshot, conversation, me, host, nav, single } = props;
  const view = useSyncExternalStore(nav.subscribe, nav.getSnapshot);
  // The parts' own tables (each keeps the Swift keys it replaces).
  const [words] = useState(() => ({
    transcript: createTranscriptStrings(),
    cards: cardStrings(),
    sheets: createStrings(sheetsTable),
  }));
  const actions = useMemo(() => hostActions(host ?? NO_HOST, words.sheets), [host, words.sheets]);
  const appearance = useHostStream(host, DetailOps.appearance, parseAppearance, DEFAULT_APPEARANCE);
  const panels = useHostStream(host, DetailOps.headerPanels, parseHeaderPanels, NO_HEADER_PANELS);
  const hostFirstRun = useHostStream(host, DetailOps.firstRun, parseFirstRun, NO_FIRST_RUN);
  // DEBUG captures (debugCommands.ts `fixture`): an intro on the shown Chief, New Message's fixture people.
  const debug = useSyncExternalStore(pageDebug.subscribe, pageDebug.getSnapshot);
  const firstRun = useMemo(
    () => (debug.intro ? { ...hostFirstRun, introKind: debug.intro } : hostFirstRun),
    [hostFirstRun, debug.intro],
  );
  const needsYou = useHostStream(host, DetailOps.needsYou, parseNeedsYouRoute, undefined);
  const chiefFace = useHostStream(host, DetailOps.chiefFace, parseChiefFace, undefined);
  const chiefPlace = useHostStream(host, DetailOps.chiefPlace, parseChiefPlace, undefined);
  const dictation = useHostDictation(host);
  // Chat widgets draw from the app's widget host (HomeMessagesWidgets.swift); none: their fallback.
  const widgets = useMemo(() => (host ? hostWidgets(host) : undefined), [host]);
  // Photos and videos go through the app's preparation before they upload (location removed
  // unless Settings > Home keeps it), as the native composer's did. No host (a browser): as they are.
  const prepareFile = useMemo(() => (host ? hostPrepareFile(host) : undefined), [host]);
  // The app's toasts rest above the shown compose bar (the conversation's, a thread's or New
  // Message's); no host (a browser): nothing to tell.
  const toastAvoidance = useMemo(() => (host ? homeToastAvoidance(host) : undefined), [host]);
  const links = useMemo<RowLinks>(
    () => ({
      fetchPreview: linkPreviewFetch(host),
      onOpen: (href) => {
        // A conversation link opens here (the docked Home's list); any other app link or path, and
        // every link on a one-conversation page, is the app's to open.
        if (!single && parseConversationLink(href)) {
          nav.leaveCompose();
          void store.openLink(href);
        } else void host?.call(DetailOps.openLink, { url: href }).catch(() => undefined);
      },
    }),
    [host, nav, store, single],
  );

  // A Chief's permission cards decide through the app, on the person's click only.
  const approvals = useMemo(
    () => (host ? new ApprovalDecisions((params) => host.call<unknown>(APPROVAL_DECIDE_OP, params)) : undefined),
    [host],
  );

  // Message Requests: read at start, when the list changes size and after the sheet closes.
  const readRequests = useRef(() => {});
  readRequests.current = () => {
    if (!host) return;
    void host
      .call<unknown>(MessagesDataOps.requests, {})
      .then(parseRequests, () => [])
      .then((requests) => nav.setRequests(requests));
  };
  const listed = snapshot.conversations.size;
  useEffect(() => readRequests.current(), [host, listed]);
  // While the sheet shows it follows the requests (opening reads them again), as the native
  // presentRequests' refresh and live list; a host without the stream reads them once.
  const requestsShown = view.sheet?.kind === "requests";
  useEffect(() => {
    if (!host || !requestsShown) return;
    let live = true;
    let stop: (() => void) | undefined;
    void host
      .subscribe<unknown>(MessagesDataOps.requestsFollow, (event) => {
        if (live) nav.setRequests(parseRequests(event));
      })
      .then(
        (unsubscribe) => {
          if (live) stop = unsubscribe;
          else unsubscribe();
        },
        () => readRequests.current(),
      );
    return () => {
      live = false;
      stop?.();
    };
  }, [host, nav, requestsShown]);

  // The files the native composer staged go up into their trays once this store can upload
  // (attachmentDrafts.ts `uploadLegacy`, once for the page's life), and every upload after takes
  // the latest store's service (a reconnect's remount replaces the store and its connection).
  const uploads = store.attachments;
  useEffect(() => {
    if (!uploads) return;
    nav.attachments.uploadLegacy(
      (conversation, file, signal, progress) => uploads.upload(conversation, file, progress, signal),
      words.transcript.t("home.composer.attach.failed"),
    );
  }, [uploads, nav, words.transcript]);
  // A send whose files the owner let go of uploads their bytes again (attachmentDrafts.ts `resend`).
  useEffect(() => {
    store.reupload = (conversation, parts, signal) => nav.attachments.resend(conversation, parts, signal);
    return () => {
      store.reupload = undefined;
    };
  }, [store, nav]);

  // The people New Message, Invite and Team Invite offer: read when one of them opens.
  const [contacts, setContacts] = useState<Contacts>(NO_CONTACTS);
  const wantsContacts =
    view.compose !== undefined || view.sheet?.kind === "invite" || view.sheet?.kind === "teamInvite";
  useEffect(() => {
    if (!host || !wantsContacts) return;
    let live = true;
    void host
      .call<unknown>(MessagesDataOps.contacts, {})
      .then(parseContactsAnswer, () => NO_CONTACTS)
      .then((read) => {
        if (live) setContacts(read);
      });
    return () => {
      live = false;
    };
  }, [host, wantsContacts]);

  // Who takes the keyboard: New Message's To: field while it shows, else the conversation's box.
  const transcript = useRef<MessagesTranscriptHandle | null>(null);
  const newMessage = useRef<HTMLDivElement | null>(null);
  const composeBox = useRef<MessageComposerHandle | null>(null);
  const composing = view.compose?.shown === true;
  useEffect(
    () =>
      nav.setFocuser(() => {
        if (composing) {
          const field = newMessage.current?.querySelector<HTMLElement>(".hm-new-message-head input");
          field?.focus();
          return !!field;
        }
        return transcript.current?.focusComposer() ?? false;
      }),
    [nav, composing],
  );
  // What the app hands over (files, a quote) goes to the composer that shows.
  useEffect(
    () => nav.setComposer(() => (composing ? composeBox.current : transcript.current?.composer())),
    [nav, composing],
  );
  // Files dropped on the conversation list go to the shown conversation; New Message takes none.
  useEffect(() => nav.setFileDrop(() => (composing ? undefined : transcript.current?.fileDrop)), [nav, composing]);
  useEffect(() => {
    if (view.focusEpoch > 0) nav.focus();
  }, [nav, view.focusEpoch]);

  /** Opens a conversation a sheet or a send made (once the list has it). */
  const openMade = async (id: string) => {
    if (!snapshot.conversations.has(id)) await store.reloadInbox();
    await store.select(id);
    nav.requestFocus();
  };

  const conversationProps = {
    store,
    snapshot,
    me,
    host,
    nav,
    view,
    words,
    appearance: (shown: HomeConversation) => chatAppearance(appearance, shown),
    spellChecking: appearance.spellChecking,
    panelItems: (shown: HomeConversation) => toolbar(shown, panels, words.cards),
    onPanel: (id: string) => void host?.call(DetailOps.headerPanelToggle, { id }).catch(() => undefined),
    dictation,
    prepareFile,
    links,
    approvals,
    transcript,
    needsYou,
    chiefFace,
    chiefPlace,
    toastAvoidance,
  };

  const rows = useMemo(() => [...snapshot.conversations.values()], [snapshot.conversations]);
  let main: ReactNode = null;
  if (composing && view.compose) {
    main = (
      <div ref={newMessage} className="hm-detail-compose">
        <NewMessage
          strings={words.sheets}
          draft={view.compose.draft}
          onDraft={(draft) => {
            // The typed text follows the message box to the chosen people's conversation, or back.
            nav.composeShows(existingConversation(draft, rows, me?.id) ?? undefined);
            nav.setComposeDraft(draft);
          }}
          contacts={debug.contacts ?? contacts.contacts}
          rows={rows}
          {...(me ? { me: me.id } : {})}
          actions={actions.compose}
          inviteTeam={contacts.inviteTeam}
          look={contactLook}
          onSent={(id, pending) => {
            nav.closeCompose();
            if (pending) store.adoptPending(pending);
            void openMade(id);
          }}
          onEscape={() => {
            // Escape ends only an empty New Message (HomeNewMessageView's isEmpty guard).
            if (nav.composeIsEmpty()) closeNewMessage({ nav, store });
          }}
          onFocusMessage={() => {
            if (!composeBox.current && !transcript.current?.focusComposer()) return;
            composeBox.current?.focus();
          }}
          renderConversation={(id) => (
            <ExistingConversation
              id={id}
              {...conversationProps}
              onSent={() => {
                nav.closeCompose();
                nav.requestFocus();
              }}
            />
          )}
          renderComposer={(send) => (
            <div className="hm-detail-blank">
              <MessageComposer
                ref={composeBox}
                strings={words.transcript}
                sendEnabled={snapshot.connection === "online"}
                onSend={(text) => send(text)}
                spellChecking={appearance.spellChecking}
                initialText={nav.composeText}
                onDraftChange={(text) => {
                  nav.composeText = text;
                }}
                {...(dictation ? { dictation } : {})}
                toastAvoidance={toastAvoidance}
              />
            </div>
          )}
        />
      </div>
    );
  } else if (conversation && me) {
    main = <ConversationView conversation={conversation} {...conversationProps} firstRun={firstRun} />;
  } else if (!snapshot.loading && snapshot.conversations.size === 0 && snapshot.connection === "online") {
    // Nothing to open yet: the first run's rows, without a chat to send a starter to.
    main = (
      <FirstRunPanel
        strings={words.cards}
        face={{ name: words.cards.t("home.firstRun.hero.title") }}
        shortcuts={firstRun.shortcuts}
        {...(firstRun.memoryOffer ? { memoryOffer: firstRun.memoryOffer } : {})}
        {...(firstRun.petShown !== undefined ? { petShown: firstRun.petShown } : {})}
        agents={firstRun.agents}
        {...(firstRun.switchKeys ? { switchKeys: firstRun.switchKeys } : {})}
        {...firstRunHandlers(host)}
        onStarter={() => {}}
      />
    );
  }

  return (
    <WidgetContext.Provider value={widgets}>
      <div className="hm-detail-frame">{main}</div>
      <Sheet
        view={view}
        nav={nav}
        store={store}
        words={words.sheets}
        actions={actions}
        host={host}
        contacts={contacts}
        onDone={(id) => {
          nav.dismiss();
          if (id) void openMade(id);
        }}
        onRequestsDone={(id) => {
          nav.dismiss();
          readRequests.current();
          if (id) void openMade(id);
        }}
      />
    </WidgetContext.Provider>
  );
}

type Words = { transcript: Strings; cards: Strings; sheets: Strings };

interface ConversationViewProps {
  store: HomeChannelsStore;
  snapshot: HomeSnapshot;
  me?: HomeParticipant;
  host: PageClient | null;
  nav: MessagesNav;
  view: NavState;
  words: Words;
  appearance(conversation: HomeConversation): ReturnType<typeof chatAppearance>;
  spellChecking: boolean;
  panelItems(conversation: HomeConversation): HeaderPanelItem[];
  onPanel(id: string): void;
  dictation?: DictationCall;
  prepareFile?: PrepareFile | undefined;
  links: RowLinks;
  approvals: ApprovalDecisions | undefined;
  transcript: React.RefObject<MessagesTranscriptHandle | null>;
  /** The Feed route of the shown Chief chat's pinned Needs you, while it shows. */
  needsYou: string | undefined;
  chiefFace: ChiefFace | undefined;
  chiefPlace: ChiefPlace | undefined;
  toastAvoidance: ToastAvoidanceReports | undefined;
}

/** The open conversation: its transcript and composer, a Chief's first run while it is empty. */
function ConversationView(
  props: ConversationViewProps & {
    conversation: HomeConversation;
    firstRun: FirstRunFacts;
    /** A send went (New Message's existing conversation: the draft ends on it). */
    afterSend?(): void;
  },
) {
  const { store, snapshot, me, host, nav, words, conversation, firstRun } = props;
  // Reply… on a message (the native transcript's tree mode): its thread opens over the
  // conversation at the replied message's branch (the drill path from the root down to it), and a
  // send there answers the branch's message (the root when the path is empty).
  const [replying, setReplying] = useState<{ root: string; path: readonly string[] }>();
  // The bubbles' menus: what the app offers here, and the runs of their rows (both views share them).
  const bubbleHost = useBubbleFacts(host, conversation.id);
  const hostRuns = useMemo(() => bubbleHostActions(host), [host]);
  const menus: BubbleMenuProps = {
    bubbleHost,
    onDelete: (message) => void store.retract(message),
    onRetryReply: (message) => hostRuns.retryReply(message.conversation, message.id),
    onForward: hostRuns.forward,
    onShare: hostRuns.share,
    onFile: hostRuns.file,
  };
  // Reply to Selection's quote: it goes out before the next send's text in the thread it opened.
  const [quote, setQuote] = useState<ReplyQuote>();
  const timelineCounts = useMemo(
    () => timelineReplyCounts(snapshot.messages, snapshot.threadStats),
    [snapshot.messages, snapshot.threadStats],
  );
  const known = (id: string) =>
    snapshot.threadView?.messages.find((message) => message.id === id) ??
    snapshot.messages.find((message) => message.id === id);
  const openBranch = (root: string, path: readonly string[]) => {
    setReplying({ root, path });
    if (snapshot.thread !== root) void store.openThread(root);
  };
  const onReply = (message: HomeMessage) => {
    const root = threadOf(message) ?? message.id;
    const loaded = [...(snapshot.threadView?.messages ?? []), ...snapshot.messages];
    // Another message's Reply… ends a quote taken from a different one (native forgetQuote).
    if (quote && quote.message !== message.id) setQuote(undefined);
    openBranch(root, threadPath(message.id, root, loaded));
  };
  const onReplyToSelection = (message: HomeMessage, taken: ReplyQuote) => {
    onReply(message);
    setQuote(taken);
    nav.requestFocus();
  };
  // The host's Reply to Selection (Cmd-Shift-R, the palette): the page's selection, in one message.
  const replier = useRef<() => boolean>(() => false);
  replier.current = () => {
    const taken = selectionQuote(document);
    const message = taken && known(taken.message);
    if (!taken || !message) return false;
    onReplyToSelection(message, taken);
    return true;
  };
  useEffect(() => nav.setReplier(() => replier.current()), [nav]);
  // The Chief's Stop, Escape, Cmd-., Option-click Stop all agents and Continue (the native compose
  // button, HomeChiefTurnActions): it works while it types or writes its reply here.
  const chiefId = conversation.participants.find((person) => person.id !== me?.id && person.chief)?.id;
  const turn = useChiefTurn(
    host,
    conversation.id,
    conversation.kind === "chief" && !!chiefId,
    !!chiefId && (snapshot.activity.get(conversation.id)?.has(chiefId) ?? false),
    conversation.lastSeq,
    words.transcript,
  );
  // My typing indicator (HomeStore.composing through the host): each edit of the message box, here
  // or in a thread; a send and leaving the conversation end it.
  const typing = useMemo(() => new OutgoingTyping(host, conversation.id), [host, conversation.id]);
  useEffect(() => () => typing.stop(), [typing]);
  // What the Chief works on now, under the newest message while its run streams it (HomeTurnProgress).
  // The row changes only when the line or its run does (the clock ticks inside it).
  const live = useChiefActivity(store.live, store.runs, conversation.id);
  const activity = live?.activity;
  const steps = live?.steps;
  // The Chief's agents: a row of pills under each message that told or heard from them, and the
  // agent pane on the right (HomeNativeTranscriptView+AgentPane). A pill's chat opens right of Home
  // through the host, as its `aN` link does.
  const openOutside = useMemo(
    () =>
      host
        ? (url: string) => {
            void host.call(DetailOps.openLink, { url }).catch(() => undefined);
            return true;
          }
        : undefined,
    [host],
  );
  const isChief = conversation.kind === "chief";
  // Start now on a queued agent's pill or card: the brain starts it past its cap (chief.startAgent);
  // a refusal shows the Chief's words in the turn's toast.
  const { startAgent: startTurnAgent, ...turnProps } = turn;
  const startAgent = isChief ? startTurnAgent : undefined;
  const agents = useAgents(store, snapshot.messages, me?.id, openOutside, words.cards, isChief, startAgent);
  // A Chief's Set Up cmux card while the app shows it (a first run), under Needs you.
  const setupCard = useSetupCard(host, isChief, words.cards);
  const extras = useMemo<TranscriptExtras | undefined>(
    () => {
      const tail =
        activity && steps
          ? [
              {
                key: "chief-status",
                estimate: 24,
                node: <ChiefStatusLine activity={activity} steps={steps} strings={words.transcript} />,
              },
            ]
          : undefined;
      if (!tail && !agents.after.size) return undefined;
      return { ...(tail ? { tail } : {}), ...(agents.after.size ? { after: agents.after } : {}) };
    },
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- the activity's own fields, not its object
    [
      activity?.run,
      activity?.author,
      activity?.activity.line,
      activity?.activity.since,
      steps,
      words.transcript,
      agents.after,
    ],
  );
  if (!me) return null;
  const hostCall = (op: string, params: Record<string, unknown>) => void host?.call(op, params).catch(() => undefined);
  const { look, colors } = props.appearance(conversation);
  const id = conversation.id;
  // A Chief's name opens its settings under the pill (the app's popover); others' open Group Info.
  // The thread's header is the conversation's, so it does the same.
  const onContact = (anchor: { x: number; y: number; width: number; height: number }) =>
    isChief && host
      ? hostCall(DetailOps.chiefSettings, { conversation: id, anchor })
      : nav.present({ kind: "groupInfo", conversation: id });
  // A Chief chat with no message ever shows its first run where the rows will be (the list's own
  // count, so a chat whose page is still loading never flashes it).
  const firstRunShown = conversation.kind === "chief" && conversation.lastSeq === 0 && snapshot.messages.length === 0;
  const chief = conversation.participants.find((person) => person.id !== me.id && person.chief);
  const intro = firstRun.introKind ? chiefIntroText(firstRun.introKind, words.cards) : undefined;
  const root = snapshot.thread;
  if (root) {
    const path = replying?.root === root ? replying.path : [];
    const quoteName =
      quote && conversation.participants.find((person) => person.id === known(quote.message)?.author)?.name;
    // The thread keeps every control of the conversation it opens over (the native composer and
    // header stayed while a thread showed): the Chief's Stop, Escape, Cmd-., Continue and its toast,
    // the header's panel toggles and Group Info, the agents' pills and card, and the status line.
    return (
      <ThreadView
        {...props}
        me={me}
        menus={menus}
        turn={turnProps}
        {...(extras ? { extras } : {})}
        card={agents.card}
        onContact={onContact}
        root={root}
        path={path}
        onPath={(next) => setReplying({ root, path: next })}
        onReply={onReply}
        onReplyToSelection={onReplyToSelection}
        {...(quote ? { quote: { text: quote.text, ...(quoteName ? { name: quoteName } : {}) } } : {})}
        onRemoveQuote={() => setQuote(undefined)}
        typing={typing}
        onSend={async (text, files) => {
          typing.stop();
          const sent = await store.send(quote ? quotedReply(quote.text, text) : text, root, path.at(-1), files);
          if (sent) setQuote(undefined);
          return sent;
        }}
        onClose={() => {
          setReplying(undefined);
          setQuote(undefined);
          void store.openThread(undefined);
        }}
      />
    );
  }
  return (
    <div className="hm-detail-split">
      <MessagesTranscript
        ref={props.transcript}
        strings={words.transcript}
        me={me.id}
        conversation={conversation}
        messages={snapshot.messages}
        pending={snapshot.pending}
        typing={snapshot.typing}
        viewing={snapshot.viewing}
        {...(snapshot.draft ? { draft: snapshot.draft } : {})}
        hasOlder={snapshot.hasOlder}
        loadingOlder={snapshot.loadingOlder}
        connection={snapshot.connection}
        look={look}
        colors={colors}
        panels={props.panelItems(conversation)}
        onPanel={props.onPanel}
        onContact={onContact}
        {...(isChief && props.chiefFace?.conversation === id ? { face: props.chiefFace } : {})}
        {...(isChief && props.chiefPlace?.conversation === id
          ? {
              place: props.chiefPlace,
              onPlace: (anchor: { x: number; y: number; width: number; height: number }) =>
                hostCall(DetailOps.chiefPlaceOpen, { conversation: id, anchor }),
            }
          : {})}
        {...(isChief && props.needsYou && host
          ? { pinned: <FeedNeedsYou key={`${id} ${props.needsYou}`} host={host} route={props.needsYou} /> }
          : {})}
        {...(setupCard ? { setupCard } : {})}
        {...(store.attachments && takesFiles(snapshot, conversation) ? { attachments: store.attachments } : {})}
        {...(props.dictation ? { dictation: props.dictation } : {})}
        toastAvoidance={props.toastAvoidance}
        initialDraft={nav.draft(id)}
        onDraftChange={(text) => {
          nav.keepDraft(id, text);
          typing.changed(text);
        }}
        composerKey={String(nav.draftVersion(id))}
        attachmentDrafts={nav.attachments}
        {...(props.prepareFile ? { prepareFile: props.prepareFile } : {})}
        spellChecking={props.spellChecking}
        onSend={async (text, files) => {
          typing.stop();
          const sent = await store.send(text, undefined, undefined, files);
          if (sent) props.afterSend?.();
          return sent;
        }}
        onLoadOlder={() => void store.loadOlder()}
        onRead={(seq) => store.readThrough(id, seq)}
        onRetry={(key) => store.retry(key)}
        onDiscard={(key) => store.discard(key)}
        canCancelUpload={(key) => store.canCancel(key)}
        onCancelUpload={(key) => store.cancel(key)}
        onReact={(message, partIndex, value, tapback) => void store.react(message, value, { partIndex, tapback })}
        onReply={onReply}
        {...menus}
        onReplyToSelection={onReplyToSelection}
        replyCounts={timelineCounts}
        onOpenReplies={(id) => openBranch(id, [])}
        {...(snapshot.highlight ? { highlight: snapshot.highlight } : {})}
        links={props.links}
        {...(props.approvals ? { approvals: props.approvals } : {})}
        {...(props.approvals ? { approvals: props.approvals } : {})}
        {...turnProps}
        {...(setupCard ? { pinned: setupCard } : {})}
        {...(extras ? { extras } : {})}
        {...(firstRunShown
          ? {
              empty: (
                <IntroMark host={host} conversation={id} kind={firstRun.introKind}>
                  <FirstRunPanel
                    strings={words.cards}
                    face={{ name: chief?.name || words.cards.t("home.firstRun.hero.title") }}
                    {...(intro ? { intro } : {})}
                    starters={starterPrompts(firstRun.starters, words.cards)}
                    shortcuts={firstRun.shortcuts}
                    {...(firstRun.memoryOffer ? { memoryOffer: firstRun.memoryOffer } : {})}
                    {...(firstRun.petShown !== undefined ? { petShown: firstRun.petShown } : {})}
                    agents={firstRun.agents}
                    {...(firstRun.switchKeys ? { switchKeys: firstRun.switchKeys } : {})}
                    {...firstRunHandlers(host)}
                    onStarter={(prompt) => void store.send(prompt)}
                  />
                </IntroMark>
              ),
            }
          : {})}
      />
      {agents.card}
    </div>
  );
}

/** The open thread over its conversation (the native transcript's thread view): the root and every
 * reply loaded so far (the owner's thread pages with the window's newer copies), my sends in it,
 * Back to the conversation, and the message box, whose sends go in the thread. A permalink to a reply
 * opens here too (the store opens its thread and marks it). */
function ThreadView(
  props: ConversationViewProps & {
    conversation: HomeConversation;
    me: HomeParticipant;
    menus: BubbleMenuProps;
    root: string;
    /** The drilled replies below the root (outermost first); empty: the whole thread. */
    path: readonly string[];
    onPath(path: readonly string[]): void;
    onReply(message: HomeMessage): void;
    onReplyToSelection(message: HomeMessage, quote: ReplyQuote): void;
    quote?: { text: string; name?: string };
    onRemoveQuote(): void;
    onSend(text: string, files?: readonly HomeAttachment[]): Promise<boolean>;
    onClose(): void;
    /** The conversation's Chief controls (Stop, Escape, Cmd-., Continue) and their toast. */
    turn: Pick<MessagesTranscriptProps, "chief" | "toast">;
    /** The conversation's added rows (agent pills, the Chief's status line). */
    extras?: TranscriptExtras;
    /** The agent card a pill opened. */
    card?: ReactNode;
    /** My typing indicator: the thread's message box is the conversation's. */
    typing: OutgoingTyping;
    /** The header's name: the conversation's own (a Chief's settings, else Group Info). */
    onContact: NonNullable<MessagesTranscriptProps["onContact"]>;
  },
) {
  const { store, snapshot, words, conversation, root, path } = props;
  const view = snapshot.threadView;
  const messages = useMemo(() => {
    const source = view
      ? mergeMessages(
          view.messages,
          snapshot.messages.filter((message) => !view.hasMore || message.seq <= (view.messages.at(-1)?.seq ?? 0)),
          Number.MAX_SAFE_INTEGER,
        )
      : snapshot.messages;
    const { root: first, replies } = threadMessages(source, root);
    return first ? [first, ...replies] : replies;
  }, [view, snapshot.messages, root]);
  // Tree order, or the drilled branch, with "N Replies" under each reply that has replies.
  const branch = useMemo(() => threadBranch(messages, root, path), [messages, root, path]);
  const names = useMemo(
    () =>
      [root, ...path].map((id) => {
        const author = messages.find((message) => message.id === id)?.author;
        return conversation.participants.find((person) => person.id === author)?.name ?? "";
      }),
    [messages, root, path, conversation.participants],
  );
  const pending = useMemo(
    () => snapshot.pending.filter((entry) => entry.threadRoot === root),
    [snapshot.pending, root],
  );
  // Every reply page loads, one after another (a thread is read whole, as the native view did).
  useEffect(() => {
    if (view?.hasMore && !view.loading) store.loadMoreReplies();
  }, [store, view]);
  const { look, colors } = props.appearance(conversation);
  return (
    <div className="hm-detail-split">
      <MessagesTranscript
        key={`thread:${root}`}
        ref={props.transcript}
        strings={words.transcript}
        me={props.me.id}
        conversation={conversation}
        messages={branch.messages}
        replyCounts={branch.counts}
        threadMode
        onOpenReplies={(id) => props.onPath(threadPath(id, root, messages))}
        onReplyToSelection={props.onReplyToSelection}
        {...(props.quote ? { quote: props.quote } : {})}
        onRemoveQuote={props.onRemoveQuote}
        pending={pending}
        typing={snapshot.typing}
        viewing={snapshot.viewing}
        hasOlder={false}
        loadingOlder={false}
        connection={snapshot.connection}
        look={look}
        colors={colors}
        panels={props.panelItems(conversation)}
        onPanel={props.onPanel}
        onContact={props.onContact}
        {...props.turn}
        {...(props.extras ? { extras: props.extras } : {})}
        pinned={
          <div className="hm-thread-bar">
            {/* Back steps out of a drilled branch one level, then closes the thread (native crumb). */}
            <Button
              variant="ghost"
              size="sm"
              onClick={() => (path.length ? props.onPath(path.slice(0, -1)) : props.onClose())}
            >
              {words.transcript.t("thread.back")}
            </Button>
            {path.length > 0 && (
              <span className="hm-thread-crumbs">
                {names.map((name, level) => (
                  <Button
                    key={level}
                    variant="ghost"
                    size="sm"
                    disabled={level === names.length - 1}
                    onClick={() => props.onPath(path.slice(0, level))}
                  >
                    {name}
                  </Button>
                ))}
              </span>
            )}
          </div>
        }
        {...(store.attachments && takesFiles(snapshot, conversation) ? { attachments: store.attachments } : {})}
        {...(props.dictation ? { dictation: props.dictation } : {})}
        toastAvoidance={props.toastAvoidance}
        {...(props.prepareFile ? { prepareFile: props.prepareFile } : {})}
        spellChecking={props.spellChecking}
        // One message box, as the native one: the conversation's draft and files go on into the thread.
        initialDraft={props.nav.draft(conversation.id)}
        onDraftChange={(text) => {
          props.nav.keepDraft(conversation.id, text);
          props.typing.changed(text);
        }}
        attachmentDrafts={props.nav.attachments}
        composerKey={`thread:${root}:${props.nav.draftVersion(conversation.id)}`}
        composerPlaceholder={words.transcript.t("compose.placeholder.reply")}
        onSend={props.onSend}
        onLoadOlder={() => {}}
        onRetry={(key) => store.retry(key)}
        onDiscard={(key) => store.discard(key)}
        canCancelUpload={(key) => store.canCancel(key)}
        onCancelUpload={(key) => store.cancel(key)}
        onReact={(message, partIndex, value, tapback) => void store.react(message, value, { partIndex, tapback })}
        onReply={props.onReply}
        {...props.menus}
        {...(snapshot.highlight ? { highlight: snapshot.highlight } : {})}
        links={props.links}
        {...(props.approvals ? { approvals: props.approvals } : {})}
      />
      {props.card}
    </div>
  );
}

/** The bubble menu's props both the conversation and its thread pass to their transcript. */
type BubbleMenuProps = Pick<
  MessagesTranscriptProps,
  "bubbleHost" | "onDelete" | "onRetryReply" | "onForward" | "onShare" | "onFile"
>;

/** New Message's people already have this conversation: it shows under the field, and a send there
 * ends the draft on it. */
function ExistingConversation(props: ConversationViewProps & { id: string; onSent(): void }) {
  const { store, snapshot, id } = props;
  useEffect(() => {
    void store.select(id, false);
  }, [store, id]);
  const conversation = snapshot.selected === id ? snapshot.conversations.get(id) : undefined;
  if (!conversation) return null;
  return <ConversationView {...props} conversation={conversation} firstRun={NO_FIRST_RUN} afterSend={props.onSent} />;
}

/** Tells the host once per conversation that its first-open intro showed (it never returns). */
function IntroMark({
  host,
  conversation,
  kind,
  children,
}: {
  host: PageClient | null;
  conversation: string;
  kind: FirstRunFacts["introKind"];
  children: ReactNode;
}) {
  useEffect(() => {
    if (host && kind) void host.call(FIRST_RUN_OPS.markIntroShown, { kind, conversation }).catch(() => undefined);
  }, [host, kind, conversation]);
  return children;
}

function firstRunHandlers(host: PageClient | null) {
  const call = (op: string, params: Record<string, unknown> = {}) => void host?.call(op, params).catch(() => undefined);
  return {
    onAction: (action: string) => call(FIRST_RUN_OPS.action, { action }),
    onAgent: (id: string) => call(FIRST_RUN_OPS.openAgent, { id }),
    onHideSwitchKeys: () => call(FIRST_RUN_OPS.hideSwitchKeys),
    onOpenKeyboardSettings: () => call(FIRST_RUN_OPS.openKeyboardSettings),
  };
}

/** Files go to the conversation when its owner takes them through this host. */
function takesFiles(snapshot: HomeSnapshot, conversation: HomeConversation): boolean {
  const support = snapshot.fileSupport;
  return !!support && (conversation.owner === "cloud" ? support.cloud : support.local);
}

/** The header's top-right toggles: the ones the host lists for this chat, in the panels' order. */
function toolbar(
  conversation: HomeConversation,
  state: ReturnType<typeof parseHeaderPanels>,
  strings: Strings,
): HeaderPanelItem[] {
  const listed = HEADER_PANELS.filter((panel) => state.panels.some((entry) => entry.id === panel.id)).map((panel) => ({
    ...panel,
    isShown: () => true,
  }));
  return headerPanelItems({ isChief: conversation.kind === "chief" }, state.panels, strings, state.enabled, listed).map(
    (item) => ({
      id: item.id,
      icon: <Icon name={item.isOn ? item.onIcon : item.icon} selected={item.isOn} size={16} />,
      label: item.label,
      ...(item.shortcut ? { shortcut: item.shortcut } : {}),
      on: item.isOn,
    }),
  );
}

/** The sheet over the page, with the data it reads from the host. */
function Sheet({
  view,
  nav,
  store,
  words,
  actions,
  host,
  contacts,
  onDone,
  onRequestsDone,
}: {
  view: NavState;
  nav: MessagesNav;
  store: HomeChannelsStore;
  words: Strings;
  actions: ReturnType<typeof hostActions>;
  host: PageClient | null;
  contacts: Contacts;
  onDone(conversation: string | null): void;
  onRequestsDone(conversation: string | null): void;
}) {
  const sheet = view.sheet;
  switch (sheet?.kind) {
    case undefined:
      return null;
    case "requests":
      return (
        <RequestsSheet strings={words} requests={view.requests} actions={actions.requests} onFinish={onRequestsDone} />
      );
    case "groupInfo":
      return sheet.conversation ? (
        <GroupInfo
          key={sheet.conversation}
          conversation={sheet.conversation}
          adding={sheet.adding === true}
          host={host}
          words={words}
          actions={actions.group(sheet.conversation)}
          onClose={() => nav.dismiss()}
          fallback={store.getSnapshot().conversations.get(sheet.conversation)}
        />
      ) : null;
    case "newChief":
      return (
        <NewChiefSheet
          strings={words}
          actions={actions.compose}
          onFinish={onDone}
          {...(sheet.prefill ? { initialName: sheet.prefill } : {})}
        />
      );
    case "invite":
      return (
        <InviteSheet
          strings={words}
          actions={actions.compose}
          pending={contacts.pendingInvites}
          {...(sheet.prefill ? { prefill: sheet.prefill } : {})}
          onFinish={onDone}
        />
      );
    case "teamInvite":
      return (
        <TeamInviteSheet
          strings={words}
          actions={actions.compose}
          team={contacts.inviteTeam ?? ""}
          {...(sheet.prefill ? { prefill: sheet.prefill } : {})}
          requestedByAgent={sheet.requestedByAgent === true}
          onFinish={onDone}
        />
      );
  }
}

/** Group Info: the host's read of the conversation, followed while the sheet shows (members, name
 * and mute as the owner says; TopHomePageView.presentGroupInfo's observation). It closes when the
 * conversation is gone (left, deleted). A host without the stream: read once, then after each
 * change the sheet makes. */
function GroupInfo({
  conversation,
  adding,
  host,
  words,
  actions,
  onClose,
  fallback,
}: {
  conversation: string;
  adding: boolean;
  host: PageClient | null;
  words: Strings;
  actions: GroupInfoActions;
  onClose(): void;
  fallback?: HomeConversation;
}) {
  const [read, setRead] = useState<{ info: GroupInfo; addable: HomeContact[] } | undefined>();
  const live = useRef(true);
  const following = useRef(false);
  const close = useRef(onClose);
  close.current = onClose;
  const load = useRef(() => {});
  load.current = () => {
    if (!host || following.current) return;
    void host
      .call<unknown>(MessagesDataOps.groupInfo, { conversation })
      .then(parseGroupInfoAnswer, () => undefined)
      .then((answer) => {
        if (live.current && answer) setRead(answer);
      });
  };
  useEffect(() => {
    live.current = true;
    let stop: (() => void) | undefined;
    if (host) {
      void host
        .subscribe<unknown>(
          MessagesDataOps.groupFollow,
          (event) => {
            if (!live.current) return;
            if (isGone(event)) return close.current();
            const answer = parseGroupInfoAnswer(event);
            if (answer) setRead(answer);
          },
          { conversation },
        )
        .then(
          (unsubscribe) => {
            if (!live.current) return unsubscribe();
            following.current = true;
            stop = unsubscribe;
          },
          () => load.current(),
        );
    }
    return () => {
      live.current = false;
      stop?.();
    };
  }, [host, conversation]);
  // Without a host (or before its answer) the sheet shows what the list knows.
  const info: GroupInfo | undefined = read?.info ?? (fallback ? infoFromList(fallback) : undefined);
  if (!info) return null;
  const reread =
    <A extends unknown[], R>(run: (...args: A) => Promise<R>) =>
    async (...args: A) => {
      const outcome = await run(...args);
      load.current();
      return outcome;
    };
  const wrapped: GroupInfoActions = {
    ...actions,
    rename: reread(actions.rename),
    add: reread(actions.add),
    remove: reread(actions.remove),
    setMuted: reread(actions.setMuted),
    setChiefReplies: reread(actions.setChiefReplies),
  };
  return (
    <GroupInfoSheet
      strings={words}
      info={info}
      addable={read?.addable ?? []}
      actions={wrapped}
      onClose={onClose}
      initialAdding={adding}
    />
  );
}

/** What the list knows of a conversation, as Group Info shows it before the host's read. */
function infoFromList(conversation: HomeConversation): GroupInfo {
  return {
    conversation: conversation.id,
    isGroup: conversation.kind === "group",
    title: conversation.title,
    displayTitle: conversation.title,
    members: conversation.participants.map((person) => ({
      id: person.id,
      name: person.name,
      isMe: false,
      isAgent: person.kind === "agent",
      isInvited: false,
    })),
    canMute: false,
    muted: conversation.muted,
    canAddPeople: false,
    canRename: false,
  };
}

// The Messages page's detail slot (TopHomePageView's transcript column): the open conversation's
// transcript and composer with its header toggles and link chips, a Chief's first run while its
// chat is empty, New Message in place of the conversation while it shows, and the sheets over the
// page (Requests, Group Info, New Chief, Invite, Team Invite). The conversation's data is the
// Channels store's; the app adds only what it knows (detailHost.ts) and runs the sheets' actions
// (sheets/actions.ts). Nothing here keeps a model of its own beyond the page's view state (nav.ts).
import { useEffect, useMemo, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import { Icon } from "../../../agent-session/acpmux/icons/Icon";
import { parseConversationLink } from "../../home-channels/model";
import type { HomeChannelsStore, HomeSnapshot } from "../../home-channels/store";
import type { HomeConversation, HomeParticipant } from "../../home-channels/types";
import { createStrings, type Strings } from "../../shared/i18n";
import { pageError, type PageClient } from "../../shared/pageClient";
import { FirstRunPanel } from "../cards/firstRun/FirstRunPanel";
import { chiefIntroText, FIRST_RUN_OPS, starterPrompts } from "../cards/firstRun/firstRunModel";
import { HEADER_PANELS, headerPanelItems } from "../cards/header/HeaderPanelBar";
import { cardStrings } from "../cards/strings";
import type { MessagesNav, NavState } from "../nav";
import { hostActions, type GroupInfoActions } from "../sheets/actions";
import { GroupInfoSheet } from "../sheets/GroupInfoSheet";
import { InviteSheet, TeamInviteSheet } from "../sheets/InviteSheets";
import type { GroupInfo } from "../sheets/model";
import { NewChiefSheet } from "../sheets/NewChiefSheet";
import { NewMessage } from "../sheets/NewMessage";
import type { HomeContact } from "../sheets/recipients";
import { RequestsSheet } from "../sheets/RequestsSheet";
import sheetsTable from "../sheets/generated/strings.json";
import { MessagesDataOps, parseContactsAnswer, parseGroupInfoAnswer, parseRequests } from "../sheets/wire";
import { MessageComposer, type DictationCall, type MessageComposerHandle } from "../transcript/MessageComposer";
import { MessagesTranscript, type MessagesTranscriptHandle } from "../transcript/MessagesTranscript";
import { createTranscriptStrings } from "../transcript/strings";
import type { HeaderPanelItem } from "../transcript/TranscriptHeader";
import type { RowLinks } from "../transcript/TranscriptRows";
import type { MessagesDetailProps } from "../types";
import {
  chatAppearance,
  DEFAULT_APPEARANCE,
  DetailOps,
  linkPreviewFetch,
  NO_FIRST_RUN,
  NO_HEADER_PANELS,
  parseAppearance,
  parseFirstRun,
  parseHeaderPanels,
  useHostDictation,
  useHostStream,
  type FirstRunFacts,
} from "./detailHost";
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
  const { store, snapshot, conversation, me, host, nav } = props;
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
  const firstRun = useHostStream(host, DetailOps.firstRun, parseFirstRun, NO_FIRST_RUN);
  const dictation = useHostDictation(host);
  const links = useMemo<RowLinks>(
    () => ({
      fetchPreview: linkPreviewFetch(host),
      onOpen: (href) => {
        // A conversation link opens here; any other app link or path is the app's to open.
        if (parseConversationLink(href)) {
          nav.leaveCompose();
          void store.openLink(href);
        } else void host?.call(DetailOps.openLink, { url: href }).catch(() => undefined);
      },
    }),
    [host, nav, store],
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
    panelItems: (shown: HomeConversation) => toolbar(shown, panels, words.cards),
    onPanel: (id: string) => void host?.call(DetailOps.headerPanelToggle, { id }).catch(() => undefined),
    dictation,
    links,
    transcript,
  };

  let main: ReactNode = null;
  if (composing && view.compose) {
    main = (
      <div ref={newMessage} className="hm-detail-compose">
        <NewMessage
          strings={words.sheets}
          draft={view.compose.draft}
          onDraft={(draft) => nav.setComposeDraft(draft)}
          contacts={contacts.contacts}
          rows={[...snapshot.conversations.values()]}
          {...(me ? { me: me.id } : {})}
          actions={actions.compose}
          inviteTeam={contacts.inviteTeam}
          onSent={(id) => {
            nav.closeCompose();
            void openMade(id);
          }}
          onEscape={() => nav.closeCompose()}
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
                initialText={nav.composeText}
                onDraftChange={(text) => {
                  nav.composeText = text;
                }}
                {...(dictation ? { dictation } : {})}
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
    <>
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
    </>
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
  panelItems(conversation: HomeConversation): HeaderPanelItem[];
  onPanel(id: string): void;
  dictation?: DictationCall;
  links: RowLinks;
  transcript: React.RefObject<MessagesTranscriptHandle | null>;
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
  const { store, snapshot, me, host, nav, view, words, conversation, firstRun } = props;
  if (!me) return null;
  const { look, colors } = props.appearance(conversation);
  const id = conversation.id;
  // A Chief chat with no message ever shows its first run where the rows will be (the list's own
  // count, so a chat whose page is still loading never flashes it).
  const firstRunShown = conversation.kind === "chief" && conversation.lastSeq === 0 && snapshot.messages.length === 0;
  const chief = conversation.participants.find((person) => person.id !== me.id && person.chief);
  const intro = firstRun.introKind ? chiefIntroText(firstRun.introKind, words.cards) : undefined;
  return (
    <>
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
        onContact={() => nav.present({ kind: "groupInfo", conversation: id })}
        {...(store.attachments && takesFiles(snapshot, conversation) ? { attachments: store.attachments } : {})}
        {...(props.dictation ? { dictation: props.dictation } : {})}
        initialDraft={nav.draft(id)}
        onDraftChange={(text) => nav.keepDraft(id, text)}
        composerKey={String(view.draftEpoch)}
        onSend={async (text, files) => {
          const sent = await store.send(text, undefined, undefined, files);
          if (sent) props.afterSend?.();
          return sent;
        }}
        onLoadOlder={() => void store.loadOlder()}
        onRetry={(key) => store.retry(key)}
        onDiscard={(key) => store.discard(key)}
        onReact={(message, _part, value) => void store.react(message, value)}
        {...(snapshot.highlight ? { highlight: snapshot.highlight } : {})}
        links={props.links}
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
    </>
  );
}

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

/** Group Info: the host's read of the conversation, read again after each change it makes. */
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
  const load = useRef(() => {});
  load.current = () => {
    if (!host) return;
    void host
      .call<unknown>(MessagesDataOps.groupInfo, { conversation })
      .then(parseGroupInfoAnswer, () => undefined)
      .then((answer) => {
        if (live.current && answer) setRead(answer);
      });
  };
  useEffect(() => {
    live.current = true;
    load.current();
    return () => {
      live.current = false;
    };
  }, []);
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

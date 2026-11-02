// The guest page (design/chat-multiplayer.md section 3): the join page, the shared chat read only,
// and the ended page. The chat draws with the owner's own transcript (VirtualTranscript) over a
// client fed by the room's socket (AcpmuxDirectClient.fed), with nothing of the pane around it:
// no composer pickers, sessions, inspector or permission buttons. A pending ask shows who it waits on.
import "./guest.css";
import { type FormEvent, useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { VirtualTranscript } from "../acpmux/App";
import { AcpmuxDirectClient } from "../acpmux/direct";
import { GuestActionsBoundary } from "../acpmux/conversation/GuestActionsBoundary";
import { useT } from "../acpmux/i18n";
import type { AcpmuxSnapshot } from "../acpmux/model";
import { PresenceStack } from "../acpmux/multiplayer/Faces";
import { displayName, participant, type Participant } from "../acpmux/multiplayer/participants";
import { GuestComposer, GuestMessages } from "./GuestComposer";
import { GuestPrompts } from "./guestPrompts";
import { GuestSendQueue } from "./guestSendQueue";
import { joinName, type Redeem, type RedeemError } from "./redeem";
import { TypingSignal } from "./typingSignal";
import {
  type GuestChat,
  type GuestConnection,
  type GuestEnd,
  type GuestParticipant,
  ShareSocket,
  type ShareSocketLike,
} from "./shareSocket";

/** What ended the page: the share's end, or a redeem the room refused for good. */
export type GuestEnded = GuestEnd | "used";

/** The fed client's id for the one chat a guest sees; the room never names the owner's session. */
const GUEST_SESSION = "guest-chat";

const ENDED_TEXT = {
  expired: "guest.ended.expired",
  revoked: "guest.ended.revoked",
  closed: "guest.ended.revoked",
  kicked: "guest.ended.kicked",
  used: "guest.ended.used",
} as const;

/** A redeem error that ends the page, else undefined (the guest may try again). */
export function endedBy(error: RedeemError): GuestEnded | undefined {
  if (error === "share.expired") return "expired";
  if (error === "share.revoked") return "revoked";
  if (error === "share.kicked") return "kicked";
  if (error === "share.used" || error === "share.left") return "used";
  return undefined;
}

export function EndedPage({ reason }: { reason: GuestEnded }) {
  const t = useT();
  return (
    <main className="guest-card" data-testid="guest-ended">
      <h1 className="guest-card__title">{t(ENDED_TEXT[reason])}</h1>
    </main>
  );
}

export function JoinPage({
  hasSecret,
  onJoin,
}: {
  /** False when the link lost its secret part: Join is off and the page says so. */
  hasSecret: boolean;
  /** Redeems with the name; resolves to the error to show, or undefined once joined. */
  onJoin: (name: string) => Promise<RedeemError | undefined>;
}) {
  const t = useT();
  const [typed, setTyped] = useState("");
  const [joining, setJoining] = useState(false);
  const [error, setError] = useState<RedeemError>();
  const name = joinName(typed);
  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (!name || joining || !hasSecret) return;
    setJoining(true);
    setError(undefined);
    void onJoin(name).then((failed) => {
      setJoining(false);
      setError(failed);
    });
  };
  const message = !hasSecret
    ? t("guest.join.badLink")
    : error === "share.host_offline"
      ? t("guest.join.hostOffline")
      : error
        ? t("guest.join.failed")
        : undefined;
  return (
    <main className="guest-card">
      <h1 className="guest-card__title">{t("guest.join.title")}</h1>
      <p className="guest-card__detail">{t("guest.join.detail")}</p>
      <form className="guest-join" onSubmit={submit}>
        <input
          className="guest-join__name"
          aria-label={t("guest.join.name")}
          placeholder={t("guest.join.name")}
          value={typed}
          maxLength={64}
          autoComplete="name"
          disabled={!hasSecret}
          onChange={(event) => setTyped(event.target.value)}
        />
        <button className="guest-join__button" type="submit" disabled={!name || joining || !hasSecret}>
          {joining ? t("guest.join.joining") : t("guest.join.button")}
        </button>
      </form>
      {message && (
        <p className="guest-card__error" role="alert">
          {message}
        </p>
      )}
    </main>
  );
}

/** Whether a participant is this guest: its own id, or the author id the daemon stamps (`guest:<share>.<guest>`). */
const isMe = (id: string, guestId: string) => id === guestId || id.endsWith(`.${guestId}`);

/** The chat's owner, as the room's presence names them. */
const ownerOf = (participants: GuestParticipant[]): Participant | undefined => {
  const owner = participants.find((person) => person.kind === "owner");
  return owner && participant(owner.id, owner.name);
};

export function LiveChat({
  guestId,
  name,
  prompts,
  socketUrl,
  openSocket,
  onEnded,
}: {
  /** This guest: never in its own face stack, as the pane leaves the reader out. */
  guestId: string;
  /** The name this guest joined with, for its chip until presence names it. */
  name?: string;
  /** This guest's own messages (guestPrompts.ts). */
  prompts: GuestPrompts;
  socketUrl: string;
  openSocket?: (url: string) => ShareSocketLike;
  onEnded: (reason: GuestEnd) => void;
}) {
  const t = useT();
  const [snapshot, setSnapshot] = useState<AcpmuxSnapshot>();
  const [chat, setChat] = useState<GuestChat>({});
  const [people, setPeople] = useState<GuestParticipant[]>([]);
  const [connection, setConnection] = useState<GuestConnection>("connecting");
  const [hasMore, setHasMore] = useState(false);
  const [expanded, setExpanded] = useState(() => new Set<string>());
  const socket = useRef<ShareSocket | undefined>(undefined);
  const sendQueue = useMemo(
    () => new GuestSendQueue(prompts, (prompt) => socket.current?.send({ t: "prompt", client_id: prompt.clientId, text: prompt.text }) ?? false),
    [prompts],
  );
  const pageArrived = useRef<(() => void) | undefined>(undefined);
  const ended = useRef(onEnded);
  ended.current = onEnded;
  const mine = useSyncExternalStore(prompts.subscribe, prompts.list);
  const typing = useMemo(() => new TypingSignal((on) => socket.current?.send({ t: "typing", on }) ?? false), []);
  useEffect(() => () => typing.dispose(), [typing]);

  useEffect(() => {
    const client = AcpmuxDirectClient.fed(GUEST_SESSION, setSnapshot);
    const room = new ShareSocket(
      { url: socketUrl, unresolved: () => prompts.held(), ...(openSocket ? { open: openSocket } : {}) },
      {
        snapshot: (next) => {
          setChat(next.chat);
          setHasMore(next.hasMore);
          client.feed(next.records, "snapshot");
          sendQueue.snapshot(next.prompts);
          typing.reset();
          // A page asked for on the old connection never comes; the new history is in place.
          pageArrived.current?.();
          pageArrived.current = undefined;
        },
        records: (records) => client.feed(records, "live"),
        page: (records, more) => {
          setHasMore(more);
          client.feed(records, "older");
          pageArrived.current?.();
          pageArrived.current = undefined;
        },
        presence: setPeople,
        promptState: (state) => sendQueue.status(state),
        connection: (state) => { setConnection(state); if (state !== "live") sendQueue.disconnected(); },
        ended: (reason) => {
          sendQueue.stop();
          client.dispose();
          ended.current(reason);
        },
      },
    );
    socket.current = room;
    room.connect();
    return () => {
      sendQueue.disconnected();
      room.stop();
      client.dispose();
      pageArrived.current?.();
    };
  }, [socketUrl, openSocket, prompts, typing, sendQueue]);

  const loadOlder = useCallback(
    () =>
      new Promise<void>((resolve) => {
        const first = snapshot?.historyFrom;
        if (first === undefined || !socket.current?.older(first)) return resolve();
        pageArrived.current = resolve;
      }),
    [snapshot?.historyFrom],
  );
  const toggle = useCallback((id: string) => {
    setExpanded((open) => {
      const next = new Set(open);
      if (!next.delete(id)) next.add(id);
      return next;
    });
  }, []);

  const owner = ownerOf(people);
  const ownerName = owner?.name ?? t("guest.live.owner");
  const me = participant(guestId, people.find((person) => isMe(person.id, guestId))?.name ?? name) ?? {
    id: guestId,
    name: t("guest.you"),
  };
  const send = (text: string) => {
    typing.stop();
    prompts.add(text);
    sendQueue.queued();
  };
  const viewing = people
    .filter((person) => person.viewing !== false && !isMe(person.id, guestId))
    .flatMap((person) => participant(person.id, person.name) ?? []);
  return (
    <GuestActionsBoundary>
      {/* The whole page reports nothing to an owner's context menu (conversation/messageMenu.ts). */}
      <div className="guest-live" data-read-only-transcript="">
        <header className="guest-live__header">
          <div className="guest-live__titles">
            <h1 className="guest-live__title">{displayName(chat.title) ?? t("guest.live.untitled")}</h1>
            {owner && <p className="guest-live__owner">{t("guest.live.sharedBy", { owner: owner.name })}</p>}
          </div>
          <PresenceStack viewing={viewing} />
        </header>
        {connection !== "live" && (
          <output className="guest-live__notice">
            {t(connection === "connecting" ? "guest.live.connecting" : "guest.live.reconnecting")}
          </output>
        )}
        {snapshot && (
          <div className="guest-live__transcript">
            <VirtualTranscript
              rows={snapshot.rows}
              sessionId={GUEST_SESSION}
              expanded={expanded}
              onToggleActivity={toggle}
              working={snapshot.isWorking}
              readOnly
              canLoadOlder={hasMore}
              historyFrom={snapshot.historyFrom}
              onLoadOlder={loadOlder}
            />
          </div>
        )}
        {snapshot?.permission && (
          <output className="guest-live__ask">
            {t("guest.live.waitingAnswer", { owner: ownerName })}
            {snapshot.permission.title && <span className="guest-live__ask-title">{snapshot.permission.title}</span>}
          </output>
        )}
        <div className="guest-live__dock">
          <GuestMessages prompts={mine} me={me} owner={ownerName} />
          <GuestComposer onSend={send} onDraft={(draft) => typing.input(draft)} />
        </div>
      </div>
    </GuestActionsBoundary>
  );
}

export type GuestPageProps = {
  shareId: string;
  /** The link's secret; undefined when the link lost it. */
  secret?: string;
  /** The guest id this tab joined as before (the room's cookie is set): open the chat at once. */
  guestId?: string;
  redeem: Redeem;
  /** This tab's redeem attempt id (redeem.ts attemptId). */
  attempt: () => string;
  /** The name this tab joined with (redeem.ts joinedName). */
  name?: string;
  /** Called once the redeem worked (redeem.ts rememberJoined). */
  onJoined?: (guestId: string, name: string) => void;
  /** Where this tab keeps its own messages (sessionStorage in the page). */
  storage: Storage;
  socketUrl: string;
  openSocket?: (url: string) => ShareSocketLike;
  /** Starts on the ended page (the gallery's ended states). */
  ended?: GuestEnded;
};

export function GuestPage({
  shareId,
  secret,
  guestId: joinedAs,
  name: joinedName,
  storage,
  redeem,
  attempt,
  onJoined,
  socketUrl,
  openSocket,
  ended: endedAtStart,
}: GuestPageProps) {
  const [guestId, setGuestId] = useState(joinedAs);
  const [name, setName] = useState(joinedName);
  const prompts = useMemo(() => new GuestPrompts(shareId, storage), [shareId, storage]);
  const [ended, setEnded] = useState<GuestEnded | undefined>(endedAtStart);
  const join = async (name: string): Promise<RedeemError | undefined> => {
    if (!secret) return "failed";
    const result = await redeem(shareId, { attempt_id: attempt(), secret, name });
    if (result.ok) {
      onJoined?.(result.guestId, name);
      setName(name);
      setGuestId(result.guestId);
      return undefined;
    }
    const final = endedBy(result.error);
    if (final) setEnded(final);
    return result.error;
  };
  if (ended) return <EndedPage reason={ended} />;
  if (!guestId) return <JoinPage hasSecret={!!secret} onJoin={join} />;
  return (
    <LiveChat
      guestId={guestId}
      name={name}
      prompts={prompts}
      socketUrl={socketUrl}
      openSocket={openSocket}
      onEnded={setEnded}
    />
  );
}

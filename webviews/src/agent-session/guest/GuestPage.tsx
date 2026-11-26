// The guest page (design/chat-multiplayer.md section 3): the join page, the shared chat read only,
// and the ended page. The chat draws with the owner's own transcript (VirtualTranscript) over a
// client fed by the room's socket (AcpmuxDirectClient.fed), with nothing of the pane around it:
// no composer pickers, sessions, inspector or permission buttons. A pending ask shows who it waits on.
// The chat's first frame is its final layout: the header, the transcript's area and the composer at
// the bottom draw at once, the socket opens at once, and the transcript's chunk (GuestTranscript.tsx)
// loads beside it and fades in where it stays (Leo, 2026-11-07: "we should be able to expect that it
// goes on the bottom when it loads in the web app").
// An invite (`/i/<id>`, a person invited by account) joins as the signed-in account, with no name
// field; a `view` invitee watches with no composer.
// A link (`/g/<id>`) asks the room who is signed in first (`whoami`): a cmux account joins as itself,
// "Join as <name>" with its picture and an Edit for the name (Leo, 2026-11-07: "they can just use
// their cmux account, and then they wouldn't have to enter their name that way, although they could
// customize their name potentially if they wanted to"); anyone else types a name as before. The
// redeem's `role` decides the composer: `talk` (a signed-in guest on a talk link) may send.
import "./guest.css";
import { type FormEvent, useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { AvatarContext } from "../../pages/home-channels/avatars";
import { useAutoRetry } from "../acpmux/autoRetry";
import { useQuietConnect, useLasting } from "../../ui/lasting";
import { useT } from "../acpmux/i18n";
import type { AcpmuxSnapshot } from "../acpmux/model";
import type { GuestFeed } from "./GuestTranscript";
import { Face, PresenceStack } from "../acpmux/multiplayer/Faces";
import { displayName, participant, type Participant } from "../acpmux/multiplayer/participants";
import { GuestComposer, GuestMessages, GuestQueue, runsAfterTurn } from "./GuestComposer";
import { GuestPrompts } from "./guestPrompts";
import { GuestSendQueue } from "./guestSendQueue";
import {
  type Accept,
  type GuestRole,
  type JoinedVia,
  joinName,
  type Redeem,
  type RedeemError,
  type WhoAmI,
  type WhoAmIFetch,
} from "./redeem";
import { TypingSignal } from "./typingSignal";
import {
  type GuestChat,
  type GuestConnection,
  type GuestEnd,
  type GuestParticipant,
  ShareSocket,
  type ShareSocketLike,
} from "./shareSocket";

/** What ended the page: the share's end, or a redeem the room refused for good (spent, or this guest left). */
export type GuestEnded = GuestEnd | "used" | "left";

export type TranscriptModule = typeof import("./GuestTranscript");
let transcriptChunk: Promise<TranscriptModule> | undefined;
let pageSetup: ((chunk: TranscriptModule) => void) | undefined;
/** The page's transcript stylesheet (main.tsx startGuestPage), loaded with the chunk. */
let pageSheet: (() => Promise<unknown>) | undefined;
/**
 * Loads the transcript's chunk once (a failed load is forgotten, so the next call tries again). The
 * page's own setup (`startGuestPage`) runs on it before any caller sees it.
 */
export function loadGuestTranscript(): Promise<TranscriptModule> {
  // The import is its own step: the bundler wraps `import()` with its preload of the chunk's CSS and
  // shared modules, and a callback chained on the import would sit inside that wrapper, so a failed
  // preload would skip the reset below and keep the rejected promise for good (#38101 F4).
  const fetchChunk = async (): Promise<TranscriptModule> => {
    const [chunk] = await Promise.all([import("./GuestTranscript"), pageSheet?.()]);
    return chunk;
  };
  transcriptChunk ??= fetchChunk().then(
    (chunk) => {
      pageSetup?.(chunk);
      return chunk;
    },
    (error: unknown) => {
      transcriptChunk = undefined;
      throw error;
    },
  );
  return transcriptChunk;
}

/**
 * The page (main.tsx, never the gallery): the chunk's no-owner host is installed as it arrives,
 * before anything from it draws, and its load starts beside the first frame. `loadSheet` loads the
 * transcript's stylesheet (the pane's sheet past the first frame's part); the chunk counts as loaded
 * only once it is in, so no row draws unstyled, and a failed load is tried again with the chunk.
 */
export function startGuestPage(loadSheet?: () => Promise<unknown>): void {
  pageSheet = loadSheet;
  pageSetup = (chunk) => chunk.installGuestPage();
  void loadGuestTranscript().catch(() => undefined);
}

/** Tries to load the transcript's chunk again after a failed load: 1 s, 2 s, 4 s ... up to 30 s apart. */
const CHUNK_RETRY_FIRST_MS = 1_000;
const CHUNK_RETRY_MAX_MS = 30_000;
/// The failed loads after which the page reloads (once): the browser may keep a failed module fetch
/// for the page's life (#38101 F1), so asking the same import again cannot land.
const CHUNK_RELOAD_AFTER = 2;
/// The tab's last reload for a failed chunk; one within `CHUNK_RELOAD_GAP_MS` keeps asking instead,
/// so a chunk that cannot load anywhere never reloads the page in a loop.
const CHUNK_RELOAD_KEY = "cmux.guest.chunkReloadAt";
const CHUNK_RELOAD_GAP_MS = 5 * 60_000;
const reloadWindow = () => window.location.reload();

/// Whether this tab may reload for a failed chunk now, and if so records that it did.
function mayReloadForChunk(): boolean {
  try {
    const last = Number(window.sessionStorage.getItem(CHUNK_RELOAD_KEY) ?? 0);
    if (Date.now() - last < CHUNK_RELOAD_GAP_MS) return false;
    window.sessionStorage.setItem(CHUNK_RELOAD_KEY, String(Date.now()));
    return true;
  } catch {
    return false;
  }
}

/** The fed client's id for the one chat a guest sees; the room never names the owner's session. */
const GUEST_SESSION = "guest-chat";

const ENDED_TEXT = {
  expired: "guest.ended.expired",
  revoked: "guest.ended.revoked",
  closed: "guest.ended.revoked",
  kicked: "guest.ended.kicked",
  used: "guest.ended.used",
  left: "guest.ended.left",
} as const;

/** The muted next step under an ended page's title: a spent or expired link takes a new one. */
const ENDED_NEXT: Partial<Record<GuestEnded, "guest.ended.askNewLink">> = {
  expired: "guest.ended.askNewLink",
  used: "guest.ended.askNewLink",
};

/** A redeem error that ends the page, else undefined (the guest may try again). */
export function endedBy(error: RedeemError): GuestEnded | undefined {
  if (error === "share.expired") return "expired";
  if (error === "share.revoked") return "revoked";
  if (error === "share.closed") return "closed";
  if (error === "share.kicked") return "kicked";
  if (error === "share.used") return "used";
  if (error === "share.left") return "left";
  return undefined;
}

export function EndedPage({ reason, invite = false }: { reason: GuestEnded; invite?: boolean }) {
  const t = useT();
  // An account invite (`/i/<id>`) expires as an invite, and a new one comes from the owner too.
  const title = invite && reason === "expired" ? "guest.ended.inviteExpired" : ENDED_TEXT[reason];
  const next = invite && reason === "expired" ? "guest.ended.askNewInvite" : ENDED_NEXT[reason];
  return (
    <main className="guest-card" data-testid="guest-ended">
      <h1 className="guest-card__title">{t(title)}</h1>
      {next && <p className="guest-card__detail">{t(next)}</p>}
    </main>
  );
}

/**
 * A join that failed only because the owner's computer or the network was away (`share.host_offline`,
 * `failed`): Join's click is asked again on the shared backoff (autoRetry.ts; the redeem's attempt id
 * makes a repeat the same attempt, redeem.ts), with no "try again" (Leo, 2026-11-22: "vacuous decisions
 * like that should be just done").
 */
function joinsAgain(error: RedeemError | undefined): boolean {
  return error === "share.host_offline" || error === "failed";
}

/**
 * A join card's state: `join` runs the person's Join; a failure `joinsAgain` covers runs it again by
 * itself, the button reading Joining… meanwhile, and says nothing until it has lasted (`stillTrying`,
 * one quiet line). Any other failure is `error`, said at once.
 */
function useJoin<Args extends unknown[]>(onJoin: (...args: Args) => Promise<RedeemError | undefined>) {
  const [joining, setJoining] = useState(false);
  const [failed, setFailed] = useState<RedeemError>();
  const asked = useRef<Args | undefined>(undefined);
  const join = (...args: Args) => {
    asked.current = args;
    setJoining(true);
    setFailed(undefined);
    void onJoin(...args).then((error) => {
      setJoining(false);
      setFailed(error);
    });
  };
  const again = joinsAgain(failed) ? failed : undefined;
  const { stillTrying } = useAutoRetry(
    again,
    () => {
      if (asked.current) join(...asked.current);
    },
    { busy: joining },
  );
  return { joining: joining || again !== undefined, error: again ? undefined : failed, stillTrying, join };
}

/**
 * What a failed join says: invites name the account's problem; else the link's (an away host or a
 * dropped connection never reaches here: `useJoin` joins again by itself). `signIn`
 * is where to sign in (an invite's own address); a link's join signs in at its own page.
 */
function JoinError({ error, signIn }: { error: RedeemError; signIn?: string }) {
  const t = useT();
  if (error === "share.unauthorized" && signIn)
    return (
      <>
        {t("guest.invite.signIn")}{" "}
        <a className="guest-card__link" href={signIn}>
          {t("guest.invite.signInButton")}
        </a>
      </>
    );
  // A link's signed-in join whose sign-in lapsed: not a connection problem; sign in on this page.
  if (error === "share.unauthorized")
    return (
      <>
        {t("guest.join.signInExpired")}{" "}
        <a className="guest-card__link" href={signInHere()}>
          {t("guest.join.signInAgain")}
        </a>
      </>
    );
  if (error === "share.not_invited")
    return (
      <>
        {t("guest.invite.notInvited")}
        {signIn && (
          <>
            {" "}
            <a className="guest-card__link" href={signIn}>
              {t("guest.invite.otherAccount")}
            </a>
          </>
        )}
      </>
    );
  if (error === "share.unverified") return <>{t("guest.invite.unverified")}</>;
  return <>{t("guest.join.failed")}</>;
}

/** This page's own address: signing in again comes back to the same link (secret fragment kept). */
const signInHere = () => (typeof window === "undefined" ? "" : window.location.pathname + window.location.search);

/** An invite's join: the room already signed this visitor in, so no name field, only Join. */
export function InviteJoinPage({
  signIn,
  onJoin,
}: {
  /** Where to sign in again when the sign-in lapsed (the invite's own address). */
  signIn: string;
  /** Accepts as the signed-in account; resolves to the error to show, or undefined once joined. */
  onJoin: () => Promise<RedeemError | undefined>;
}) {
  const t = useT();
  const { joining, error, stillTrying, join } = useJoin(onJoin);
  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (joining) return;
    join();
  };
  return (
    <main className="guest-card" data-testid="guest-invite">
      <h1 className="guest-card__title">{t("guest.join.title")}</h1>
      <p className="guest-card__detail">{t("guest.invite.detail")}</p>
      <form className="guest-join" onSubmit={submit}>
        <button className="guest-join__button" type="submit" disabled={joining}>
          {joining ? t("guest.join.joining") : t("guest.join.button")}
        </button>
      </form>
      {error ? (
        <p className="guest-card__error" role="alert">
          <JoinError error={error} signIn={signIn} />
        </p>
      ) : (
        stillTrying && <output className="guest-card__detail">{t("guest.join.stillTrying")}</output>
      )}
    </main>
  );
}

export function JoinPage({
  hasSecret,
  signIn,
  onJoin,
}: {
  /** False when the link lost its secret part: Join is off and the page says so. */
  hasSecret: boolean;
  /**
   * Where a visitor with a cmux account signs in and comes back to this same link (the room's
   * hosted sign-in, as an invite's); none on a link that lost its secret, where it could not help.
   */
  signIn?: string;
  /** Redeems with the name; resolves to the error to show, or undefined once joined. */
  onJoin: (name: string) => Promise<RedeemError | undefined>;
}) {
  const t = useT();
  const [typed, setTyped] = useState("");
  const { joining, error, stillTrying, join } = useJoin(onJoin);
  const name = joinName(typed);
  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (!name || joining || !hasSecret) return;
    join(name);
  };
  const message = !hasSecret ? t("guest.join.badLink") : error ? <JoinError error={error} /> : undefined;
  const quiet = !message && stillTrying;
  return (
    <main className="guest-card">
      <h1 className="guest-card__title">{t("guest.join.title")}</h1>
      {/* A guest who joins by the link alone watches only; sending takes an invited account. */}
      <p className="guest-card__detail">{t("guest.live.viewOnly")}</p>
      <form className="guest-join" onSubmit={submit}>
        <input
          className="guest-join__name"
          aria-label={t("guest.join.name")}
          placeholder={t("guest.join.name")}
          value={typed}
          maxLength={64}
          autoComplete="name"
          disabled={!hasSecret || joining}
          onChange={(event) => setTyped(event.target.value)}
        />
        <button className="guest-join__button" type="submit" disabled={!name || joining || !hasSecret}>
          {joining ? t("guest.join.joining") : t("guest.join.button")}
        </button>
      </form>
      {message ? (
        <p className="guest-card__error" role="alert">
          {message}
        </p>
      ) : (
        quiet && <output className="guest-card__detail">{t("guest.join.stillTrying")}</output>
      )}
      {signIn && hasSecret && (
        <p className="guest-card__detail" data-testid="guest-join-sign-in">
          {t("guest.join.signInOffer")}{" "}
          <a className="guest-card__link" href={signIn}>
            {t("guest.invite.signInButton")}
          </a>
        </p>
      )}
    </main>
  );
}

/**
 * A link's sign-in: the room's hosted sign-in (the one an invite's `/i/<id>` uses), back to this
 * `/g/<id>` with no query. The secret is not in it: the page kept it in this tab's sessionStorage
 * (redeem.ts takeGuestLink), which the same tab finds again on its return.
 */
export const linkSignIn = (shareId: string) => `/g/${encodeURIComponent(shareId)}?sign_in=1`;

/**
 * The signed-in account a link guest joins as: its name and picture from the room's `whoami`, and
 * the link's role when the room names it (`talk` may send, `view` watches).
 */
export type SignedIn = { name: string; avatarUrl?: string; linkRole?: GuestRole };

/** The signed-in join's line, by the link's role; a room that names none keeps the hedged line. */
const JOIN_AS_DETAIL = {
  talk: "guest.join.asDetailTalk",
  view: "guest.join.asDetailView",
  unknown: "guest.invite.detail",
} as const;

/**
 * A link's join for a visitor signed in to cmux: "Join as <name>" with their picture, and a quiet
 * Edit name that opens the name field, filled with the account's name. Join redeems the link with
 * the shown (maybe edited) name; the room adds the account from its own sign-in.
 */
export function JoinAsPage({
  account,
  editing: editingAtStart = false,
  onJoin,
}: {
  account: SignedIn;
  /** Starts with the name field open (the gallery's edit state). */
  editing?: boolean;
  /** Redeems with the name; resolves to the error to show, or undefined once joined. */
  onJoin: (name: string) => Promise<RedeemError | undefined>;
}) {
  const t = useT();
  const [editing, setEditing] = useState(editingAtStart);
  const [typed, setTyped] = useState(account.name);
  const field = useRef<HTMLInputElement>(null);
  // Edit name asked for the field: the caret goes there (a field open from the start takes none).
  useEffect(() => {
    if (editing && !editingAtStart) field.current?.focus();
  }, [editing, editingAtStart]);
  const edit = () => setEditing(true);
  const { joining, error, stillTrying, join } = useJoin(onJoin);
  const name = editing ? joinName(typed) : account.name;
  const face: Participant = {
    id: "guest-join-as",
    name: name ?? account.name,
    ...(account.avatarUrl ? { avatar: account.avatarUrl } : {}),
  };
  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (!name || joining) return;
    join(name);
  };
  return (
    <main className="guest-card" data-testid="guest-join-as">
      <h1 className="guest-card__title">{t("guest.join.title")}</h1>
      <p className="guest-card__detail">{t(JOIN_AS_DETAIL[account.linkRole ?? "unknown"])}</p>
      <form className="guest-join" onSubmit={submit}>
        {editing ? (
          <>
            <span className="guest-join__face">
              <Face person={face} size={24} />
            </span>
            <input
              className="guest-join__name"
              aria-label={t("guest.join.name")}
              placeholder={t("guest.join.name")}
              value={typed}
              maxLength={64}
              autoComplete="name"
              disabled={joining}
              ref={field}
              onChange={(event) => setTyped(event.target.value)}
            />
            <button className="guest-join__button" type="submit" disabled={!name || joining}>
              {joining ? t("guest.join.joining") : t("guest.join.button")}
            </button>
          </>
        ) : (
          <button className="guest-join__button guest-join__as" type="submit" disabled={joining}>
            <Face person={face} size={20} />
            <span className="guest-join__as-label">
              {joining ? t("guest.join.joining") : t("guest.join.as", { name: account.name })}
            </span>
          </button>
        )}
      </form>
      {!editing && (
        <button className="guest-join__edit" type="button" disabled={joining} onClick={edit}>
          {t("guest.join.editName")}
        </button>
      )}
      {error ? (
        <p className="guest-card__error" role="alert">
          <JoinError error={error} />
        </p>
      ) : (
        stillTrying && <output className="guest-card__detail">{t("guest.join.stillTrying")}</output>
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
  avatar,
  role,
  prompts,
  socketUrl,
  openSocket,
  loadTranscript = loadGuestTranscript,
  reloadPage = reloadWindow,
  onEnded,
}: {
  /** This guest: never in its own face stack, as the pane leaves the reader out. */
  guestId: string;
  /** The name this guest joined with, for its chip until presence names it. */
  name?: string;
  /** The signed-in account's picture this guest joined with, for its own chip. */
  avatar?: string;
  /** This guest's role: only `talk` sends (a composer); `view` or none watches. */
  role?: GuestRole;
  /** This guest's own messages (guestPrompts.ts). */
  prompts: GuestPrompts;
  socketUrl: string;
  openSocket?: (url: string) => ShareSocketLike;
  /** Loads the transcript's chunk (loadGuestTranscript; tests and the gallery hand in a failing one). */
  loadTranscript?: () => Promise<TranscriptModule>;
  /** Reloads the page once a chunk load failed twice (tests hand in a spy). */
  reloadPage?: () => void;
  onEnded: (reason: GuestEnd) => void;
}) {
  const t = useT();
  const [snapshot, setSnapshot] = useState<AcpmuxSnapshot>();
  const [chat, setChat] = useState<GuestChat>({});
  const [people, setPeople] = useState<GuestParticipant[]>([]);
  const [connection, setConnection] = useState<GuestConnection>("connecting");
  // Connecting and reconnecting heal on their own and offer nothing to do: the line waits out the
  // shared bound (ui/lasting.ts `CONNECTION_QUIET_MS`, with Quiet Connections on), so a join or a blip that lands under it
  // says nothing (Leo, 2026-11-14: "i also want all our connectivity stuff to shut up").
  const linkDownLasting = useQuietConnect(connection !== "live");
  const [hasMore, setHasMore] = useState(false);
  const [expanded, setExpanded] = useState(() => new Set<string>());
  const socket = useRef<ShareSocket | undefined>(undefined);
  const sendQueue = useMemo(
    () =>
      new GuestSendQueue(
        prompts,
        (prompt) => socket.current?.send({ t: "prompt", client_id: prompt.clientId, text: prompt.text }) ?? false,
      ),
    [prompts],
  );
  const pageArrived = useRef<(() => void) | undefined>(undefined);
  const ended = useRef(onEnded);
  ended.current = onEnded;
  const mine = useSyncExternalStore(prompts.subscribe, prompts.list);
  const typing = useMemo(() => new TypingSignal((on) => socket.current?.send({ t: "typing", on }) ?? false), []);
  useEffect(() => () => typing.dispose(), [typing]);

  // The socket opens on the first commit; the records it brings wait for the transcript's chunk,
  // in arrival order, if they come first.
  const [transcript, setTranscript] = useState<TranscriptModule>();
  // The chunk failed to load: the page keeps trying on its own and says nothing until the failure
  // has lasted (then one quiet line, no Retry: Leo, 2026-11-22, "vacuous decisions like that should
  // be just done").
  const [loadFailed, setLoadFailed] = useState(false);
  const stillLoading = useLasting(loadFailed);
  useEffect(() => {
    let stopped = false;
    let client: GuestFeed | undefined;
    const waiting: ((client: GuestFeed) => void)[] = [];
    const withClient = (run: (client: GuestFeed) => void) => (client ? run(client) : waiting.push(run));
    // A failed chunk load (a dropped connection) tries again until it lands or the chat goes away.
    // The browser may keep a failed module fetch for the page's life, so a load that failed
    // `CHUNK_RELOAD_AFTER` times reloads the page once (this tab's join is in sessionStorage, so it
    // opens the chat again).
    let retry: ReturnType<typeof setTimeout> | undefined;
    let attempt = 0;
    let failures = 0;
    const load = (delay: number) => {
      clearTimeout(retry);
      retry = undefined;
      const mine = ++attempt;
      void loadTranscript().then(
        (module) => {
          if (stopped || client) return;
          client = module.feedClient(GUEST_SESSION, setSnapshot);
          setLoadFailed(false);
          setTranscript(module);
          for (const run of waiting.splice(0)) run(client);
        },
        () => {
          // Only the newest attempt schedules the next one.
          if (stopped || client || mine !== attempt) return;
          failures += 1;
          if (failures === CHUNK_RELOAD_AFTER && mayReloadForChunk()) return reloadPage();
          setLoadFailed(true);
          retry = setTimeout(() => load(Math.min(delay * 2, CHUNK_RETRY_MAX_MS)), delay);
        },
      );
    };
    load(CHUNK_RETRY_FIRST_MS);
    const stop = () => {
      stopped = true;
      clearTimeout(retry);
      waiting.length = 0;
      client?.dispose();
    };
    const room = new ShareSocket(
      {
        url: socketUrl,
        unresolved: () => prompts.held(),
        ...(openSocket ? { open: openSocket } : {}),
      },
      {
        snapshot: (next) => {
          setChat(next.chat);
          setHasMore(next.hasMore);
          withClient((fed) => fed.feed(next.records, "snapshot"));
          sendQueue.snapshot(next.prompts);
          typing.reset();
          // A page asked for on the old connection never comes; the new history is in place.
          pageArrived.current?.();
          pageArrived.current = undefined;
        },
        records: (records) => withClient((fed) => fed.feed(records, "live")),
        page: (records, more) => {
          setHasMore(more);
          withClient((fed) => fed.feed(records, "older"));
          pageArrived.current?.();
          pageArrived.current = undefined;
        },
        presence: setPeople,
        promptState: (state) => sendQueue.status(state),
        connection: (state) => {
          setConnection(state);
          if (state !== "live") sendQueue.disconnected();
        },
        ended: (reason) => {
          sendQueue.stop();
          stop();
          ended.current(reason);
        },
      },
    );
    socket.current = room;
    room.connect();
    return () => {
      sendQueue.disconnected();
      room.stop();
      stop();
      pageArrived.current?.();
    };
  }, [socketUrl, openSocket, prompts, typing, sendQueue, loadTranscript, reloadPage]);

  const loadOlder = useCallback(
    () =>
      new Promise<void>((resolve) => {
        const first = snapshot?.historyFrom;
        if (first === undefined || !socket.current?.older(first)) return resolve();
        pageArrived.current = resolve;
      }),
    [snapshot?.historyFrom],
  );
  // A joined run's line is open under any of its keys (turns.ts `foldCovers`): closing it clears them
  // all, as turns.ts `toggleTurnFold` does. Inline, so this first chunk does not load the transcript's.
  const toggle = useCallback((id: string, covers: readonly string[] = []) => {
    setExpanded((open) => {
      const next = new Set(open);
      const keys = [id, ...covers];
      const wasOpen = keys.some((key) => open.has(key));
      for (const key of keys) next.delete(key);
      if (!wasOpen) next.add(id);
      return next;
    });
  }, []);

  const owner = ownerOf(people);
  const ownerName = owner?.name ?? t("guest.live.owner");
  const named = participant(guestId, people.find((person) => isMe(person.id, guestId))?.name ?? name);
  const me: Participant = named
    ? { ...named, ...(avatar && !named.avatar ? { avatar } : {}) }
    : { id: guestId, name: t("guest.you") };
  const send = (text: string) => {
    typing.stop();
    prompts.keepDraft("");
    prompts.add(text);
    sendQueue.queued();
  };
  // Try again on a refused message: back to sending with its own id, through the paced outbox.
  const retry = (clientId: string) => {
    prompts.retry(clientId);
    sendQueue.queued();
  };
  const viewing = people
    .filter((person) => person.viewing !== false && !isMe(person.id, guestId))
    .flatMap((person) => participant(person.id, person.name) ?? []);
  // This guest's own approved message is the "Sent" line below already.
  const waiting = (snapshot?.queue ?? []).filter(
    (entry) => runsAfterTurn(entry) && !(entry.author && isMe(entry.author.id, guestId)),
  );
  return (
    // Faces and chips ask no owner's avatar service (GuestTranscript's boundary does the same).
    <AvatarContext.Provider value={undefined}>
      {/* The whole page reports nothing to an owner's context menu (conversation/messageMenu.ts). */}
      <div className="guest-live" data-read-only-transcript="">
        {/* One height from the first frame: the title and the owner's line hold their lines while
            the room has not named them yet, so nothing below moves when they arrive. */}
        <header className="guest-live__header">
          <div className="guest-live__titles">
            <h1 className="guest-live__title">
              {snapshot || chat.title ? (displayName(chat.title) ?? t("guest.live.untitled")) : ""}
            </h1>
            <p className="guest-live__owner">{owner ? t("guest.live.sharedBy", { owner: owner.name }) : ""}</p>
          </div>
          <PresenceStack viewing={viewing} />
        </header>
        {/* The transcript's area fills the page from the first frame, so the composer sits at the
            bottom before the room's snapshot; the notice floats in it and moves nothing. */}
        <div className="guest-live__transcript" aria-busy={!snapshot}>
          {snapshot && transcript && (
            <transcript.GuestTranscript
              snapshot={snapshot}
              sessionId={GUEST_SESSION}
              expanded={expanded}
              onToggle={toggle}
              hasMore={hasMore}
              onLoadOlder={loadOlder}
            />
          )}
          {loadFailed
            ? stillLoading && <output className="guest-live__notice">{t("guest.live.stillLoading")}</output>
            : linkDownLasting && (
                <output className="guest-live__notice">
                  {t(connection === "connecting" ? "guest.live.connecting" : "guest.live.reconnecting")}
                </output>
              )}
        </div>
        {snapshot?.permission && (
          <output className="guest-live__ask">
            {t("guest.live.waitingAnswer", { owner: ownerName })}
            {snapshot.permission.title && <span className="guest-live__ask-title">{snapshot.permission.title}</span>}
          </output>
        )}
        <div className="guest-live__dock">
          <GuestQueue queue={waiting} owner={owner} />
          <GuestMessages prompts={mine} me={me} owner={ownerName} onRetry={role === "talk" ? retry : undefined} />
          {/* Only a `talk` guest sends; no role (an answer that named none) or `view` watches. */}
          {role === "talk" ? (
            <GuestComposer
              initialText={prompts.draft()}
              onSend={send}
              onDraft={(draft) => {
                prompts.keepDraft(draft);
                typing.input(draft);
              }}
            />
          ) : (
            <p className="guest-live__view-only">{t("guest.live.viewOnly")}</p>
          )}
        </div>
      </div>
    </AvatarContext.Provider>
  );
}

export type GuestPageProps = {
  shareId: string;
  /** The link's secret; undefined when the link lost it. */
  secret?: string;
  /** The guest id this tab joined as before (the room's cookie is set): open the chat at once. */
  guestId?: string;
  redeem: Redeem;
  /** An account invite (`/i/<id>`): Join accepts as the signed-in account, with no name or secret. */
  invite?: boolean;
  /** The room's accept, for an invite. */
  accept?: Accept;
  /** This tab's redeem attempt id (redeem.ts attemptId). */
  attempt: () => string;
  /** The name this tab joined with (redeem.ts joinedName). */
  name?: string;
  /** The role this tab's invitee joined with (redeem.ts joinedRole). */
  role?: GuestRole;
  /** Called once the redeem or accept worked (redeem.ts rememberJoined); an invite has no typed name. */
  onJoined?: (guestId: string, name: string | undefined, role: GuestRole | undefined, via: JoinedVia) => void;
  /** Where this tab keeps its own messages (sessionStorage in the page). */
  storage: Storage;
  socketUrl: string;
  openSocket?: (url: string) => ShareSocketLike;
  /** Loads the transcript's chunk (default loadGuestTranscript). */
  loadTranscript?: () => Promise<TranscriptModule>;
  /** Reloads the page once a chunk load failed twice (default window.location.reload). */
  reloadPage?: () => void;
  /** Starts on the ended page (the gallery's ended states). */
  ended?: GuestEnded;
  /** The room's `whoami` for a link (redeem.ts whoamiOverFetch); none, or an invite, asks nobody. */
  whoami?: WhoAmIFetch;
  /** Starts the signed-in join with the name field open (the gallery's edit state). */
  editName?: boolean;
};

/** How long a link's join waits for `whoami` before it shows the name prompt. */
const WHOAMI_WAIT_MS = 3000;
const ANONYMOUS: WhoAmI = { signedIn: false };

export function GuestPage({
  shareId,
  secret,
  guestId: joinedAs,
  name: joinedName,
  role: joinedRole,
  storage,
  redeem,
  invite = false,
  accept,
  attempt,
  onJoined,
  socketUrl,
  openSocket,
  loadTranscript,
  reloadPage,
  ended: endedAtStart,
  whoami,
  editName = false,
}: GuestPageProps) {
  const [guestId, setGuestId] = useState(joinedAs);
  // Asked only on a link's join (a secret, no invite, not joined yet); anything else is anonymous.
  const asks = !!whoami && !invite && !!secret && !joinedAs;
  const [who, setWho] = useState<WhoAmI | undefined>(asks ? undefined : ANONYMOUS);
  useEffect(() => {
    if (!asks || !whoami) return;
    let live = true;
    const settle = (answer: WhoAmI) => live && setWho((known) => known ?? answer);
    // timeout: a room that never answers whoami would hold the join page blank; past the wait it is
    // the name prompt, and a late answer changes nothing (the page never swaps under the person).
    const timer = setTimeout(() => settle(ANONYMOUS), WHOAMI_WAIT_MS);
    void whoami(shareId).then(
      (answer) => {
        clearTimeout(timer);
        settle(answer);
      },
      () => settle(ANONYMOUS),
    );
    return () => {
      live = false;
      clearTimeout(timer);
    };
  }, [asks, whoami, shareId]);
  const [name, setName] = useState(joinedName);
  const [role, setRole] = useState(joinedRole);
  const prompts = useMemo(() => new GuestPrompts(shareId, storage), [shareId, storage]);
  const [ended, setEnded] = useState<GuestEnded | undefined>(endedAtStart);
  const join = async (name: string): Promise<RedeemError | undefined> => {
    if (!secret) return "failed";
    const result = await redeem(shareId, { attempt_id: attempt(), secret, name });
    if (result.ok) {
      // The redeem names the role: `talk` for a signed-in account on a talk link; an anonymous
      // guest watches (the daemon refuses its messages whatever the room says).
      const joinedAs = result.role ?? "view";
      onJoined?.(result.guestId, name, joinedAs, "link");
      setRole(joinedAs);
      setName(name);
      setGuestId(result.guestId);
      return undefined;
    }
    const final = endedBy(result.error);
    if (final) setEnded(final);
    return result.error;
  };
  const acceptInvite = async (): Promise<RedeemError | undefined> => {
    if (!accept) return "failed";
    const result = await accept(shareId, { attempt_id: attempt() });
    if (result.ok) {
      onJoined?.(result.guestId, undefined, result.role, "invite");
      setRole(result.role);
      setGuestId(result.guestId);
      return undefined;
    }
    const final = endedBy(result.error);
    if (final) setEnded(final);
    return result.error;
  };
  if (ended) return <EndedPage reason={ended} invite={invite} />;
  if (!guestId && invite) return <InviteJoinPage signIn={`/i/${encodeURIComponent(shareId)}`} onJoin={acceptInvite} />;
  // Nothing until the room says who this is (at most WHOAMI_WAIT_MS), so the join never swaps.
  if (!guestId && !who) return <main className="guest-card" aria-busy="true" />;
  if (!guestId && who?.signedIn) return <JoinAsPage account={who} editing={editName} onJoin={join} />;
  if (!guestId)
    return <JoinPage hasSecret={!!secret} signIn={whoami ? linkSignIn(shareId) : undefined} onJoin={join} />;
  return (
    <LiveChat
      guestId={guestId}
      name={name}
      avatar={who?.signedIn ? who.avatarUrl : undefined}
      role={role}
      prompts={prompts}
      socketUrl={socketUrl}
      openSocket={openSocket}
      loadTranscript={loadTranscript}
      reloadPage={reloadPage}
      onEnded={setEnded}
    />
  );
}

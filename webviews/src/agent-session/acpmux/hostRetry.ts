import { peerLinkFailure, peerLinkFailureShows } from "./hostLine";

/// A refused handshake that offers Restart acpmux (`details.restartAcpmux`): another binary's
/// daemon holds this app's acpmux socket, and the app may replace it with its own on a click.
export function offersAcpmuxRestart(error: unknown): boolean {
  const details = (error as { details?: unknown } | null)?.details;
  return !!details && typeof details === "object" && (details as { restartAcpmux?: unknown }).restartAcpmux === true;
}

/// A host-owned update handoff or a lost transport is still recovering. A definite host refusal
/// (missing binary, stopped daemon, unsupported machine, untrusted folder) keeps its instructions.
/// Older bridges may omit retryability on socket failures; only errors without an owned code fall
/// back to recovery. Never infer it from the translated message or from the restart gate.
export function hostIsReconnecting(error: unknown): boolean {
  const fields = error as {
    code?: unknown;
    retryable?: unknown;
    details?: { reconnecting?: unknown };
    data?: { retryable?: unknown };
  } | null;
  if (fields?.details?.reconnecting === true) return true;
  // The chat's machine is reconnecting (acpmux `peer_unreachable`/`peer_disconnected`): acpmux
  // reconnects it on its own, and the request was not sent (hostLine.ts).
  if (peerLinkFailure(error)) return true;
  // acpmux marks a refusal a retry clears (`data.retryable`; direct.ts keeps `data` on the error).
  if (fields?.data?.retryable === true) return true;
  if (fields?.code === "native.not_connected" || fields?.code === "native.timed_out") return true;
  if (typeof fields?.retryable === "boolean") return fields.retryable;
  if (typeof fields?.code === "string") return false;
  return fields?.code === undefined;
}

/// A handshake refused because a reply would pass one message (`message.too_large`: a chat
/// whose records together were too large to open, on an acpmux before #28754). Asking again gets
/// the same reply, so the pane never asks on its own; the line's Retry still asks (Leo,
/// 2026-10-31: "this is completely hardlocked bc of message size").
export function hostRefusedTooLarge(error: unknown): boolean {
  return (error as { reason?: unknown } | null)?.reason === "message.too_large";
}

/// Whether the failure is one the pane clears by itself by asking again, so the person has nothing
/// to do: a lost or never-opened connection, a chat's machine that is reconnecting or rebooting, an
/// agent service that is starting (`hostIsReconnecting`). Not a chat too large to open (asking again
/// gets the same reply), not another build's acpmux holding this app's socket (`restartOffered`:
/// only Restart agent service clears it), not a refusal that waits on the person (an untrusted
/// folder, acpmux missing). Such a failure is one quiet "Reconnecting…" (HostError.tsx), however
/// long it lasts (Leo, 2026-11-12: "it should just automatically do stuff").
export function hostSelfRetrying(error: unknown, restartOffered: boolean): boolean {
  return hostIsReconnecting(error) && !hostRefusedTooLarge(error) && !restartOffered;
}

/// How long a pane's handshakes may keep failing while the host is still recovering (an update's
/// handoff, a daemon starting or restarting, a start that lost the lock race) before the pane says
/// so. Until then the pane shows nothing: no card, no header status, no button (Leo, 2026-10-29:
/// "STOP SHOWING FUCKING BULLSHIT ON LOAD"). 25 s: a daemon after an update answered 10 s after the
/// first failed handshake in the logged timeline (#27283), so a recovery past 25 s is a failure.
/// The page's own retries keep running past it, and a connect clears the line.
export const HOST_ERROR_DEADLINE_MS = 25_000;

/// Whether a failed handshake is said (one line above the composer) after the handshakes have been
/// failing for `failingForMs`. A refusal the host cannot recover from by itself (acpmux missing,
/// another build's daemon, a refused chat) is said at once; a recovery only after the deadline.
/// A chat whose machine is unreachable is said only once the person can act (hostLine.ts
/// `peerLinkFailureShows`): never while the machine is slow or restarting, else after two minutes.
///
/// `asleep` says whether the named machine is a Cloud machine the account says is paused or
/// resuming; such a machine is never said to be unreachable.
export function hostErrorShows(
  error: unknown,
  failingForMs: number,
  asleep: (peer: string | undefined) => boolean = () => false,
): boolean {
  const peer = peerLinkFailure(error);
  if (peer) return peerLinkFailureShows(peer, failingForMs, asleep(peer.peer));
  return !hostIsReconnecting(error) || failingForMs >= HOST_ERROR_DEADLINE_MS;
}

/// The wait before the next handshake. Looking for a daemon is cheap, so while the host is
/// recovering it is asked again within 2 s and the chat appears soon after the daemon answers; a
/// refusal that waits on the person backs off to one ask every 30 s, never stopping, so one the
/// host clears on its own (a daemon that is back after its machine rebooted) is found within 30 s
/// instead of hours later.
export const REFUSED_RETRY_MAX_MS = 30_000;

/// A chat on screen asks again within 500 ms for the first 10 s of a recovery (a daemon restart or
/// handoff usually ends sooner), so it is back within half a second of acpmux answering instead of up
/// to 2 s later. Asking is one connect from the app's host (`acpmux-bridge`, Swift
/// AgentPaneTransport); a hidden chat, or a recovery past 10 s, keeps 2 s.
///
/// A page that opens its own WebSocket (`browserSocket`: the dev slot's `acpmux-websocket`) keeps 2 s
/// too: Chromium holds back each of a renderer's WebSocket opens by 1-5 s × 2^min(failed, 16) / 65536
/// (network WebSocketPerProcessThrottler, failures counted over 2-4 min), so ~25 refused opens in 10 s
/// delay the one that would succeed by 1-5 s (first-load bench, 10 s drop: 791 -> 2618 ms).
export const QUICK_RETRY_MAX_MS = 500;
export const QUICK_RETRY_WINDOW_MS = 10_000;

export function quickRetry({
  shown,
  failingForMs,
  browserSocket = false,
}: {
  shown: boolean;
  failingForMs: number;
  browserSocket?: boolean;
}): boolean {
  return shown && !browserSocket && failingForMs < QUICK_RETRY_WINDOW_MS;
}

export function nextRetryDelay(delay: number, recovering: boolean, quick = false): number {
  return Math.min(delay * 2, recovering ? (quick ? QUICK_RETRY_MAX_MS : 2_000) : REFUSED_RETRY_MAX_MS);
}

/// The first wait before a reconnect.
export const RETRY_FIRST_MS = 250;
/// How long a connection stays up before its loss starts the backoff over. One that dropped
/// sooner (a daemon that crashes after attach, a socket the bridge replaces, a liveness check that
/// gives up) was not a recovery: the pane reconnected every 250 ms and drew the chat anew each
/// time (Leo's NIGHTLY, 2026-11-12: "this loop is just so fundamentally f***ing stupid").
export const CONNECTION_STABLE_MS = 30_000;
/// The longest wait between reconnects to a daemon that keeps dropping the pane soon after it
/// connects (direct.ts `RECONNECT_MAX_MS` is the same).
export const FLAP_RETRY_MAX_MS = 10_000;

/// The wait before reconnecting after an established connection was lost `upForMs` after it
/// connected, while the backoff stood at `delay`, and the backoff after it. Never start the backoff
/// over at a connect: only a connection that stayed up does (agent-pane-reconnect-loop.test.ts).
export function lostRetryDelay(delay: number, upForMs: number): { wait: number; next: number } {
  // Capped too: the handshakes before a first connect may have backed off far past it (a long outage).
  const wait =
    upForMs >= CONNECTION_STABLE_MS ? RETRY_FIRST_MS : Math.min(Math.max(delay, RETRY_FIRST_MS), FLAP_RETRY_MAX_MS);
  return { wait, next: Math.min(wait * 2, FLAP_RETRY_MAX_MS) };
}

/// One retry wait: `step` scaled to 50-100% (home-channels DaemonGate.tsx). Every tab restored over
/// one daemon loses it at the same moment; unjittered they would all ask again in lockstep.
export function jitteredDelay(step: number, random: () => number = Math.random): number {
  return Math.round(step * (0.5 + random() / 2));
}

/// What the pane's handshake loop does around a Restart acpmux.
export type AcpmuxRestartHooks = {
  /// Drops the automatic retry waiting to run and a Retry queued behind an attempt in flight.
  cancelRetries(): void;
  /// The card's in-flight state.
  changed(restarting: boolean): void;
  /// Whether a client connected meanwhile (then no second handshake runs).
  connected(): boolean;
  /// Asks the host again now, as Retry does.
  ask(): void;
};

/// How long the pane waits on the app's Restart acpmux before it asks the host again anyway.
export const RESTART_DEADLINE_MS = 25_000;

/// The pane's Restart acpmux. While one runs no handshake may start (``mayAsk``): not the
/// automatic retry, not a Retry queued behind an attempt that was in flight, so the old daemon is
/// never asked again while it shuts down. When the restart ends, one handshake runs unless a client
/// connected meanwhile. A second click while one runs does nothing.
export class AcpmuxRestartGate {
  private running = false;

  /// Whether a handshake may start now.
  mayAsk(): boolean {
    return !this.running;
  }

  async run(stop: () => Promise<unknown>, hooks: AcpmuxRestartHooks): Promise<void> {
    if (this.running) return;
    this.running = true;
    hooks.cancelRetries();
    hooks.changed(true);
    let deadline: ReturnType<typeof setTimeout> | undefined;
    try {
      // An app that never answers the restart (it hung, its reply was lost) must not hold the pane
      // on "Restarting…" with every handshake barred: past RESTART_DEADLINE_MS the gate opens and
      // the pane asks again, and its line becomes the wait's or the failure's, which offer Restart.
      await Promise.race([
        stop(),
        new Promise<void>((resolve) => {
          deadline = setTimeout(resolve, RESTART_DEADLINE_MS);
        }),
      ]);
    } catch {
      // The app answers `{stopped: false}` or fails; either way the pane asks again below.
    } finally {
      if (deadline !== undefined) clearTimeout(deadline);
      this.running = false;
      hooks.changed(false);
      if (!hooks.connected()) hooks.ask();
    }
  }
}

/// How long a lost connection, or a restore the host reports, stays unsaid before the pane's quiet
/// line shows. A recovery the person can do nothing about says nothing until it has lasted long
/// enough to matter (Leo, 2026-11-14: "i also want all our connectivity stuff to shut the f*** up").
/// 10 s is the bound the app already waits out for the same daemon before it says anything (its
/// startup deadline, its drop grace, the sidebar's "Connecting…" hold), and an update's handoff
/// answered within it (#27283), so a daemon restart, a handoff or a short drop shows nothing on any
/// open chat. At 1.5 s every open chat said "Reconnecting…" for each restart.
export const RECONNECT_LINE_AFTER_MS = 10_000;

/// What the host says while acpmux restores its chats after a start (`restoring`): how long it has
/// waited so far, in milliseconds, as of `at` (this page's `Date.now()` when it heard it).
export type HostRestoring = { waitedMs: number; at: number };

/// The host's word on a restore in progress, from its `acpmux-host-status` event's detail or a
/// refused handshake's `details` (`{restoring: {waitedMs}}`); undefined when it says none (a
/// missing, null or malformed `restoring` ends one).
export function readHostRestoring(source: unknown, at: number): HostRestoring | undefined {
  const restoring = (source as { restoring?: unknown } | null | undefined)?.restoring;
  const waited = (restoring as { waitedMs?: unknown } | null | undefined)?.waitedMs;
  if (typeof waited !== "number" || !Number.isFinite(waited) || waited < 0) return undefined;
  return { waitedMs: waited, at };
}

/// The quiet line the pane shows while it gets its chat back on its own (Leo, 2026-11-08: "it
/// fixes itself"): "Restoring sessions… m:ss" once the host says acpmux has been restoring its chats
/// for RECONNECT_LINE_AFTER_MS, else "Reconnecting…" once a lost connection has been coming back that long. Past
/// HOST_ERROR_DEADLINE_MS a reconnect is the waiting line's or the failure's (HostWaitingLine,
/// HostUnavailableLine), so this says nothing then. A failure the pane already says (`failureShown`:
/// a refusal said at once, such as another build's acpmux on the socket) is never covered by
/// "Reconnecting…": the person needs its Restart now, not after the deadline. The restore line
/// stays, since the host says it only while acpmux restores, and a refusal without it ends it.
export function hostRecoveryLine(state: {
  relinkingSince?: number;
  restoring?: HostRestoring;
  failureShown?: boolean;
  /// When the wait the waiting line counts began (HostWaitingLine `since`), if one runs. That line
  /// takes over only once its own wait reaches the deadline, which starts at the first handshake after
  /// the drop, a moment after `relinkingSince`: "Reconnecting…" stays until then, so no frame between
  /// the two lines draws neither (the line went for a second at the 25 s mark and came back).
  waitingSince?: number;
  now: number;
}): { kind: "restoring"; waitedMs: number } | { kind: "reconnecting" } | undefined {
  const { relinkingSince, restoring, failureShown, waitingSince, now } = state;
  if (restoring) {
    const waitedMs = restoring.waitedMs + Math.max(0, now - restoring.at);
    // A restore is as quiet as a reconnect until it has lasted as long: the usual one ends sooner.
    return waitedMs < RECONNECT_LINE_AFTER_MS ? undefined : { kind: "restoring", waitedMs };
  }
  if (relinkingSince === undefined || failureShown) return undefined;
  const waited = now - relinkingSince;
  if (waited < RECONNECT_LINE_AFTER_MS) return undefined;
  // Only a wait that began while this line showed hands over from it: a handshake started after the
  // deadline brings no "Reconnecting…" back.
  const handsOver =
    waitingSince !== undefined &&
    waitingSince - relinkingSince < HOST_ERROR_DEADLINE_MS &&
    now - waitingSince < HOST_ERROR_DEADLINE_MS;
  if (waited >= HOST_ERROR_DEADLINE_MS && !handsOver) return undefined;
  return { kind: "reconnecting" };
}

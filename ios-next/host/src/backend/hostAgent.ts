// Host side of signaling: answers phone offers with one WebRTC peer per
// sessionId and attaches each opened link to the HostCore.

import type { HostCore } from "../host.ts";
import { WebRtcPeer } from "../transport/webrtc.ts";
import type { Logger } from "../util.ts";
import { ApiClient, ApiError, IceCache } from "./api.ts";
import { SignalingClient, type SignalFrame } from "./signaling.ts";

/** How long a revoked phone session family stays refused. */
export const REVOKED_FAMILY_TTL_MS = 20 * 60_000;

function frameFamily(f: { family?: string | null }): string | undefined {
  return typeof f.family === "string" && f.family ? f.family : undefined;
}

interface PeerEntry {
  /** Set once ICE servers are known; candidates before that are buffered. */
  peer?: WebRtcPeer;
  pendingCandidates: { candidate: string; mid: string }[];
  /** Latest phone peerId seen for this session (changes if its signaling reconnects). */
  remotePeerId: string;
  /** Backend-stamped phone session family; revoking it drops the link. */
  family?: string;
  createdAt: number;
  closed: boolean;
}

export interface HostAgentOptions {
  api: ApiClient;
  core: HostCore;
  relayOnly?: boolean;
  log: Logger;
  /** Max concurrent phone peers. */
  maxPeers?: number;
  /** The host credential was revoked (host removed, account deleted, 401). */
  onRevoked?: (reason: string) => void;
  /** How often to re-validate the host token over HTTP (ms). */
  validateEveryMs?: number;
}

export class HostAgent {
  readonly signaling: SignalingClient;
  private readonly ice: IceCache;
  private readonly peers = new Map<string, PeerEntry>();
  private validateTimer: NodeJS.Timeout | null = null;
  /** family -> refuse until (ms). */
  private readonly revokedFamilies = new Map<string, number>();
  private revoked = false;

  constructor(private readonly opts: HostAgentOptions) {
    this.ice = new IceCache(opts.api, opts.log);
    this.signaling = new SignalingClient({ url: () => opts.api.signalUrl(), token: () => opts.api.bearer, log: opts.log });
    this.signaling.on("frame", (f) => void this.onFrame(f));
    this.signaling.on("revoked", (reason) => this.revoke(reason));
  }

  start(): void {
    void this.ice.get();
    this.signaling.start();
    // Re-validate the token even while signaling stays connected.
    this.validateTimer = setInterval(() => void this.validate(), this.opts.validateEveryMs ?? 10 * 60_000);
    this.validateTimer.unref();
  }

  /** Checks the host token over HTTP; revokes on 401/403. */
  async validate(): Promise<boolean> {
    try {
      await this.opts.api.ice();
      return true;
    } catch (err) {
      if (err instanceof ApiError && (err.status === 401 || err.status === 403)) {
        this.revoke(`the backend rejected the host token (HTTP ${err.status})`);
        return false;
      }
      return true; // network trouble is not revocation
    }
  }

  private revoke(reason: string): void {
    if (this.revoked) return;
    this.revoked = true;
    this.opts.log(`host credential revoked: ${reason}; closing every phone link`);
    for (const sessionId of [...this.peers.keys()]) this.dropPeer(sessionId, false);
    this.signaling.stop();
    if (this.validateTimer) clearInterval(this.validateTimer);
    this.opts.onRevoked?.(reason);
  }

  stop(): void {
    if (this.validateTimer) clearInterval(this.validateTimer);
    for (const sessionId of [...this.peers.keys()]) this.dropPeer(sessionId, true);
    this.signaling.stop();
  }

  get peerCount(): number {
    return this.peers.size;
  }

  /** Session ids and their current phone peer (tests, diagnostics). */
  sessions(): { sessionId: string; remotePeerId: string; family?: string; open: boolean }[] {
    return [...this.peers.entries()].map(([sessionId, e]) => ({
      sessionId,
      remotePeerId: e.remotePeerId,
      family: e.family,
      open: e.peer?.link.state === "open",
    }));
  }

  private async onFrame(f: SignalFrame): Promise<void> {
    const log = this.opts.log;
    switch (f.type) {
      case "revoked":
        this.revokeFamily(f.family);
        return;
      case "welcome":
        log(`signaling welcome as ${f.peerId}`);
        for (const family of f.revokedFamilies ?? []) this.revokeFamily(family);
        return;
      case "offer": {
        if (!f.from || !f.sessionId || !f.sdp) return;
        const sessionId = f.sessionId;
        const remotePeerId = f.from;
        const family = frameFamily(f);
        if (family && this.isRevoked(family)) {
          log(`[${sessionId}] refusing offer from revoked session family ${family}`);
          this.signaling.send({ type: "bye", to: remotePeerId, sessionId });
          return;
        }
        const existing = this.peers.get(sessionId);
        if (existing && existing.family !== family) {
          log(`[${sessionId}] ignoring offer for a session owned by another family`);
          return;
        }
        if (existing) this.dropPeer(sessionId, false);
        if (this.peers.size >= (this.opts.maxPeers ?? 16)) {
          const oldest = [...this.peers.entries()].sort((a, b) => a[1].createdAt - b[1].createdAt)[0];
          if (oldest) this.dropPeer(oldest[0], true);
        }
        // Register before awaiting ICE servers so trickled candidates that
        // arrive meanwhile are buffered instead of dropped.
        if (!family) log(`[${sessionId}] token without session family; allowing for now`);
        const entry: PeerEntry = { pendingCandidates: [], remotePeerId, family, createdAt: Date.now(), closed: false };
        this.peers.set(sessionId, entry);
        const iceServers = await this.ice.get();
        if (entry.closed || this.peers.get(sessionId) !== entry) return;
        const peer = new WebRtcPeer({
          role: "answerer",
          iceServers,
          // The phone can force TURN for this session ("policy":"relay").
          relayOnly: this.opts.relayOnly || f.policy === "relay",
          name: `host-${sessionId}`,
          log: (m) => log(`[${sessionId}] ${m}`),
          onSignal: (sig) => {
            if (sig.type === "description") {
              this.signaling.send({ type: "answer", to: entry.remotePeerId, sessionId, sdp: sig.sdp });
            } else {
              this.signaling.send({ type: "candidate", to: entry.remotePeerId, sessionId, candidate: sig.candidate, sdpMid: sig.sdpMid, sdpMLineIndex: sig.sdpMLineIndex });
            }
          },
        });
        entry.peer = peer;
        peer.link.on("state", (state) => {
          if (state === "open") {
            const pair = peer.selectedPair();
            log(`[${sessionId}] link open${peer.relayOnly ? " [relay only]" : ""} ${pair ? `${pair.local}/${pair.transport} -> ${pair.remote} (${pair.remoteAddress})` : ""}`);
            this.opts.core.attach(peer.link);
          } else if (state === "closed") {
            if (this.peers.get(sessionId) === entry) this.dropPeer(sessionId, true);
          }
        });
        // Give up on peers that never connect.
        setTimeout(() => {
          if (peer.link.state === "connecting" && this.peers.get(sessionId) === entry) {
            log(`[${sessionId}] connect timeout`);
            this.dropPeer(sessionId, true);
          }
        }, 45_000).unref();
        try {
          peer.setRemoteDescription(f.sdp, "offer");
          for (const c of entry.pendingCandidates) peer.addRemoteCandidate(c.candidate, c.mid);
          entry.pendingCandidates = [];
        } catch (err) {
          log(`[${sessionId}] bad offer: ${(err as Error).message}`);
          this.dropPeer(sessionId, true);
        }
        return;
      }
      case "candidate": {
        const e = this.sessionFor(f);
        if (!e || !f.candidate) return;
        if (e.peer) e.peer.addRemoteCandidate(f.candidate, f.sdpMid ?? "0");
        else e.pendingCandidates.push({ candidate: f.candidate, mid: f.sdpMid ?? "0" });
        return;
      }
      case "bye":
        if (this.sessionFor(f)) this.dropPeer(f.sessionId, false);
        return;
      case "error":
        log(`signaling error frame: ${f.code}${f.message ? ` ${f.message}` : ""}`);
        return;
      default:
        return;
    }
  }

  /**
   * The session a phone frame belongs to, only if the frame's backend-stamped
   * family matches the session's. Follows the phone's latest peerId (its
   * signaling may have reconnected).
   */
  private sessionFor(f: { sessionId: string; from?: string; family?: string | null }): PeerEntry | undefined {
    const e = this.peers.get(f.sessionId);
    if (!e) return undefined;
    if (e.family !== frameFamily(f)) {
      this.opts.log(`[${f.sessionId}] ignoring a frame from a different session family`);
      return undefined;
    }
    if (f.from && e.remotePeerId !== f.from) {
      this.opts.log(`[${f.sessionId}] phone signaling moved ${e.remotePeerId} -> ${f.from}`);
      e.remotePeerId = f.from;
    }
    return e;
  }

  private isRevoked(family: string): boolean {
    const until = this.revokedFamilies.get(family);
    if (until === undefined) return false;
    if (until > Date.now()) return true;
    this.revokedFamilies.delete(family);
    return false;
  }

  /** Refuses the family for 20 minutes and drops its live links now. */
  revokeFamily(family: string): void {
    if (!family) return;
    const now = Date.now();
    for (const [f, until] of this.revokedFamilies) if (until <= now) this.revokedFamilies.delete(f);
    this.revokedFamilies.set(family, now + REVOKED_FAMILY_TTL_MS);
    const doomed = [...this.peers.entries()].filter(([, e]) => e.family === family);
    this.opts.log(`phone session family ${family} revoked; dropping ${doomed.length} link(s)`);
    for (const [sessionId] of doomed) this.dropPeer(sessionId, false);
  }

  private dropPeer(sessionId: string, sendBye: boolean): void {
    const e = this.peers.get(sessionId);
    if (!e) return;
    this.peers.delete(sessionId);
    e.closed = true;
    if (sendBye) this.signaling.send({ type: "bye", to: e.remotePeerId, sessionId });
    e.peer?.close();
  }
}

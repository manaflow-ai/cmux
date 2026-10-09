// Host side of signaling: answers phone offers with one WebRTC peer per
// sessionId and attaches each opened link to the HostCore.

import type { HostCore } from "../host.ts";
import { WebRtcPeer } from "../transport/webrtc.ts";
import type { Logger } from "../util.ts";
import { ApiClient, IceCache } from "./api.ts";
import { SignalingClient, type SignalFrame } from "./signaling.ts";

interface PeerEntry {
  peer: WebRtcPeer;
  remotePeerId: string;
  createdAt: number;
}

export interface HostAgentOptions {
  api: ApiClient;
  core: HostCore;
  relayOnly?: boolean;
  log: Logger;
  /** Max concurrent phone peers. */
  maxPeers?: number;
}

export class HostAgent {
  readonly signaling: SignalingClient;
  private readonly ice: IceCache;
  private readonly peers = new Map<string, PeerEntry>();

  constructor(private readonly opts: HostAgentOptions) {
    this.ice = new IceCache(opts.api, opts.log);
    this.signaling = new SignalingClient({ url: () => opts.api.signalUrl(), log: opts.log });
    this.signaling.on("frame", (f) => void this.onFrame(f));
  }

  start(): void {
    void this.ice.get();
    this.signaling.start();
  }

  stop(): void {
    for (const [sessionId, e] of this.peers) {
      this.signaling.send({ type: "bye", to: e.remotePeerId, sessionId });
      e.peer.close();
    }
    this.peers.clear();
    this.signaling.stop();
  }

  get peerCount(): number {
    return this.peers.size;
  }

  private async onFrame(f: SignalFrame): Promise<void> {
    const log = this.opts.log;
    switch (f.type) {
      case "welcome":
        log(`signaling welcome as ${f.peerId}`);
        return;
      case "offer": {
        if (!f.from || !f.sessionId || !f.sdp) return;
        this.peers.get(f.sessionId)?.peer.close();
        if (this.peers.size >= (this.opts.maxPeers ?? 16)) {
          const oldest = [...this.peers.entries()].sort((a, b) => a[1].createdAt - b[1].createdAt)[0];
          if (oldest) this.dropPeer(oldest[0], true);
        }
        const iceServers = await this.ice.get();
        const remotePeerId = f.from;
        const sessionId = f.sessionId;
        const peer = new WebRtcPeer({
          role: "answerer",
          iceServers,
          // The phone can force TURN for this session ("policy":"relay").
          relayOnly: this.opts.relayOnly || f.policy === "relay",
          name: `host-${sessionId}`,
          log: (m) => log(`[${sessionId}] ${m}`),
          onSignal: (sig) => {
            if (sig.type === "description") {
              this.signaling.send({ type: "answer", to: remotePeerId, sessionId, sdp: sig.sdp });
            } else {
              this.signaling.send({ type: "candidate", to: remotePeerId, sessionId, candidate: sig.candidate, sdpMid: sig.sdpMid, sdpMLineIndex: sig.sdpMLineIndex });
            }
          },
        });
        this.peers.set(sessionId, { peer, remotePeerId, createdAt: Date.now() });
        peer.link.on("state", (state) => {
          if (state === "open") {
            const pair = peer.selectedPair();
            log(`[${sessionId}] link open${peer.relayOnly ? " [relay only]" : ""} ${pair ? `${pair.local}/${pair.transport} -> ${pair.remote} (${pair.remoteAddress})` : ""}`);
            this.opts.core.attach(peer.link);
          } else if (state === "closed") {
            if (this.peers.get(sessionId)?.peer === peer) this.dropPeer(sessionId, true);
          }
        });
        // Give up on peers that never connect.
        setTimeout(() => {
          if (peer.link.state === "connecting" && this.peers.get(sessionId)?.peer === peer) {
            log(`[${sessionId}] connect timeout`);
            this.dropPeer(sessionId, true);
          }
        }, 45_000).unref();
        try {
          peer.setRemoteDescription(f.sdp, "offer");
        } catch (err) {
          log(`[${sessionId}] bad offer: ${(err as Error).message}`);
          this.dropPeer(sessionId, true);
        }
        return;
      }
      case "candidate": {
        const e = this.peers.get(f.sessionId);
        if (e && f.candidate) e.peer.addRemoteCandidate(f.candidate, f.sdpMid ?? "0");
        return;
      }
      case "bye":
        this.dropPeer(f.sessionId, false);
        return;
      case "error":
        log(`signaling error frame: ${f.code}${f.message ? ` ${f.message}` : ""}`);
        return;
      default:
        return;
    }
  }

  private dropPeer(sessionId: string, sendBye: boolean): void {
    const e = this.peers.get(sessionId);
    if (!e) return;
    this.peers.delete(sessionId);
    if (sendBye) this.signaling.send({ type: "bye", to: e.remotePeerId, sessionId });
    e.peer.close();
  }
}

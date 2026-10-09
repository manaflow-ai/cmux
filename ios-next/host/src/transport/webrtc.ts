// WebRTC LinkTransport on node-datachannel (libdatachannel). Each lane is one
// negotiated, ordered, reliable data channel: ids 0/1/2, labels ctl/int/blk.
// Signaling is out of band: the peer reports local SDP and trickled
// candidates through onSignal and accepts remote ones through methods.

import nodeDataChannel, {
  type DataChannel,
  type IceServer,
  type PeerConnection,
  type RtcConfig,
} from "node-datachannel";
import { ChunkLink, LANES, LANE_IDS, type Lane } from "./link.ts";

/** ICE server as returned by GET /v1/ice (W3C RTCIceServer shape). */
export interface ApiIceServer {
  urls: string | string[];
  username?: string;
  credential?: string;
}

export type LocalSignal =
  | { type: "description"; sdp: string; sdpType: "offer" | "answer" }
  | { type: "candidate"; candidate: string; sdpMid: string; sdpMLineIndex: number };

export interface PeerOptions {
  role: "offerer" | "answerer";
  iceServers: ApiIceServer[];
  relayOnly?: boolean;
  name?: string;
  onSignal: (signal: LocalSignal) => void;
  log?: (msg: string) => void;
  /** Close the link if ICE stays disconnected for this long (ms). */
  disconnectTimeoutMs?: number;
}

/** Converts W3C ICE server entries to libdatachannel's config shape. */
export function toNdcIceServers(servers: ApiIceServer[]): (string | IceServer)[] {
  const out: (string | IceServer)[] = [];
  for (const s of servers) {
    const urls = Array.isArray(s.urls) ? s.urls : [s.urls];
    for (const url of urls) {
      const parsed = parseIceUrl(url);
      if (!parsed) continue;
      if (parsed.scheme === "stun" || parsed.scheme === "stuns") {
        out.push(`stun:${parsed.hostname.includes(":") ? `[${parsed.hostname}]` : parsed.hostname}:${parsed.port}`);
      } else {
        out.push({
          hostname: parsed.hostname,
          port: parsed.port,
          username: s.username,
          password: s.credential,
          relayType: parsed.scheme === "turns" ? "TurnTls" : parsed.transport === "tcp" ? "TurnTcp" : "TurnUdp",
        });
      }
    }
  }
  return out;
}

export function parseIceUrl(
  url: string,
): { scheme: "stun" | "stuns" | "turn" | "turns"; hostname: string; port: number; transport?: string } | null {
  const m = /^(stuns?|turns?):(?:\/\/)?(\[[^\]]+\]|[^:?/]+)(?::(\d+))?(?:\?(.*))?$/i.exec(url.trim());
  if (!m) return null;
  const scheme = m[1]!.toLowerCase() as "stun" | "stuns" | "turn" | "turns";
  const hostname = m[2]!.replace(/^\[|\]$/g, "");
  const defaultPort = scheme === "turns" || scheme === "stuns" ? 5349 : 3478;
  const port = m[3] ? Number(m[3]) : defaultPort;
  const transport = m[4] ? new URLSearchParams(m[4]).get("transport")?.toLowerCase() : undefined;
  return { scheme, hostname, port, transport };
}

const HIGH_WATER = 1024 * 1024;
const LOW_WATER = 256 * 1024;

class LaneChannel {
  private queue: Uint8Array[] = [];
  constructor(
    readonly dc: DataChannel,
    private readonly onError: (err: string) => void,
  ) {
    dc.setBufferedAmountLowThreshold(LOW_WATER);
    dc.onBufferedAmountLow(() => this.drain());
  }

  send(chunk: Uint8Array): void {
    if (this.queue.length > 0 || this.dc.bufferedAmount() > HIGH_WATER) {
      this.queue.push(chunk);
      return;
    }
    this.write(chunk);
  }

  private write(chunk: Uint8Array): void {
    try {
      this.dc.sendMessageBinary(chunk);
    } catch (err) {
      this.onError((err as Error).message);
    }
  }

  private drain(): void {
    while (this.queue.length > 0 && this.dc.bufferedAmount() <= HIGH_WATER && this.dc.isOpen()) {
      this.write(this.queue.shift()!);
    }
  }
}

export class WebRtcLink extends ChunkLink {
  private channels = new Map<Lane, LaneChannel>();
  private openCount = 0;

  constructor(private readonly peer: WebRtcPeer) {
    super();
  }

  describe(): string {
    const pair = this.peer.selectedPair();
    return pair ? `webrtc ${pair.local}->${pair.remote}` : "webrtc";
  }

  /** Creates the three negotiated channels. Must run once per peer. */
  attachChannels(pc: PeerConnection): void {
    for (const lane of LANES) {
      const dc = pc.createDataChannel(lane, { negotiated: true, id: LANE_IDS[lane] });
      const ch = new LaneChannel(dc, (err) => this.close(`send failed: ${err}`));
      this.channels.set(lane, ch);
      dc.onOpen(() => {
        this.openCount += 1;
        if (this.openCount === LANES.length) this.setState("open");
      });
      dc.onClosed(() => this.close(`channel ${lane} closed`));
      dc.onError((err) => this.close(`channel ${lane} error: ${err}`));
      dc.onMessage((msg) => {
        const bytes =
          typeof msg === "string"
            ? new TextEncoder().encode(msg)
            : msg instanceof ArrayBuffer
              ? new Uint8Array(msg)
              : new Uint8Array(msg.buffer, msg.byteOffset, msg.byteLength);
        this.receiveChunk(lane, bytes);
      });
    }
  }

  protected sendChunk(lane: Lane, chunk: Uint8Array): void {
    const ch = this.channels.get(lane);
    if (!ch) throw new Error(`lane ${lane} not ready`);
    ch.send(chunk);
  }

  protected closeTransport(): void {
    for (const ch of this.channels.values()) {
      try {
        ch.dc.close();
      } catch {}
    }
    this.channels.clear();
    this.peer.close();
  }

  /** Called by the peer when the peer connection dies. */
  transportClosed(reason: string): void {
    if (this.state !== "closed") this.close(reason);
  }
}

export interface SelectedPair {
  local: string;
  remote: string;
  localAddress: string;
  remoteAddress: string;
  transport: string;
}

/** One RTCPeerConnection carrying one Link. */
export class WebRtcPeer {
  readonly link: WebRtcLink;
  private readonly pc: PeerConnection;
  private closed = false;
  private haveRemote = false;
  private pendingCandidates: { candidate: string; mid: string }[] = [];
  private disconnectTimer: NodeJS.Timeout | null = null;
  private readonly log: (msg: string) => void;

  constructor(private readonly opts: PeerOptions) {
    this.log = opts.log ?? (() => {});
    const config: RtcConfig = {
      iceServers: toNdcIceServers(opts.iceServers),
      iceTransportPolicy: opts.relayOnly ? "relay" : "all",
      disableAutoNegotiation: true,
      maxMessageSize: 256 * 1024,
    };
    this.pc = new nodeDataChannel.PeerConnection(opts.name ?? opts.role, config);
    this.link = new WebRtcLink(this);
    this.pc.onLocalDescription((sdp, type) => {
      if (type !== "offer" && type !== "answer") return;
      opts.onSignal({ type: "description", sdp, sdpType: type });
    });
    this.pc.onLocalCandidate((candidate, mid) => {
      opts.onSignal({
        type: "candidate",
        candidate: candidate.replace(/^a=/, ""),
        sdpMid: mid,
        sdpMLineIndex: 0,
      });
    });
    this.pc.onStateChange((state) => {
      this.log(`peer state ${state}`);
      if (state === "connected" && this.disconnectTimer) {
        clearTimeout(this.disconnectTimer);
        this.disconnectTimer = null;
      }
      if (state === "disconnected" && !this.disconnectTimer) {
        this.disconnectTimer = setTimeout(
          () => this.link.transportClosed("ice disconnected"),
          opts.disconnectTimeoutMs ?? 15_000,
        );
      }
      if (state === "failed" || state === "closed") this.link.transportClosed(`peer ${state}`);
    });
    if (opts.role === "offerer") {
      this.link.attachChannels(this.pc);
      this.pc.setLocalDescription("offer");
    }
  }

  setRemoteDescription(sdp: string, type: "offer" | "answer"): void {
    if (this.closed) return;
    this.pc.setRemoteDescription(sdp, type);
    this.haveRemote = true;
    if (type === "offer") {
      this.link.attachChannels(this.pc);
      this.pc.setLocalDescription("answer");
    }
    for (const c of this.pendingCandidates) this.addRemoteCandidate(c.candidate, c.mid);
    this.pendingCandidates = [];
  }

  addRemoteCandidate(candidate: string, mid?: string | null): void {
    if (this.closed || !candidate) return;
    const m = mid ?? "0";
    if (!this.haveRemote) {
      this.pendingCandidates.push({ candidate, mid: m });
      return;
    }
    try {
      this.pc.addRemoteCandidate(candidate, m);
    } catch (err) {
      this.log(`ignored remote candidate: ${(err as Error).message}`);
    }
  }

  selectedPair(): SelectedPair | null {
    if (this.closed) return null;
    try {
      const pair = this.pc.getSelectedCandidatePair();
      if (!pair) return null;
      return {
        local: pair.local.type,
        remote: pair.remote.type,
        localAddress: `${pair.local.address}:${pair.local.port}`,
        remoteAddress: `${pair.remote.address}:${pair.remote.port}`,
        transport: pair.local.transportType,
      };
    } catch {
      return null;
    }
  }

  rttMs(): number | null {
    try {
      const r = this.pc.rtt();
      return r >= 0 ? r : null;
    } catch {
      return null;
    }
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    if (this.disconnectTimer) clearTimeout(this.disconnectTimer);
    try {
      this.pc.close();
    } catch {}
    this.link.transportClosed("closed");
  }
}

/** Releases libdatachannel threads so the process can exit. */
export function shutdownWebRtc(): void {
  try {
    nodeDataChannel.cleanup();
  } catch {}
}

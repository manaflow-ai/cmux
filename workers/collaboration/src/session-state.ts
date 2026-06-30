import { parseEnvelope, type PeerInfo } from "./protocol";

export interface RelaySocket {
  send(data: string): void;
  close(code: number, reason: string): void;
}

interface PeerConnection {
  peer: PeerInfo;
  socket: RelaySocket;
  lastHeartbeatAt: number;
}

export class CollaborationRelaySessionState {
  private peers = new Map<string, PeerConnection>();

  get peerCount(): number {
    return this.peers.size;
  }

  addPeer(sessionID: string, peer: PeerInfo, socket: RelaySocket, now: number): void {
    this.peers.set(peer.peerID, { peer, socket, lastHeartbeatAt: now });
    socket.send(JSON.stringify({
      type: "session.joined",
      sessionID,
      peers: [...this.peers.values()].map((entry) => entry.peer),
    }));
    this.broadcast(peer.peerID, { type: "peer.joined", peer });
  }

  handleMessage(peerID: string, data: string | ArrayBuffer, now: number): void {
    const entry = this.peers.get(peerID);
    if (!entry) return;
    const envelope = parseEnvelope(data);
    if (envelope === null) {
      this.closePeer(peerID, 1003, "invalid frame");
      this.dropPeer(peerID, "disconnect");
      return;
    }
    if (envelope.type === "peer.heartbeat") {
      entry.lastHeartbeatAt = now;
      this.peers.set(peerID, entry);
      return;
    }
    this.broadcast(peerID, { ...envelope, fromPeerID: peerID, receivedAt: now });
  }

  expire(now: number, timeoutMs: number): void {
    for (const [peerID, entry] of this.peers) {
      if (now - entry.lastHeartbeatAt > timeoutMs) {
        this.closePeer(peerID, 1001, "heartbeat timeout");
        this.dropPeer(peerID, "timeout");
      }
    }
  }

  dropPeer(peerID: string, reason: "disconnect" | "timeout" | "leave"): void {
    if (!this.peers.delete(peerID)) return;
    this.broadcast(peerID, { type: "peer.left", peerID, reason });
  }

  private broadcast(fromPeerID: string, body: unknown): void {
    const encoded = JSON.stringify(body);
    for (const [peerID, entry] of this.peers) {
      if (peerID === fromPeerID) continue;
      try {
        entry.socket.send(encoded);
      } catch {
        this.dropPeer(peerID, "disconnect");
      }
    }
  }

  private closePeer(peerID: string, code: number, reason: string): void {
    const entry = this.peers.get(peerID);
    if (!entry) return;
    try {
      entry.socket.close(code, reason);
    } catch {
      // Already closed.
    }
  }
}

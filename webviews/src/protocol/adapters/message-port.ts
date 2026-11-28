// MessagePort transport for iframes and workers. Strings pass as-is; binary frames are posted
// as a transferred ArrayBuffer copy. MessagePort has no portable close signal, so a peer that
// closes posts a `{"t":"bye"}` sentinel first (transport-level, never seen by Session); engines
// that fire the newer `close` event on ports are handled too. Both ends run this adapter, so a
// batch posts as one array (one structured-clone task instead of one per message).

import { BaseTransport, toUint8Array, type TransportMessage } from "../transport";

export interface MessagePortLike {
  postMessage(message: unknown, transfer?: Transferable[]): void;
  addEventListener(type: "message", listener: (event: { data: unknown }) => void): void;
  addEventListener(type: "close", listener: () => void): void;
  start?(): void;
  close(): void;
}

const BYE = '{"t":"bye"}';

export class MessagePortTransport extends BaseTransport {
  private readonly port: MessagePortLike;

  constructor(port: MessagePortLike) {
    super();
    this.port = port;
    port.addEventListener("message", (event) => {
      const data = event.data;
      if (Array.isArray(data)) for (const item of data) this.receive(item);
      else this.receive(data);
    });
    port.addEventListener("close", () => this.finish({ reason: "port closed" }));
    port.start?.();
  }

  private receive(data: unknown): void {
    if (data === BYE) {
      this.port.close();
      this.finish({ reason: "peer closed" });
    } else if (typeof data === "string") this.deliver(data);
    else if (data instanceof ArrayBuffer || ArrayBuffer.isView(data)) this.deliver(toUint8Array(data));
  }

  protected sendRaw(msg: TransportMessage): void {
    if (typeof msg === "string") {
      this.port.postMessage(msg);
      return;
    }
    const copy = msg.slice();
    this.port.postMessage(copy.buffer, [copy.buffer]);
  }

  sendBatch(msgs: readonly TransportMessage[]): void {
    if (this.closed) throw new Error("transport is closed");
    const transfer: ArrayBuffer[] = [];
    const items = msgs.map((msg) => {
      if (typeof msg === "string") return msg;
      const copy = msg.slice();
      transfer.push(copy.buffer);
      return copy.buffer;
    });
    this.port.postMessage(items, transfer);
  }

  protected closeRaw(): void {
    try {
      this.port.postMessage(BYE);
    } finally {
      this.port.close();
    }
  }
}

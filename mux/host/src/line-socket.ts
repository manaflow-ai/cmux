import { connect, type Socket } from "node:net";

/**
 * One newline-delimited JSON connection over a Unix socket. Both owners this
 * host talks to (the cmux daemon, acpmux) frame messages this way.
 */
export class LineSocket {
  private buffer = "";
  private closed = false;
  private readonly closeListeners = new Set<(error?: Error) => void>();
  private lastError?: Error;

  private constructor(
    private readonly socket: Socket,
    private readonly onMessage: (message: Record<string, unknown>) => void,
  ) {
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => this.read(chunk));
    socket.on("error", (error) => {
      this.lastError = error;
      socket.destroy();
    });
    socket.on("close", () => {
      this.closed = true;
      for (const listener of this.closeListeners) listener(this.lastError);
    });
  }

  static open(
    path: string,
    onMessage: (message: Record<string, unknown>) => void,
  ): Promise<LineSocket> {
    return new Promise((resolve, reject) => {
      const socket = connect(path);
      const failed = (error: Error) => reject(error);
      socket.once("error", failed);
      socket.once("connect", () => {
        socket.off("error", failed);
        resolve(new LineSocket(socket, onMessage));
      });
    });
  }

  get isClosed(): boolean {
    return this.closed;
  }

  send(message: unknown): void {
    if (this.closed) throw new Error("connection closed");
    this.socket.write(`${JSON.stringify(message)}\n`);
  }

  onClose(listener: (error?: Error) => void): () => void {
    if (this.closed) {
      listener(this.lastError);
      return () => {};
    }
    this.closeListeners.add(listener);
    return () => this.closeListeners.delete(listener);
  }

  close(): void {
    this.socket.end();
    this.socket.destroy();
  }

  private read(chunk: string): void {
    this.buffer += chunk;
    for (let newline = this.buffer.indexOf("\n"); newline >= 0; newline = this.buffer.indexOf("\n")) {
      const line = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      if (!line.trim()) continue;
      let message: unknown;
      try {
        message = JSON.parse(line);
      } catch {
        continue;
      }
      if (message && typeof message === "object") this.onMessage(message as Record<string, unknown>);
    }
  }
}

/**
 * Joins a client WebSocket to the provider's terminal socket through a
 * Workers WebSocketPair. Each frame is forwarded from its message event as it
 * arrives, so nothing is buffered here and order is preserved in both
 * directions.
 *
 * Binary frames (terminal bytes) pass through unchanged. Text frames are
 * control messages: the bridge re-serializes the known ones with an allowlist
 * of fields, replaces provider error prose with a fixed message, and drops
 * anything else, so the client never sees a provider id or field it did not
 * ask for, and the provider never receives a control message the cmux
 * protocol does not define.
 */
import { Schema } from "effect";

const ServerFrame = Schema.Union(
  Schema.Struct({
    type: Schema.Literal("sessionInfo"),
    sessionId: Schema.Int,
    slug: Schema.optional(Schema.NullOr(Schema.String)),
    created: Schema.optional(Schema.Boolean),
  }),
  Schema.Struct({ type: Schema.Literal("exited"), exitCode: Schema.Int }),
  Schema.Struct({ type: Schema.Literal("error"), message: Schema.String }),
);

const ClientFrame = Schema.Union(
  Schema.Struct({
    type: Schema.Literal("resize"),
    cols: Schema.Int.pipe(Schema.between(1, 1000)),
    rows: Schema.Int.pipe(Schema.between(1, 1000)),
  }),
  Schema.Struct({ type: Schema.Literal("signal"), signal: Schema.Literal("sigint", "sigkill") }),
);

const decodeServer = Schema.decodeUnknownOption(Schema.parseJson(ServerFrame));
const decodeClient = Schema.decodeUnknownOption(Schema.parseJson(ClientFrame));

export const TERMINAL_ERROR_MESSAGE = "The terminal reported an error";

/** The cmux form of a provider text frame, or null to drop it. */
export function serverTextFrame(data: string): string | null {
  const frame = decodeServer(data);
  if (frame._tag === "None") return null;
  const value = frame.value;
  switch (value.type) {
    case "sessionInfo":
      return JSON.stringify({
        type: "sessionInfo",
        sessionId: value.sessionId,
        name: value.slug ?? null,
        created: value.created ?? true,
      });
    case "exited":
      return JSON.stringify({ type: "exited", exitCode: value.exitCode });
    case "error":
      // Provider prose can name hosts, ids or accounts: never forward it.
      return JSON.stringify({ type: "error", message: TERMINAL_ERROR_MESSAGE });
  }
}

/** The provider form of a client text frame, or null to drop it. */
export function clientTextFrame(data: string): string | null {
  const frame = decodeClient(data);
  if (frame._tag === "None") return null;
  const value = frame.value;
  return value.type === "resize"
    ? JSON.stringify({ type: "resize", cols: value.cols, rows: value.rows })
    : JSON.stringify({ type: "signal", signal: value.signal });
}

/**
 * Close codes a peer may send are 1000 and 3000-4999. A normal end (1000,
 * 1001 going away, 1005 no status) stays normal; an abnormal one becomes 1011.
 */
const sendableCode = (code: number): number =>
  code === 1000 || code === 1001 || code === 1005 ? 1000 : code >= 3000 && code <= 4999 ? code : 1011;

const closeQuietly = (socket: WebSocket, code: number, reason: string) => {
  try {
    socket.close(sendableCode(code), reason);
  } catch {
    // Already closed or closing.
  }
};

const sendQuietly = (socket: WebSocket, data: string | ArrayBuffer, onFailure: () => void) => {
  try {
    socket.send(data);
  } catch {
    onFailure();
  }
};

/**
 * Accepts `upstream`, pairs it with a new socket for the client, and returns
 * the client's end, to be handed back in the 101 response.
 */
export function bridgeTerminal(upstream: WebSocket): WebSocket {
  const pair = new WebSocketPair();
  const client = pair[0];
  const server = pair[1];
  // Binary frames must arrive as ArrayBuffer: a Blob (the default binaryType)
  // would be stringified by send() and could only be read back asynchronously,
  // which would break frame order.
  server.binaryType = "arraybuffer";
  upstream.binaryType = "arraybuffer";
  server.accept();
  upstream.accept();

  const fail = () => {
    closeQuietly(server, 1011, "terminal connection lost");
    closeQuietly(upstream, 1011, "client connection lost");
  };

  upstream.addEventListener("message", (event) => {
    if (typeof event.data === "string") {
      const frame = serverTextFrame(event.data);
      if (frame !== null) sendQuietly(server, frame, fail);
    } else if (event.data instanceof ArrayBuffer) {
      sendQuietly(server, event.data, fail);
    }
  });
  server.addEventListener("message", (event) => {
    if (typeof event.data === "string") {
      const frame = clientTextFrame(event.data);
      if (frame !== null) sendQuietly(upstream, frame, fail);
    } else if (event.data instanceof ArrayBuffer) {
      sendQuietly(upstream, event.data, fail);
    }
  });
  // Provider close reasons are not forwarded: they are provider prose.
  // Each close is answered on the socket that started it (finishing its closing
  // handshake) and passed on to the other side.
  upstream.addEventListener("close", (event) => {
    closeQuietly(upstream, event.code, "");
    closeQuietly(server, event.code, "");
  });
  server.addEventListener("close", (event) => {
    closeQuietly(server, event.code, "");
    closeQuietly(upstream, event.code, "");
  });
  upstream.addEventListener("error", fail);
  server.addEventListener("error", fail);
  return client;
}

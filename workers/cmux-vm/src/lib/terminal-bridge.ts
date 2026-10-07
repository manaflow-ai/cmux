/**
 * Joins a client WebSocket to the provider's terminal socket through a
 * Workers WebSocketPair. Each frame is forwarded from its message event as it
 * arrives, so nothing is buffered here and order is preserved in both
 * directions.
 *
 * Binary frames (terminal bytes) pass through unchanged. Text frames are
 * control messages: the bridge re-serializes the known ones with an allowlist
 * of fields, rewrites provider wording out of error messages, and drops
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

export interface BridgeContext {
  /** The provider's id for the VM; replaced by `publicId` wherever a frame mentions it. */
  readonly scrub: string;
  readonly publicId: string;
}

const PROVIDER_WORD = /freestyle/gi;

const scrubText = (text: string, context: BridgeContext): string =>
  text.split(context.scrub).join(context.publicId).replace(PROVIDER_WORD, "cmux VM");

/** The cmux form of a provider text frame, or null to drop it. */
export function serverTextFrame(data: string, context: BridgeContext): string | null {
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
      return JSON.stringify({ type: "error", message: scrubText(value.message, context) });
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

/** Close codes a peer may send: 1000, or an application code. Anything else becomes 1011. */
const sendableCode = (code: number): number => (code === 1000 || (code >= 3000 && code <= 4999) ? code : 1011);

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
export function bridgeTerminal(upstream: WebSocket, context: BridgeContext): WebSocket {
  const pair = new WebSocketPair();
  const client = pair[0];
  const server = pair[1];
  server.accept();
  upstream.accept();

  const fail = () => {
    closeQuietly(server, 1011, "terminal connection lost");
    closeQuietly(upstream, 1011, "client connection lost");
  };

  upstream.addEventListener("message", (event) => {
    if (typeof event.data === "string") {
      const frame = serverTextFrame(event.data, context);
      if (frame !== null) sendQuietly(server, frame, fail);
    } else {
      sendQuietly(server, event.data, fail);
    }
  });
  server.addEventListener("message", (event) => {
    if (typeof event.data === "string") {
      const frame = clientTextFrame(event.data);
      if (frame !== null) sendQuietly(upstream, frame, fail);
    } else {
      sendQuietly(upstream, event.data, fail);
    }
  });
  // Provider close reasons are not forwarded: they are provider prose.
  upstream.addEventListener("close", (event) => closeQuietly(server, event.code, ""));
  server.addEventListener("close", (event) => closeQuietly(upstream, event.code, ""));
  upstream.addEventListener("error", fail);
  server.addEventListener("error", fail);
  return client;
}

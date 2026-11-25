import type { ComposerAttachment } from "../attachments";

export type AcpmuxHostConfig = {
  protocolVersion: number;
  /// `acpmux-bridge`: the app's host owns the socket and its tokens (bridgeSocket.ts); this page
  /// gets neither endpoint nor token. `acpmux-websocket`: a real socket, only for the browser dev
  /// slot (devHost.ts) and mock mode.
  transport: "acpmux-websocket" | "acpmux-bridge";
  endpoint?: string;
  token?: string;
  /** The shipped /app/ browser shell authenticates its own device on every socket. */
  browserDevice?: boolean;
  sessionId?: string;
  /** A pane opened as a new chat: do not fall back to the most recent session; the first prompt creates one. */
  newSession?: boolean;
  /** A tab's recorded session (`sessionId`) must exist. When the daemon has no such session, or it
   * goes away, the pane says so rather than showing another chat, and marks nothing seen. */
  sessionMustExist?: boolean;
  /** A new chat's working directory, inherited from the tab it was opened from. */
  cwd?: string;
  /** Text the composer starts with. Shown, never sent by itself. */
  draft?: string;
  /** A new chat's first prompt, sent once the client connects (onboarding's first task). */
  prompt?: string;
  /** Attachments of the seeded prompt, with file references on this chat's machine. */
  promptAttachments?: ComposerAttachment[];
  /** The model a new chat starts on before its first prompt. */
  model?: string;
  /** Explicit startup harness; omitted uses the existing daemon default. */
  harness?: string;
  /** Validated peer selected by the host's New Agent Chat action. */
  peer?: string;
  /** An outside Claude Code or Codex chat this pane resumes once it connects. */
  adopt?: AcpmuxAdopt;
  /** A chat opened for its workspace (Cmd-I's chat dock): its first prompt carries the workspace
   *  context (workspaceContext.ts), hidden from the transcript. */
  workspaceContext?: boolean;
};

/** A harness's own session for acpmux to adopt (`_meta.acpmux.adopt`). */
export type AcpmuxAdopt = {
  harness: string;
  agentSessionId: string;
  ifLive?: "fork" | "open";
  /** Show the chat and follow it without running it, until Take Over (acpmux `hub/watch.rs`). */
  watch?: boolean;
};

/** `session/new` params: the host's cwd when it gave one, else acpmux's default. An adopt
 *  sends no cwd: acpmux resumes the chat where its harness recorded it. */
/// Where a new session starts: `cwd` when given; another machine (`peer`) or no project never
/// inherits this tab's folder, which is a path on this Mac (the peer starts where it defaults).
export function newSessionHost(
  host: Pick<AcpmuxHostConfig, "cwd" | "adopt">,
  cwd: string | undefined,
  peer: string | undefined,
  noProject: boolean,
): Pick<AcpmuxHostConfig, "cwd" | "adopt"> & { peer?: string } {
  return cwd ? { cwd, peer } : noProject || peer ? { peer } : { ...host, peer };
}

export function newSessionParams(
  host: Pick<AcpmuxHostConfig, "cwd" | "adopt"> & { peer?: string },
  harness?: string,
  noProject = false,
  model?: string,
  additionalDirectories?: readonly string[],
  restricted = false,
  autoPlace = false,
): Record<string, unknown> {
  if (host.adopt)
    return {
      mcpServers: [],
      _meta: { acpmux: { harness: harness ?? host.adopt.harness, adopt: host.adopt } },
    };
  return {
    ...(host.cwd ? { cwd: host.cwd } : {}),
    mcpServers: [],
    // The folders the chat sees beside its own (extraFolders.ts, cmux#32811): the machine's own
    // paths, never its cwd; left out for none.
    ...(additionalDirectories?.length ? { additionalDirectories: [...additionalDirectories] } : {}),
    _meta: {
      acpmux: {
        harness,
        ...(host.peer ? { peer: host.peer } : {}),
        // The model the page showed, for a chat on another machine (acpmux `model_request`).
        ...(model ? { model } : {}),
        // Do not work in a project: the host starts the chat in its agent-home folder, not the
        // workspace's (AcpmuxPathPolicy), and strips this before acpmux sees it.
        ...(noProject ? { noProject: true } : {}),
        // Read-only in a folder the person declined (acpmux hub/restricted.rs).
        ...(restricted ? { restricted: true } : {}),
        // The person's place pick was Auto: with no room anywhere acpmux may wait for a machine
        // being added (hub/admission.rs). An explicit This Mac or machine never sends it.
        ...(autoPlace ? { autoPlace: true } : {}),
      },
    },
  };
}

export function liveDetails(details: unknown): { canFork: boolean; command?: string } {
  const d = details && typeof details === "object" ? (details as Record<string, unknown>) : {};
  return {
    canFork: d.canFork === true,
    ...(typeof d.command === "string" && d.command ? { command: d.command } : {}),
  };
}

/** True when a `session/new` result resumed `adopt`. A daemon without adopt ignores the request
 *  and starts a fresh chat, whose `agentSessionId` is its own or absent. */
export function adoptedBy(result: any, adopt: AcpmuxAdopt): boolean {
  return result?._meta?.acpmux?.agentSessionId === adopt.agentSessionId;
}

/// Opens the client's socket; mock mode passes an in-page daemon (mock.ts), the app the host
/// bridge (bridgeSocket.ts). `protocols` carries the listener token (`tokenProtocols`): acpmux
/// takes it only from a header, never the URL, which logs, history and a Referer keep.
export type OpenSocket = (url: URL, protocols?: string[]) => WebSocket;

/// The subprotocol acpmux answers a browser's upgrade with; it never echoes the token.
export const ACPMUX_PROTOCOL = "acpmux.v1";

/// The WebSocket subprotocols that carry `token`: a browser cannot set an Authorization header.
export function tokenProtocols(token: string): string[] {
  return [ACPMUX_PROTOCOL, `acpmux.token.${token}`];
}

/// The placeholder URL of a bridge connection (never dialed).
export const BRIDGE_URL = "cmux-bridge://acpmux/";

/// Where git reads go: the native host, or in mock mode the daemon the socket reaches.
export type GitRoute = "native" | "daemon";

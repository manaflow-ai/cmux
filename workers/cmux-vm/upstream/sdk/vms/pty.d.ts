import type { FreestyleClient } from "../client.js";
/** Text frames sent by the server. Binary frames are raw terminal output. */
export type PtyServerMsg = {
    type: "sessionInfo";
    sessionId: number;
    slug?: string;
    created?: boolean;
} | {
    type: "exited";
    exitCode: number;
} | {
    type: "error";
    message: string;
    fatal?: boolean;
} | {
    type: "keepalive";
    intervalMs: number;
} | {
    type: "replayStart";
    exact?: boolean;
} | {
    type: "replayEnd";
};
/** Text frames the client may send. Binary frames are raw terminal input. */
export type PtyClientMsg = {
    type: "resize";
    cols: number;
    rows: number;
} | {
    type: "signal";
    signal: "sigint" | "sigkill";
};
export interface PtySessionInfo {
    /** Per-VM session id, for attaching or closing this session. */
    sessionId: number;
    /** `"running"` while the shell is alive, `"exited"` once it has terminated. */
    state: string;
    /** Unix timestamp, in seconds, when the session was opened. */
    createdUnix: number;
    cols: number;
    rows: number;
    /** Exit code, present only once the session has exited. */
    exitCode?: number | null;
    /**
     * Linux user the session runs as, named even when the open left the choice to
     * the VM's default. Absent only for a session opened by a guest agent that
     * predates that default, which ran it as root.
     */
    linuxUser?: string | null;
    /**
     * The name this session was opened with. Retained after exit until the
     * session is explicitly closed or reaped.
     */
    slug?: string | null;
}
export interface ListPtySessionsResult {
    sessions: PtySessionInfo[];
}
export interface ClosePtySessionResult {
    sessionId: number;
    /** Exit code if the session had already exited. Absent when it was still running. */
    exitCode?: number | null;
}
export interface PtyOpenOptions {
    /** Command to run; omit for a login shell. */
    exec?: string;
    /** Initial width in columns (default 80). */
    cols?: number;
    /** Initial height in rows (default 24). */
    rows?: number;
    /**
     * Guest Linux user to run as. Omit for the VM's default user: the account
     * holding uid 1000, or `root` in an image that has no such account.
     */
    linuxUser?: string;
    /**
     * Name this session, so you can reattach to it later without storing the id
     * we mint — `vm.pty.attach({ session: "main" })` from anywhere, any time.
     *
     * Get-or-create: if a session already has this name you get *that* one back —
     * alive, or exited with its final output and exit code still readable — and
     * `exec` is not run. `session.created` tells you which happened. Starting
     * over is `close()` then `open()` again, which is deliberate: it destroys the
     * dead session's output, and that output is usually why you came looking.
     *
     * Lowercase letters, digits and hyphens, and not all digits (session ids are
     * bare integers, so an all-digit name could not be told apart from one).
     */
    slug?: string;
    /**
     * Respawn the shell in place when it exits, keeping this session's id, name
     * and scrollback — for a terminal that should outlive whatever runs in it.
     * A command that dies at startup is not respawned forever: after a few exits
     * in quick succession the session is left dead so the error stays readable.
     *
     * Leave this off if you are waiting on a command's exit code. A session that
     * comes back to life reports `running` again, and its `exitCode` becomes the
     * next shell's.
     */
    replaceOnExit?: boolean;
}
/** A session's id, or the slug it was opened with. */
export type PtySessionSelector = number | string;
export interface PtyAttachOptions {
    /** The session to reattach to: its id, or the slug it was opened with. */
    session: PtySessionSelector;
    /** Guest Linux user that must own the session. */
    linuxUser?: string;
}
export interface PtySessionEvents {
    /** Opt in to automatic reattachment after a successful open/attach. */
    reconnect?: boolean | PtyReconnectOptions;
    /** Maximum time to receive sessionInfo on each connection. Default: 15 seconds. */
    connectTimeoutMs?: number;
    onStateChange?: (state: PtyConnectionState) => void;
    /** Exact retained-output boundaries, on agents supporting replay events. */
    onReplayStart?: (info: {
        exact: boolean;
    }) => void;
    onReplayEnd?: () => void;
    onData?: (data: Uint8Array) => void;
    onExit?: (exitCode: number) => void;
    onClose?: (info: {
        wasClean: boolean;
        code: number;
        reason: string;
    }) => void;
    onError?: (err: unknown) => void;
}
/** Minimal surface both `ws` (Node) and the browser's native `WebSocket` provide. */
interface Socket {
    readonly readyState: number;
    send(data: string | Uint8Array): void;
    close(code?: number, reason?: string): void;
    on?(event: "open" | "message" | "close" | "error", listener: (...args: unknown[]) => void): void;
    addEventListener?(event: string, listener: (event: unknown) => void): void;
    removeEventListener?(event: string, listener: (event: unknown) => void): void;
    off?(event: string, listener: (...args: unknown[]) => void): void;
}
export type PtyConnectionState = "connecting" | "connected" | "reconnecting" | "closed" | "exited";
export interface PtyReconnectOptions {
    /** Total time to recover one dropped connection. Default: five minutes. */
    timeoutMs?: number;
    /** Initial backoff, with 30% jitter. Default: 400ms. */
    initialDelayMs?: number;
    /** Backoff ceiling before jitter. Default: 10 seconds. */
    maxDelayMs?: number;
}
interface SessionTransport {
    reconnect?: boolean | PtyReconnectOptions;
    connectTimeoutMs?: number;
    dimensions?: {
        cols: number;
        rows: number;
    };
    dial: (sessionId: number, signal: AbortSignal) => Promise<Socket>;
}
/** A stable handle across reattachments. Input is never retried or buffered. */
export declare class PtySession {
    private readonly events;
    private readonly transport?;
    private _sessionId;
    private _slug;
    private _created;
    private _state;
    private socket;
    private listeners;
    private retryTimer?;
    private connectTimer?;
    private healthTimer?;
    private controller?;
    private generation;
    private attempt;
    private deadline;
    private stopped;
    private exited;
    private fatal;
    private established;
    private closeReported;
    private lastFrameAt;
    private silenceMs;
    private dimensions?;
    private removeWakeListeners?;
    private resolveReady;
    private rejectReady;
    /** Resolves only once sessionInfo has arrived, including when attaching by slug. */
    readonly ready: Promise<void>;
    constructor(socket: Socket, sessionId: number, events?: PtySessionEvents, transport?: SessionTransport | undefined);
    private setState;
    private clearConnection;
    private bind;
    private lost;
    private scheduleRetry;
    private redial;
    private finish;
    /** Retry now after a network change or an exhausted retry budget. Never opens a new shell. */
    reconnect(): void;
    /** Send input once. Throws while disconnected; uncertain keystrokes are never replayed. */
    write(data: Uint8Array | string): void;
    /** Remember the latest dimensions and apply them again after recovery. */
    resize(options: {
        cols: number;
        rows: number;
    }): void;
    signal(signal: "sigint" | "sigkill"): void;
    /** Cancel recovery and detach. The guest process remains alive. */
    detach(): void;
    get sessionId(): number;
    get slug(): string | undefined;
    get created(): boolean;
    get readyState(): number;
    get state(): PtyConnectionState;
}
/** The `vm.pty` surface: open/attach terminal WebSockets, and list/close sessions over REST. */
export declare class VmPty {
    private readonly client;
    private readonly basePath;
    constructor(client: FreestyleClient, basePath: string);
    /**
     * Open a new terminal on the VM. The returned session's data/exit
     * listeners are live from the moment the socket connects — installed
     * before we even know the session id — so a command that produces output
     * (or exits) immediately can never race past them.
     */
    open(options?: PtyOpenOptions & PtySessionEvents): Promise<PtySession>;
    /** Reattach to an existing session; retained scrollback replays first. */
    attach(options: PtyAttachOptions & PtySessionEvents): Promise<PtySession>;
    private session;
    /** List the VM's terminal sessions, running and recently exited. */
    list(options?: {
        linuxUser?: string;
    }): Promise<ListPtySessionsResult>;
    /** Kill a terminal session and remove it. */
    close(session: PtySessionSelector, options?: {
        linuxUser?: string;
    }): Promise<ClosePtySessionResult>;
}
/** PTY operations scoped to one existing Linux user by `vm.linuxUser(...)`. */
export declare class VmLinuxUserPty {
    private readonly pty;
    private readonly linuxUser;
    constructor(pty: VmPty, linuxUser: string);
    open(options?: Omit<PtyOpenOptions, "linuxUser"> & PtySessionEvents): Promise<PtySession>;
    attach(options: Omit<PtyAttachOptions, "linuxUser"> & PtySessionEvents): Promise<PtySession>;
    list(): Promise<ListPtySessionsResult>;
    close(session: PtySessionSelector): Promise<ClosePtySessionResult>;
}
export {};
//# sourceMappingURL=pty.d.ts.map
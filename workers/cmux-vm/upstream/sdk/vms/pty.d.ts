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
     * The name this session was opened with, while it still answers to it.
     * Released the moment the shell exits, so an exited session reports none and
     * is addressable only by `sessionId`.
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
}
/**
 * One interactive terminal session. Sessions are owned by the guest agent and
 * outlive the connection that opened them: closing this only detaches, so the
 * shell keeps running and a later `attach()` can pick it back up.
 */
/** Internal-only: lets {@link VmPty.open} learn the session id from the very
 *  same listener that goes on to handle data/exit frames, so there's never a
 *  gap between a throwaway listener and the real one where a fast command's
 *  output (or even its exit) could arrive and be dropped. */
interface InternalPtySessionEvents extends PtySessionEvents {
    onSessionInfo?: (sessionId: number) => void;
}
export declare class PtySession {
    private _sessionId;
    private _slug;
    private _created;
    private readonly socket;
    constructor(socket: Socket, sessionId: number, events?: InternalPtySessionEvents);
    /** Send raw bytes (or UTF-8 text) to the guest's stdin. */
    write(data: Uint8Array | string): void;
    resize(options: {
        cols: number;
        rows: number;
    }): void;
    signal(sig: "sigint" | "sigkill"): void;
    private sendControl;
    /** Close the connection. The shell keeps running; a later `attach()` can reconnect. */
    detach(): void;
    get sessionId(): number;
    /**
     * The name this session answers to, from the server's `sessionInfo` frame.
     * `undefined` for a session opened without a slug — reattach to that one by
     * `sessionId` instead.
     */
    get slug(): string | undefined;
    /**
     * Whether `open()` started this shell, or handed back one that was already
     * running under the same `slug`. `false` means your `exec` never ran — check
     * it before waiting on output from a command you thought you started.
     */
    get created(): boolean;
    get readyState(): number;
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
import type { PtyOpenOptions, PtySession, PtySessionEvents, VmPty, VmLinuxUserPty } from "./pty.js";
interface Disposable {
    dispose(): void;
}
interface SequenceId {
    prefix?: string;
    intermediates?: string;
    final: string;
}
/** Structural xterm.js surface: the SDK does not bundle or import xterm. */
export interface XtermTerminal {
    cols: number;
    rows: number;
    write(data: string | Uint8Array, callback?: () => void): void;
    onData(listener: (data: string) => void): Disposable;
    onResize(listener: (size: {
        cols: number;
        rows: number;
    }) => void): Disposable;
    parser: {
        registerCsiHandler(id: SequenceId, handler: () => boolean): Disposable;
        registerDcsHandler(id: SequenceId, handler: () => boolean): Disposable;
    };
}
export type ConnectXtermOptions = PtyOpenOptions & PtySessionEvents & {
    pty: VmPty | VmLinuxUserPty;
    terminal: XtermTerminal;
    slug: string;
};
/**
 * Connect xterm.js to a persistent named session, with reconnect enabled by
 * default. Resets the display before replay and mutes recorded terminal queries
 * until xterm has parsed the replay. dispose() detaches without killing the shell.
 */
export declare function connectXterm({ pty, terminal, ...options }: ConnectXtermOptions): Promise<{
    session: PtySession;
    dispose(): void;
}>;
export {};
//# sourceMappingURL=xterm.d.ts.map
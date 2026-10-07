import type { Vm } from "../vms/index.js";
/**
 * Run `script` the way the guest would if it could choose: bash where the
 * image has it, sh where it does not. For a script with no shebang of its own.
 */
export declare function runScriptWithBestShell(path: string): string;
/** How a PTY session ended. */
export interface PtyOutcome {
    /** The guest's exit code. Meaningless when `failed` — nothing ran to produce it. */
    code: number;
    /**
     * Whether the session never got off the ground (or died on the wire) rather
     * than running and exiting. A caller deciding what to do with the VM
     * afterwards needs these apart: a command that exited 1 ran, and left the VM
     * in some state worth reasoning about; a session that failed to open did
     * not, and there is nothing there.
     */
    failed: boolean;
}
/**
 * Hand the terminal to a shell in the VM: raw stdin in, guest bytes out,
 * window resizes forwarded, everything restored on exit.
 *
 * Returns the shell's exit code rather than setting it, so a caller with
 * work left to do after the session (taking a snapshot, say) decides what
 * the process's own status should be.
 */
export declare function runInteractiveShell(vm: Vm, options: {
    linuxUser?: string;
    exec?: string;
    argv?: unknown;
}): Promise<PtyOutcome>;
/** The interactive shell as a command handler: the exit code becomes the CLI's. */
export declare function interactiveShell(vm: Vm, options: {
    linuxUser?: string;
    exec?: string;
    argv?: unknown;
}): Promise<void>;
/**
 * Run one command in the guest on a PTY and mirror it to this terminal as it
 * goes — the same live output an interactive session shows, without handing
 * over stdin. Ctrl-C therefore reaches *this* process rather than the guest,
 * which is what lets the caller treat it as "cancel the whole operation".
 */
export declare function streamCommand(vm: Vm, options: {
    command: string;
    linuxUser?: string;
    argv?: unknown;
}): Promise<PtyOutcome>;
/**
 * The guest exec API accepts a shell command string, while the CLI accepts an
 * argv-style command after `--`. Quote every argument when translating between
 * the two so spaces, semicolons, substitutions, and embedded quotes remain in
 * the argument where the caller put them.
 */
export declare function shellQuoteArgument(argument: string): string;
/** A dim, indented block of guidance printed to stderr, above a handed-over terminal. */
export declare function printBanner(lines: string[]): void;
//# sourceMappingURL=shell.d.ts.map
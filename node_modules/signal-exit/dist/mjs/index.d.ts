/// <reference types="node" />
import { signals } from './signals.js';
export { signals };
/**
 * A function that takes an exit code and signal as arguments
 */
export type Handler = (code: number | null | undefined, signal: NodeJS.Signals | null) => any;
export declare const 
/**
 * Called when the process is exiting, whether via signal, explicit
 * exit, or running out of stuff to do.
 *
 * If the global process object is not suitable for instrumentation,
 * then this will be a no-op.
 *
 * Returns a function that may be used to unload signal-exit.
 */
onExit: (cb: Handler, opts?: {
    alwaysLast?: boolean | undefined;
} | undefined) => () => void, 
/**
 * Load the listeners.  Likely you never need to call this, unless
 * doing a rather deep integration with signal-exit functionality.
 * Mostly exposed for the benefit of testing.
 *
 * @internal
 */
load: () => void, 
/**
 * Unload the listeners.  Likely you never need to call this, unless
 * doing a rather deep integration with signal-exit functionality.
 * Mostly exposed for the benefit of testing.
 *
 * @internal
 */
unload: () => void;
//# sourceMappingURL=index.d.ts.map
import type { Logger } from '../types';
export declare const format: (...args: unknown[]) => string;
/**
 * Creates basic logger with colors that can be used from the CLI and the
 * server logs.
 */
export declare function createLogger(): Logger;

import type { Env } from './types';
/**
 * Clones zero or more objects into a single new object while ensuring that the
 * `PATH` environment variable is defined when the `PATH` or `Path` environment
 * variables are defined.
 *
 * @param {Object} [...envs] Objects and/or `process.env` to clone and merge
 * @returns {Object} The new object
 */
export declare function cloneEnv(...envs: (Env | undefined)[]): Env;

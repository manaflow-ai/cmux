/**
 * Where credentials came from, read before `.env` is loaded.
 *
 * The CLI loads a `.env` from the working directory, so a stale
 * `FREESTYLE_API_KEY` sitting in one silently outranks `freestyle login` —
 * and the rejection that follows is impossible to explain without knowing
 * which of the two supplied the key. Module bodies run before `index.ts`
 * calls `loadDotenv()`, so what this reads is the real shell environment.
 */
export declare const apiKeyInShellEnvironment: boolean;
/**
 * Whether there is a person at this terminal to hand a shell to.
 *
 * Two independent tests, because each catches what the other misses: an agent
 * or a pipeline usually has no TTY at all, but some harnesses do allocate one
 * (tmux, `script`, a PTY-backed tool runner) and would otherwise look exactly
 * like a person sitting at a prompt.
 */
export declare function hasHumanTerminal(): boolean;
//# sourceMappingURL=env.d.ts.map
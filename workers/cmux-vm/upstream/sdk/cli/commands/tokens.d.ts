import type { CommandModule } from "yargs";
import type { GlobalArgv } from "../context.js";
type Args = GlobalArgv & Record<string, unknown>;
/**
 * Account API keys, as in `FREESTYLE_API_KEY` — not the per-end-user identity
 * access tokens, which live under `freestyle identity token`.
 */
export declare const tokensCommand: CommandModule<Args, Args>;
export {};
//# sourceMappingURL=tokens.d.ts.map
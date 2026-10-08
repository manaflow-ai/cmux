import type { CommandModule } from "yargs";
import type { GlobalArgv } from "../context.js";
type Args = GlobalArgv & Record<string, unknown>;
/**
 * The docs skill, installed. The one command here that talks to the docs
 * site rather than the API: it takes no login, because it is how an agent
 * onboards before it has one.
 */
export declare const skillCommand: CommandModule<Args, Args>;
export {};
//# sourceMappingURL=skill.d.ts.map
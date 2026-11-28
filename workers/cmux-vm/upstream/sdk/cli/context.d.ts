import { Freestyle } from "../index.js";
import type { OutputFormat } from "./output.js";
export interface GlobalArgv {
    apiKey?: string;
    team?: string;
    proxy?: string;
    output?: OutputFormat;
}
/**
 * Build a client from the global flags every command inherits. Key
 * resolution: `--api-key`/`FREESTYLE_API_KEY` first, otherwise Stack Auth.
 * Stack logins refresh a short-lived access token. The v2 gateway resolves
 * the selected Freestyle team during HTTP and WebSocket handshakes.
 */
export declare function client(argv: GlobalArgv): Promise<Freestyle>;
//# sourceMappingURL=context.d.ts.map
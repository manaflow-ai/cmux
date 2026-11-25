import type { Freestyle } from "../index.js";
import { type LocalForward } from "./port-forward.js";
interface SshOptions {
    linuxUser?: string;
    exec?: string;
    login?: {
        accessToken: string;
        teamId: string;
    };
    forwards?: LocalForward[];
}
/** Use CLI login directly, or a temporary VM-scoped identity for API-key callers. */
export declare function gatewaySsh(freestyle: Freestyle, selector: string, options: SshOptions): Promise<void>;
export {};
//# sourceMappingURL=ssh.d.ts.map
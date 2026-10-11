import type { Freestyle } from "../index.js";
/** Open a native SSH session using a temporary, VM-scoped identity. */
export declare function gatewaySsh(freestyle: Freestyle, selector: string, options: {
    linuxUser?: string;
    exec?: string;
}): Promise<void>;
//# sourceMappingURL=ssh.d.ts.map
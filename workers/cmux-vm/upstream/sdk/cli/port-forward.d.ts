export interface LocalForward {
    address: string;
    localPort: number;
    remotePort: number;
}
/** The numeric subset of kubectl's [LOCAL_PORT:]REMOTE_PORT syntax. */
export declare function parsePortForwards(ports: readonly string[], address?: string): LocalForward[];
export declare function sshForwardSpec(forward: LocalForward): string;
//# sourceMappingURL=port-forward.d.ts.map
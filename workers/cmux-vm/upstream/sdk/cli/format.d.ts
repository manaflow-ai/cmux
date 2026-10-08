import type { CertificateInfo, DomainOwnership, DomainVerification, DomainVerified } from "../domains.js";
import type { FirewallEndpoint, FirewallRuleData, ListFirewallRulesResult } from "../firewall.js";
import type { ListTlsRulesResult, TlsEndpoint, TlsRuleData } from "../tls.js";
import type { AccessTokenInfo, CreatedToken, IdentityData, IdentityInfo, ListIdentitiesResult, VmPermission } from "../identities.js";
import type { DirEntry, FileStat, ListVmsResult, VmData } from "../vms/index.js";
import type { ListSnapshotsResult, SnapshotCreated, SnapshotData } from "../vms/snapshots.js";
import type { CreatedTunnel, ListTunnelsResult, TunnelData } from "../tunnel.js";
import type { ListVpcsResult, VpcData } from "../vpc.js";
/**
 * Render a VM. `timestamps` controls whether Created/Updated are shown at
 * all — pass false for action confirmations (start/stop/update/…) where
 * "created just now" or "updated 0s ago" tells you nothing you don't already
 * know. When shown, Updated is dropped if it's identical to Created.
 */
export declare function renderVm(vm: VmData, options?: {
    timestamps?: boolean;
}): string;
/** VM output for start/pause/resize/update. No Created/Updated noise. */
export declare function renderVmAction(vm: VmData): string;
/**
 * What to do with a VM the CLI is leaving running: reconnect, or get rid of
 * it. Printed after a session ends, where the id has scrolled far out of
 * reach and retyping it is the only way back.
 */
export declare function renderVmNextSteps(vmId: string, headline: string): string;
export declare function renderVmList(result: ListVmsResult): string;
export declare function renderSnapshot(snapshot: SnapshotData, options?: {
    timestamps?: boolean;
}): string;
export declare function renderSnapshotCreated(created: SnapshotCreated): string;
/** Snapshot output for update — no Created/Updated noise. */
export declare function renderSnapshotAction(snapshot: SnapshotData): string;
export declare function renderSnapshotList(result: ListSnapshotsResult): string;
export declare function renderDirEntries(entries: DirEntry[]): string;
export declare function renderFileStat(stat: FileStat): string;
export declare function renderVpc(vpc: VpcData, options?: {
    timestamps?: boolean;
}): string;
/** VPC output for update — no Created noise. */
export declare function renderVpcAction(vpc: VpcData): string;
export declare function renderVpcList(result: ListVpcsResult): string;
export declare function renderTunnel(tunnel: TunnelData | CreatedTunnel): string;
export declare function renderTunnelList(result: ListTunnelsResult): string;
export declare function renderDomainList(domains: DomainOwnership[]): string;
export declare function renderVerification(v: DomainVerification): string;
export declare function renderVerificationList(verifications: DomainVerification[]): string;
export declare function renderVerified(v: DomainVerified): string;
export declare function renderCertificate(c: CertificateInfo): string;
export declare function renderCertificateList(certs: CertificateInfo[]): string;
export declare function renderIdentity(identity: IdentityData | IdentityInfo): string;
export declare function renderIdentityList(result: ListIdentitiesResult): string;
export declare function renderCreatedToken(token: CreatedToken): string;
export declare function renderTokenList(tokens: AccessTokenInfo[]): string;
export declare function renderPermission(p: VmPermission): string;
export declare function renderPermissionList(permissions: VmPermission[]): string;
/**
 * A matcher as one readable phrase, e.g. `public:443/tcp` or
 * `vm-123 (port 22/tcp)`. Deliberately not a JSON dump: the whole point of the
 * API is that a rule reads as intent, and the CLI should too.
 */
export declare function renderFirewallEndpoint(endpoint: FirewallEndpoint): string;
export declare function renderFirewallRule(rule: FirewallRuleData): string;
export declare function renderFirewallRuleList(result: ListFirewallRulesResult): string;
/**
 * A TLS matcher as one readable phrase, e.g. `public Internet`,
 * `vm-123 port 8000`, or `api.vendor.com port 443`. As with the firewall,
 * a rule reads as intent, not as a JSON dump.
 */
export declare function renderTlsEndpoint(endpoint: TlsEndpoint): string;
export declare function renderTlsRule(rule: TlsRuleData): string;
export declare function renderTlsRuleList(result: ListTlsRulesResult): string;
//# sourceMappingURL=format.d.ts.map
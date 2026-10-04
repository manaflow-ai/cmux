// Request-body parsing for POST /api/vm/firewall endpoints (source and destination).
import { canonicalCidr } from "./cidr";
import { vmErrorResponse } from "./routeHelpers";

export type FirewallEndpoint = { vmId?: string; vpcId?: string; tunnelId?: string; cidr?: string; public?: true; port?: number; protocol?: "tcp" | "udp" | "icmp" };
const endpointKeys = new Set(["vmId", "vpcId", "tunnelId", "cidr", "public", "port", "protocol"]);

export function parseFirewallEndpoint(raw: unknown, field: string): FirewallEndpoint | Response {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field} must be an endpoint object.`, action: "Pass vmId, vpcId, tunnelId, cidr, or public on each endpoint." });
  const value = raw as Record<string, unknown>;
  if (Object.keys(value).some((key) => !endpointKeys.has(key))) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field} contains an unsupported field.`, action: "Use only the documented firewall endpoint fields." });
  const identity = endpointIdentity(value, field);
  if (identity instanceof Response) return identity;
  const traffic = endpointTraffic(value, field);
  if (traffic instanceof Response) return traffic;
  return { ...identity, ...traffic };
}

function endpointIdentity(value: Record<string, unknown>, field: string): Omit<FirewallEndpoint, "port" | "protocol"> | Response {
  const result: FirewallEndpoint = {};
  for (const key of ["vmId", "vpcId", "tunnelId", "cidr"] as const) if (value[key] !== undefined) {
    if (typeof value[key] !== "string" || !value[key].trim()) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field}.${key} must be a non-empty string.`, action: "Pass a valid resource id or CIDR." });
    if (key === "cidr" && !validCidr(String(value[key]))) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field}.cidr must be a CIDR range.`, action: "Pass an IPv4 or IPv6 address with a prefix length." });
    // The provider expects the canonical range (network address, lowercase IPv6).
    result[key] = key === "cidr" ? canonicalCidr(value[key]) : value[key].trim();
  }
  if (value.public !== undefined && value.public !== true) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field}.public must be true when present.`, action: "Set public:true for public traffic." });
  if (value.public === true) result.public = true;
  const identity = [result.vmId, result.vpcId, result.tunnelId, result.cidr, result.public].filter(Boolean);
  if (identity.length === 0) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field} must identify a resource or address.`, action: "Pass an identity, CIDR, or public:true." });
  if (result.public && [result.vmId, result.vpcId, result.tunnelId, result.cidr].some(Boolean)) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field}.public cannot be combined with another identity.`, action: "Use public:true by itself or identify a private resource/address." });
  if ([result.vmId, result.vpcId, result.tunnelId].filter(Boolean).length > 1) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field} may name only one resource identity.`, action: "Choose vmId, vpcId, or tunnelId." });
  return result;
}

function endpointTraffic(value: Record<string, unknown>, field: string): Pick<FirewallEndpoint, "port" | "protocol"> | Response {
  const result: Pick<FirewallEndpoint, "port" | "protocol"> = {};
  if (value.port !== undefined && (typeof value.port !== "number" || !Number.isInteger(value.port) || value.port < 1 || value.port > 65535)) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field}.port must be between 1 and 65535.`, action: "Pass an integer port." });
  if (value.port !== undefined) result.port = value.port as number;
  if (value.protocol !== undefined && !["tcp", "udp", "icmp"].includes(String(value.protocol))) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field}.protocol is invalid.`, action: "Use tcp, udp, or icmp." });
  if (value.protocol !== undefined) result.protocol = value.protocol as FirewallEndpoint["protocol"];
  if (result.protocol === "icmp" && result.port !== undefined) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field}.port cannot be used with icmp.`, action: "Omit port for icmp traffic." });
  if (result.port !== undefined && !result.protocol) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field}.protocol is required with port.`, action: "Pass tcp, udp, or icmp with the port." });
  return result;
}

/** An address with an explicit prefix that fits its family (IPv4 /0-32, IPv6 /0-128). */
function validCidr(value: string): boolean {
  if (!value.includes("/")) return false;
  try {
    canonicalCidr(value);
    return true;
  } catch {
    return false;
  }
}

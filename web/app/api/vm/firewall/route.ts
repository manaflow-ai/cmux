import { defaultProviderId } from "../../../../services/vms/drivers";
import { jsonResponse, resolveVmRouteAccountScope, vmErrorResponse, withAuthedVmApiRoute } from "../../../../services/vms/routeHelpers";
import { runVmRoute } from "../../../../services/vms/routeWorkflow";
import { createVmFirewallRule, deleteVmFirewallRule, getVmFirewallRule, listVmFirewallRules } from "../../../../services/vms/workflows";
import { parseLenientObjectBody, optionalString } from "../../../../services/vms/routeInput";

type Endpoint = { vmId?: string; vpcId?: string; tunnelId?: string; cidr?: string; public?: true; port?: number; protocol?: "tcp" | "udp" | "icmp" };
const endpointKeys = new Set(["vmId", "vpcId", "tunnelId", "cidr", "public", "port", "protocol"]);

function endpoint(raw: unknown, field: string): Endpoint | Response {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field} must be an endpoint object.`, action: "Pass vmId, vpcId, tunnelId, cidr, or public on each endpoint." });
  const value = raw as Record<string, unknown>;
  if (Object.keys(value).some((key) => !endpointKeys.has(key))) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field} contains an unsupported field.`, action: "Use only the documented firewall endpoint fields." });
  const identity = endpointIdentity(value, field);
  if (identity instanceof Response) return identity;
  const traffic = endpointTraffic(value, field);
  if (traffic instanceof Response) return traffic;
  return { ...identity, ...traffic };
}

function endpointIdentity(value: Record<string, unknown>, field: string): Omit<Endpoint, "port" | "protocol"> | Response {
  const result: Endpoint = {};
  for (const key of ["vmId", "vpcId", "tunnelId", "cidr"] as const) if (value[key] !== undefined) {
    if (typeof value[key] !== "string" || !value[key].trim()) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field}.${key} must be a non-empty string.`, action: "Pass a valid resource id or CIDR." });
    if (key === "cidr" && !validCidr(String(value[key]))) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field}.cidr must be a CIDR range.`, action: "Pass an IPv4 or IPv6 address with a prefix length." });
    result[key] = value[key].trim();
  }
  if (value.public !== undefined && value.public !== true) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field}.public must be true when present.`, action: "Set public:true for public traffic." });
  if (value.public === true) result.public = true;
  const identity = [result.vmId, result.vpcId, result.tunnelId, result.cidr, result.public].filter(Boolean);
  if (identity.length === 0) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field} must identify a resource or address.`, action: "Pass an identity, CIDR, or public:true." });
  if (result.public && [result.vmId, result.vpcId, result.tunnelId].some(Boolean)) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field}.public cannot be combined with a resource identity.`, action: "Use public:true by itself or identify a private resource." });
  if ([result.vmId, result.vpcId, result.tunnelId].filter(Boolean).length > 1) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field} may name only one resource identity.`, action: "Choose vmId, vpcId, or tunnelId." });
  return result;
}

function endpointTraffic(value: Record<string, unknown>, field: string): Pick<Endpoint, "port" | "protocol"> | Response {
  const result: Pick<Endpoint, "port" | "protocol"> = {};
  if (value.port !== undefined && (typeof value.port !== "number" || !Number.isInteger(value.port) || value.port < 1 || value.port > 65535)) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field}.port must be between 1 and 65535.`, action: "Pass an integer port." });
  if (value.port !== undefined) result.port = value.port as number;
  if (value.protocol !== undefined && !["tcp", "udp", "icmp"].includes(String(value.protocol))) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field}.protocol is invalid.`, action: "Use tcp, udp, or icmp." });
  if (value.protocol !== undefined) result.protocol = value.protocol as Endpoint["protocol"];
  if (result.protocol === "icmp" && result.port !== undefined) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field}.port cannot be used with icmp.`, action: "Omit port for icmp traffic." });
  if (result.port !== undefined && !result.protocol) return vmErrorResponse({ error: "vm_invalid_firewall_endpoint", status: 400, message: `${field}.protocol is required with port.`, action: "Pass tcp, udp, or icmp with the port." });
  return result;
}

function validCidr(value: string): boolean {
  const slash = value.lastIndexOf("/");
  if (slash <= 0 || slash === value.length - 1) return false;
  const prefix = Number(value.slice(slash + 1));
  const address = value.slice(0, slash);
  const ipv4 = address.split(".");
  if (ipv4.length === 4 && ipv4.every((part) => /^\d{1,3}$/.test(part) && Number(part) <= 255)) return Number.isInteger(prefix) && prefix >= 0 && prefix <= 32;
  return address.includes(":") && Number.isInteger(prefix) && prefix >= 0 && prefix <= 128;
}

export async function GET(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(request, "/api/vm/firewall", { "cmux.vm.operation": "firewall_list" }, "/api/vm/firewall GET failed", async ({ user }) => {
    const url = new URL(request.url);
    const ruleId = optionalString(url.searchParams.get("ruleId"));
    const result = ruleId
      ? await runVmRoute(getVmFirewallRule({ userId: user.id, provider: defaultProviderId(), ruleId }), { request })
      : await runVmRoute(listVmFirewallRules({ userId: user.id, provider: defaultProviderId(), vpcId: optionalString(url.searchParams.get("vpcId")), vmId: optionalString(url.searchParams.get("vmId")), tunnelId: optionalString(url.searchParams.get("tunnelId")) }), { request });
    if (!result.ok) return result.response;
    return jsonResponse(ruleId ? result.value : { rules: result.value });
  });
}

export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(request, "/api/vm/firewall", { "cmux.vm.operation": "firewall_create" }, "/api/vm/firewall POST failed", async ({ user }) => {
    const body = await parseLenientObjectBody(request);
    const source = endpoint(body.source, "source"); if (source instanceof Response) return source;
    const destination = endpoint(body.destination, "destination"); if (destination instanceof Response) return destination;
    const description = body.description === undefined ? undefined : optionalString(body.description);
    if (body.description !== undefined && description === undefined) return vmErrorResponse({ error: "vm_invalid_firewall_description", status: 400, message: "description must be a string.", action: "Pass a short rule description." });
    if (description && description.length > 1024) return vmErrorResponse({ error: "vm_invalid_firewall_description", status: 400, message: "description must be 1024 characters or fewer.", action: "Pass a shorter rule description." });
    const result = await runVmRoute(createVmFirewallRule({ userId: user.id, provider: defaultProviderId(), source, destination, ...(description ? { description } : {}) }), { request });
    if (!result.ok) return result.response;
    return jsonResponse(result.value, { status: 201 });
  });
}

export async function DELETE(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(request, "/api/vm/firewall", { "cmux.vm.operation": "firewall_delete" }, "/api/vm/firewall DELETE failed", async ({ user }) => {
    const ruleId = optionalString(new URL(request.url).searchParams.get("ruleId"));
    if (!ruleId) return vmErrorResponse({ error: "vm_invalid_firewall_rule", status: 400, message: "ruleId is required.", action: "Pass ?ruleId=... for the rule to delete." });
    const result = await runVmRoute(deleteVmFirewallRule({ userId: user.id, provider: defaultProviderId(), ruleId }), { request });
    if (!result.ok) return result.response;
    return jsonResponse({ deleted: true, ruleId });
  });
}

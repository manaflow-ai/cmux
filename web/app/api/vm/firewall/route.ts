import { parseFirewallEndpoint } from "../../../../services/vms/firewallEndpoint";
import type { AuthedUser } from "../../../../services/vms/auth";
import { defaultProviderId } from "../../../../services/vms/drivers";
import { jsonResponse, resolveVmRouteAccountScope, vmErrorResponse, withAuthedVmApiRoute } from "../../../../services/vms/routeHelpers";
import { runVmRoute } from "../../../../services/vms/routeWorkflow";
import { createVmFirewallRule, deleteVmFirewallRule, getVmFirewallRule, listVmFirewallRules } from "../../../../services/vms/workflows";
import { parseLenientObjectBody, optionalString } from "../../../../services/vms/routeInput";

/**
 * Rules may name VMs, which live in an account scope (new VMs are team-owned), so every firewall
 * call resolves the scope the same way the other VM routes do.
 */
function vmScope(user: AuthedUser, request: Request): { ok: true; billingTeamId: string | null } | { ok: false; response: Response } {
  const account = resolveVmRouteAccountScope(user, request);
  return account.ok ? { ok: true, billingTeamId: account.entitlements.billingTeamId ?? null } : account;
}

export async function GET(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(request, "/api/vm/firewall", { "cmux.vm.operation": "firewall_list" }, "/api/vm/firewall GET failed", async ({ user }) => {
    const url = new URL(request.url);
    const ruleId = optionalString(url.searchParams.get("ruleId"));
    const vmId = optionalString(url.searchParams.get("vmId")) ?? undefined;
    const scope = vmScope(user, request);
    if (!scope.ok) return scope.response;
    const result = ruleId
      ? await runVmRoute(getVmFirewallRule({ userId: user.id, provider: defaultProviderId(), billingTeamId: scope.billingTeamId, ruleId }), { request })
      : await runVmRoute(listVmFirewallRules({ userId: user.id, provider: defaultProviderId(), billingTeamId: scope.billingTeamId, vpcId: optionalString(url.searchParams.get("vpcId")) ?? undefined, vmId, tunnelId: optionalString(url.searchParams.get("tunnelId")) ?? undefined }), { request });
    if (!result.ok) return result.response;
    return jsonResponse(ruleId ? result.value : { rules: result.value });
  });
}

export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(request, "/api/vm/firewall", { "cmux.vm.operation": "firewall_create" }, "/api/vm/firewall POST failed", async ({ user }) => {
    const body = await parseLenientObjectBody(request);
    const source = parseFirewallEndpoint(body.source, "source"); if (source instanceof Response) return source;
    const destination = parseFirewallEndpoint(body.destination, "destination"); if (destination instanceof Response) return destination;
    const description = body.description === undefined ? undefined : optionalString(body.description);
    if (body.description !== undefined && description === undefined) return vmErrorResponse({ error: "vm_invalid_firewall_description", status: 400, message: "description must be a string.", action: "Pass a short rule description." });
    if (description && description.length > 1024) return vmErrorResponse({ error: "vm_invalid_firewall_description", status: 400, message: "description must be 1024 characters or fewer.", action: "Pass a shorter rule description." });
    const scope = vmScope(user, request);
    if (!scope.ok) return scope.response;
    const result = await runVmRoute(createVmFirewallRule({ userId: user.id, provider: defaultProviderId(), billingTeamId: scope.billingTeamId, source, destination, ...(description ? { description } : {}) }), { request });
    if (!result.ok) return result.response;
    return jsonResponse(result.value, 201);
  });
}

export async function DELETE(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(request, "/api/vm/firewall", { "cmux.vm.operation": "firewall_delete" }, "/api/vm/firewall DELETE failed", async ({ user }) => {
    const ruleId = optionalString(new URL(request.url).searchParams.get("ruleId"));
    if (!ruleId) return vmErrorResponse({ error: "vm_invalid_firewall_rule", status: 400, message: "ruleId is required.", action: "Pass ?ruleId=... for the rule to delete." });
    const scope = vmScope(user, request);
    if (!scope.ok) return scope.response;
    const result = await runVmRoute(deleteVmFirewallRule({ userId: user.id, provider: defaultProviderId(), billingTeamId: scope.billingTeamId, ruleId }), { request });
    if (!result.ok) return result.response;
    return jsonResponse({ deleted: true, ruleId });
  });
}

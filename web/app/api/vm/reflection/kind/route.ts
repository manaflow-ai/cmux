import { coderouterControlRoute } from "@/services/coderouter/requestTelemetry";
import { resolveVmGuestKind } from "@/services/vms/vmKind";
import { requireVmPrincipal, vmPrincipalFailureResponse } from "@/services/vms/vmPrincipal";

const JSON_HEADERS = {
  "cache-control": "no-store",
  "content-type": "application/json",
} as const;

/**
 * The machine's kind for /etc/cmux/vm-kind (services/vms/vmKind.ts). The
 * guest's root-run cmux-vm-kind-sync asks every minute and writes `owner` or
 * `team`. A missing billing owner is a retryable row-integrity failure; the
 * sync keeps the existing record when a fetch fails. The record is
 * informational only: acpmux no longer trusts it (#26227).
 */
export const GET = coderouterControlRoute("vm_reflection_kind", "/api/vm/reflection/kind", async (request) => {
  const auth = await requireVmPrincipal(request);
  if (!auth.ok) return vmPrincipalFailureResponse(auth.reason);
  const vm = auth.principal.vm;
  const kind = resolveVmGuestKind(vm);
  if (kind === null) {
    return new Response(
      JSON.stringify({ error: "vm_kind_unavailable", retryable: true }),
      { status: 503, headers: { ...JSON_HEADERS, "retry-after": "30" } },
    );
  }
  return new Response(JSON.stringify({ vm_id: vm.id, kind }), { status: 200, headers: JSON_HEADERS });
});

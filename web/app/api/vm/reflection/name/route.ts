import { coderouterControlRoute } from "@/services/coderouter/requestTelemetry";
import { requireVmPrincipal, vmPrincipalFailureResponse } from "@/services/vms/vmPrincipal";
import { vmPromptName } from "@/services/vms/promptName";

const JSON_HEADERS = {
  "cache-control": "no-store",
  "content-type": "application/json",
} as const;

/**
 * Boot-only identity endpoint. Prompt initialization needs the machine's
 * prompt name, not the full owner/peer reflection graph. Keeping this
 * response small lets a fresh clone refresh `/etc/cmux/vm-name` without
 * loading sibling machines. The guest re-fetches it every 30 s, so it must
 * answer the same name create and rename write (vmPromptName).
 */
export const GET = coderouterControlRoute("vm_reflection_name", "/api/vm/reflection/name", async (request) => {
  const auth = await requireVmPrincipal(request);
  if (!auth.ok) return vmPrincipalFailureResponse(auth.reason);
  const vm = auth.principal.vm;
  return new Response(JSON.stringify({
    name: vmPromptName(vm),
    vm_id: vm.id,
    revision: vm.createdAt.getTime(),
  }), { status: 200, headers: JSON_HEADERS });
});

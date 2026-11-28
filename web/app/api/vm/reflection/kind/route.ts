import { Effect } from "effect";
import { coderouterControlRoute } from "@/services/coderouter/requestTelemetry";
import { listTeamMemberIdsWithTimeout, vmTeamDirectory, type VmTeamMemberLookup } from "@/services/vms/teamDirectory";
import { resolveVmGuestKind } from "@/services/vms/vmKind";
import { requireVmPrincipal, vmPrincipalFailureResponse } from "@/services/vms/vmPrincipal";

const JSON_HEADERS = {
  "cache-control": "no-store",
  "content-type": "application/json",
} as const;

/**
 * Member lists are cached per team for 15 s, so a fleet of machines
 * re-asking every minute costs at most four Stack reads per team and
 * instance a minute, and a new member turns a machine `team` within about
 * 75 s (cache plus the guest's poll).
 * Only successful reads are kept; a failure is asked again next time.
 */
const MEMBER_CACHE_TTL_MS = 15_000;
const MEMBER_CACHE_MAX = 1_000;
const memberCache = new Map<string, { readonly at: number; readonly lookup: VmTeamMemberLookup }>();

async function listMembers(teamId: string): Promise<VmTeamMemberLookup> {
  const now = Date.now();
  const cached = memberCache.get(teamId);
  if (cached && now - cached.at < MEMBER_CACHE_TTL_MS) return cached.lookup;
  const lookup = await Effect.runPromise(listTeamMemberIdsWithTimeout(vmTeamDirectory(), teamId));
  if (!("error" in lookup)) {
    if (memberCache.size >= MEMBER_CACHE_MAX) memberCache.clear();
    memberCache.set(teamId, { at: now, lookup });
  }
  return lookup;
}

/**
 * The machine's kind for /etc/cmux/vm-kind (services/vms/vmKind.ts). The
 * guest's root-run cmux-vm-kind-sync asks every minute and writes `owner` or
 * `team`; a 503 leaves the guest's record as it was.
 */
export const GET = coderouterControlRoute("vm_reflection_kind", "/api/vm/reflection/kind", async (request) => {
  const auth = await requireVmPrincipal(request);
  if (!auth.ok) return vmPrincipalFailureResponse(auth.reason);
  const vm = auth.principal.vm;
  const kind = await resolveVmGuestKind(vm, { listMembers });
  if (kind === null) {
    return new Response(
      JSON.stringify({ error: "vm_kind_unavailable", retryable: true }),
      { status: 503, headers: { ...JSON_HEADERS, "retry-after": "30" } },
    );
  }
  return new Response(JSON.stringify({ vm_id: vm.id, kind }), { status: 200, headers: JSON_HEADERS });
});

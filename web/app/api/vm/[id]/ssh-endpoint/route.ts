import {
  jsonResponse,
  notFoundVm,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { isVmNotFoundError } from "../../../../../services/vms/errors";
import { openSshEndpoint, runVmWorkflow } from "../../../../../services/vms/workflows";

export const dynamic = "force-dynamic";

/**
 * Returns the SSH endpoint the mac client will dial to reach this VM's cmuxd-remote.
 *
 * Freestyle response shape: `{ host: "vm-ssh.freestyle.sh", port: 22,
 * username: "<vmId>+cmux", credential: { kind: "password", value: "<one-time token>" } }`.
 * Mac client hands this to the existing `cmux ssh` transport; no Next.js in the data plane.
 *
 * E2B returns 501-ish (provider throws) because E2B sandboxes don't expose raw TCP.
 *
 * Short-lived: each call mints a fresh identity + token. The Postgres-backed VM workflow revokes
 * the identity alongside the VM on destroy, so idle sessions don't accumulate zombie credentials.
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/ssh-endpoint",
    { "cmux.vm.operation": "open_ssh" },
    "/api/vm/[id]/ssh-endpoint failed",
    async ({ user, span }) => {
      const { id } = await params;
      setSpanAttributes(span, { "cmux.vm.id": id });
      try {
        const endpoint = await runVmWorkflow(openSshEndpoint({ userId: user.id, providerVmId: id }));
        setSpanAttributes(span, { "cmux.ssh.credential_kind": endpoint.credential.kind });
        return jsonResponse(endpoint);
      } catch (err) {
        if (isVmNotFoundError(err)) return notFoundVm(id);
        throw err;
      }
    },
  );
}

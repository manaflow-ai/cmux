import {
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";

// `cmux vm ssh-info <id>` and `cmux vm ssh --ssh` ask this route for raw SSH
// credentials. Managed Cloud VMs do not mint them (see services/vms/README.md,
// "Provider matrix"): sessions run over the cmux-remote daemon. The route
// exists so those clients get a typed, non-retryable answer they already
// understand (501 vm_attach_transport_unsupported, which `vm ssh` falls back
// from) instead of the framework's HTML 404, which reads as a missing machine.
export const maxDuration = 10;

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/ssh-endpoint",
    { "cmux.vm.operation": "ssh_endpoint" },
    "/api/vm/[id]/ssh-endpoint POST failed",
    async ({ span }) => {
      const { id } = await params;
      setSpanAttributes(span, { "cmux.vm.id": id });
      return vmErrorResponse({
        error: "vm_attach_transport_unsupported",
        status: 501,
        message: "Cloud VMs do not hand out SSH credentials. Sessions run over the cmux remote connection.",
        action: `Open the machine with \`cmux vm ssh ${id}\` or \`cmux vm attach ${id}\`; copy files with \`cmux vm push\`.`,
        phase: "attach",
        retryable: false,
        details: { requestedTransport: "ssh", supportedTransports: ["cmux-remote"] },
      });
    },
  );
}

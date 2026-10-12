/**
 * POST /v1/vms/{vmId}/exec: runs a command in the tenant's VM. The response
 * body streams from the provider through a filter that keeps only exitCode,
 * stdout and stderr (upstream/exec-stream.ts); nothing is buffered. The audit
 * row records the action, never the command or its output.
 */
import { HttpApiBuilder, HttpServerResponse } from "@effect/platform";
import { Effect } from "effect";
import { CmuxVmApi } from "../api.ts";
import { conflict, unavailable, vmNotFound } from "../errors.ts";
import { UpstreamClient } from "../upstream/client.ts";
import { audited, auditableVmId, withOwnedVm } from "./common.ts";

export const execHandlers = HttpApiBuilder.group(CmuxVmApi, "exec", (handlers) =>
  handlers.handle("execVm", ({ path, payload }) =>
    audited(
      "vm.exec",
      auditableVmId(path.vmId),
      withOwnedVm(path.vmId, "vm:exec", "exec", (_caller, vm, proofs) =>
        Effect.gen(function* () {
          const upstream = yield* UpstreamClient;
          const body = yield* upstream
            .exec(vm, proofs, {
              command: payload.command,
              ...(payload.env === undefined ? {} : { env: payload.env }),
              ...(payload.stdinBase64 === undefined ? {} : { stdinBase64: payload.stdinBase64 }),
              ...(payload.timeoutMs === undefined ? {} : { timeoutMs: payload.timeoutMs }),
              ...(payload.linuxUser === undefined ? {} : { linuxUser: payload.linuxUser }),
            })
            .pipe(
              Effect.mapError((error) =>
                error.status === 404
                  ? vmNotFound()
                  : error.status === 409
                    ? conflict("The VM is not running, or it stopped answering during the command (which may have run)")
                    : unavailable(),
              ),
            );
          return HttpServerResponse.raw(body, { contentType: "application/json" });
        }),
      ),
    ),
  ),
);

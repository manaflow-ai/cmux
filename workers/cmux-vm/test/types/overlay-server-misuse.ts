import type { Named } from "@gdp-ts/core";
import { Effect } from "effect";
import type { Principal } from "../../src/domain/principal.ts";
import type { DeviceId } from "../../src/lib/ids.ts";
import type { CallerActsOnDevice } from "../../src/proofs/device-owner.ts";
import type { KeyHasScope } from "../../src/proofs/key-has-scope.ts";
import type { CallerActsOnOverlayServer } from "../../src/proofs/overlay-server.ts";
import { UpstreamMesh } from "../../src/upstream/mesh.ts";

/** Never executed: provider-free access cannot become provider ownership. */
export const overlayServerCannotAuthorizeProviderDeletion = <C, D>(
  _caller: Named<C, Principal>, device: Named<D, DeviceId>, access: CallerActsOnOverlayServer<C, D>,
  scope: KeyHasScope<C, "mesh:join">, acts: CallerActsOnDevice<C, D>,
) => Effect.flatMap(UpstreamMesh, (upstream) => {
  // @ts-expect-error A server-access proof carries no provider-resource ownership.
  return upstream.deleteDeviceTunnel(device, { owns: access, scope, acts });
});

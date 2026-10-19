/**
 * Compile-time checks, enforced by `tsc` (this file is in tsconfig's include).
 * Each `@ts-expect-error` line is a call the type checker must refuse; if one
 * starts compiling, `tsc` fails with "Unused '@ts-expect-error' directive".
 * Never executed.
 */
import { name } from "@gdp-ts/core";
import { Effect } from "effect";
import type { Principal } from "../../src/domain/principal.ts";
import type { VmId } from "../../src/lib/ids.ts";
import { keyHasScope, type KeyHasScope } from "../../src/proofs/key-has-scope.ts";
import { tenantOwnsVm } from "../../src/proofs/tenant-owns-resource.ts";
import { UpstreamClient } from "../../src/upstream/client.ts";
import type { AccessTokenAllows, AccessTokenEvidence } from "../../src/proofs/access-token-allows.ts";
import { UpstreamAccessTokens } from "../../src/upstream/access-tokens.ts";
// @ts-expect-error only the verifier module can construct access-token proofs
import { verifierAccessTokenProof } from "../../src/proofs/access-token-allows.ts";
void verifierAccessTokenProof;

export const misuse = (principal: Principal, vmA: VmId, vmB: VmId) =>
  Effect.gen(function* () {
    const upstream = yield* UpstreamClient;

    yield* name(principal, vmA, vmB, (caller, a, b) =>
      Effect.gen(function* () {
        const read = keyHasScope(caller, "vm:read");
        const write = keyHasScope(caller, "vm:write");
        const ownsA = yield* tenantOwnsVm(caller, a);
        if (read === null || write === null || ownsA === null) return;

        // The honest call compiles.
        yield* upstream.getVm(a, { owns: ownsA, scope: read });

        // @ts-expect-error no proofs at all
        yield* upstream.getVm(a);
        // @ts-expect-error a proof about VM A does not authorize VM B
        yield* upstream.getVm(b, { owns: ownsA, scope: read });
        // @ts-expect-error vm:write is not vm:read
        yield* upstream.getVm(a, { owns: ownsA, scope: write });
        // @ts-expect-error a raw id is not a named id
        yield* upstream.getVm(vmA, { owns: ownsA, scope: read });

        // S2: each mutation demands its own scope about the same caller and VM.
        yield* upstream.pauseVm(a, { owns: ownsA, scope: write });
        // @ts-expect-error vm:read cannot pause
        yield* upstream.pauseVm(a, { owns: ownsA, scope: read });
        // @ts-expect-error vm:read cannot delete
        yield* upstream.deleteVm(a, { owns: ownsA, scope: read });
        // @ts-expect-error a proof about VM A does not delete VM B
        yield* upstream.deleteVm(b, { owns: ownsA, scope: write });
        // @ts-expect-error vm:write is not vm:exec
        yield* upstream.exec(a, { owns: ownsA, scope: write }, { command: "true" });
        // @ts-expect-error vm:write is not vm:files
        yield* upstream.listFiles(a, { owns: ownsA, scope: write }, "/");
        // @ts-expect-error a create needs a TenantMayCreate proof
        yield* upstream.createVm(caller, { cmuxId: vmA, idleTimeoutSeconds: 300, environment: "local" }, { scope: write });
      }),
    );

    // Proofs about another caller do not mix: a second name for the same principal is a different caller.
    yield* name(principal, vmA, (first, a) =>
      name(principal, (second) =>
        Effect.gen(function* () {
          const ownsA = yield* tenantOwnsVm(first, a);
          const readSecond = keyHasScope(second, "vm:read");
          if (ownsA === null || readSecond === null) return;
          // @ts-expect-error ownership by one caller and scope of another do not combine
          yield* upstream.getVm(a, { owns: ownsA, scope: readSecond });
        }),
      ),
    );
  });

declare const accessProofA: AccessTokenAllows<"caller-a">;
declare const accessProofB: AccessTokenAllows<"caller-b">;
const acceptsCallerA = (proof: AccessTokenAllows<"caller-a">) => proof;
// @ts-expect-error access-token proof evidence is bound to its caller
acceptsCallerA(accessProofB);
acceptsCallerA(accessProofA);

declare const accessEvidence: AccessTokenEvidence;
// @ts-expect-error scope decisions require the verifier's branded proof, not the envelope
accessEvidence.scopes;
declare const fileProof: KeyHasScope<"file-caller", "vm:files">;
// @ts-expect-error a file proof must carry an explicit Linux user
const missingFileUser: KeyHasScope<"file-caller", "vm:files"> = { ...fileProof, linuxUser: undefined };
void missingFileUser;
// @ts-expect-error the caller-bound proof cannot escape the evidence callback
accessEvidence.withCaller((_caller, proof) => proof);

export const accessTokenMisuse = (evidence: AccessTokenEvidence, vmId: VmId) =>
  Effect.gen(function* () {
    const upstream = yield* UpstreamAccessTokens;
    yield* evidence.withCaller((caller, allows) =>
      name(vmId, (vm) =>
        Effect.gen(function* () {
          const owns = yield* tenantOwnsVm(caller, vm);
          if (owns === null) return;
          yield* upstream.mintSsh(vm, { owns, allows }, undefined, new Date());
          yield* name(caller.value, (otherCaller) =>
            Effect.gen(function* () {
              // @ts-expect-error another caller cannot inherit the access token's Linux user
              keyHasScope(otherCaller, "vm:files", allows);
              const otherOwns = yield* tenantOwnsVm(otherCaller, vm);
              if (otherOwns === null) return;
              // @ts-expect-error ownership from another caller cannot use this access-token proof
              yield* upstream.mintSsh(vm, { owns: otherOwns, allows }, undefined, new Date());
            }),
          );
        }),
      ),
    );
  });

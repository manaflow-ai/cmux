// Lint self-test fixture: every line below must be reported by the gdp-ts
// preset (scripts/lint-selftest.sh). Never imported; not type-checked.
import { defineProof } from "@gdp-ts/core";
import type { KeyHasScope } from "../src/proofs/key-has-scope.ts";

export const Minted = defineProof("KeyHasScope:vm:read");
export const forged = {} as KeyHasScope<string, "vm:read">;
export const cast = (value: unknown) => value as string;
export const loose: any = 1;

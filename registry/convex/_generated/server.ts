// Hand-written stand-in for `convex codegen` output (the CLI needs a
// configured deployment; tests must not). Replaced by real codegen when
// the deployment is configured — the generic factories are the same ones
// codegen emits, minus schema-specific typing.
import {
  internalMutationGeneric,
  internalQueryGeneric,
  mutationGeneric,
  queryGeneric,
} from "convex/server";

export const query = queryGeneric;
export const internalQuery = internalQueryGeneric;
export const mutation = mutationGeneric;
export const internalMutation = internalMutationGeneric;

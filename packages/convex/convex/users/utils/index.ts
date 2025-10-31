import {
  mutation,
  query,
  type ActionCtx,
  type MutationCtx,
  type QueryCtx,
} from "../../_generated/server";
import { ConvexError, v } from "convex/values";
import {
  customCtx,
  customMutation,
  customQuery,
} from "convex-helpers/server/customFunctions";

export const authQuery = customQuery(
  query,
  customCtx(async (ctx) => {
    const identity = await AuthenticationRequired({ ctx });
    return { identity };
  })
);

export const authMutation = customMutation(
  mutation,
  customCtx(async (ctx) => {
    const identity = await AuthenticationRequired({ ctx });
    return { identity };
  })
);

type Identity = NonNullable<
  Awaited<ReturnType<QueryCtx["auth"]["getUserIdentity"]>>
>;

export async function AuthenticationRequired({
  ctx,
}: {
  ctx: QueryCtx | MutationCtx | ActionCtx;
}): Promise<Identity> {
  const identity = await ctx.auth.getUserIdentity();
  if (identity === null) {
    throw new ConvexError("Not authenticated!");
  }
  return identity;
}

// Custom validator for task IDs that accepts both real and fake IDs
export const taskIdWithFake = v.union(
  v.id("tasks"),
  v.string() // Accepts fake IDs like "fake-xxx"
);

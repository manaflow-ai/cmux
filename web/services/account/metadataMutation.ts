import type { cloudDb } from "../../db/client";
import {
  type AccountDeletionUserMutationLease,
  withAccountDeletionUserMutation,
} from "./deletionLock";

export type AccountMetadataUser = {
  readonly id: string;
};

export type AccountMetadataUserLoader<User extends AccountMetadataUser> = {
  getUser(userId: string): Promise<User | null>;
};

export class AccountMetadataUserUnavailableError extends Error {
  constructor(readonly userId: string) {
    super("Account user disappeared during metadata mutation");
    this.name = "AccountMetadataUserUnavailableError";
  }
}

/**
 * Serializes Stack metadata writers with account deletion and reloads the user
 * only after the durable lease is held. Callers therefore never write a whole
 * metadata object copied before a competing billing or TestFlight mutation.
 */
export async function withFreshAccountMetadataUser<
  User extends AccountMetadataUser,
  Result,
>(input: {
  readonly db: ReturnType<typeof cloudDb>;
  readonly userId: string;
  readonly loader: AccountMetadataUserLoader<User>;
  readonly operation: (
    user: User,
    lease: AccountDeletionUserMutationLease,
  ) => Promise<Result>;
}): Promise<Result> {
  return await withAccountDeletionUserMutation(
    input.db,
    input.userId,
    async (lease) => {
      const user = await input.loader.getUser(input.userId);
      if (!user || user.id !== input.userId) {
        throw new AccountMetadataUserUnavailableError(input.userId);
      }
      return await input.operation(user, lease);
    },
  );
}

import {
  accountDeletionTombstones,
  accountMutationLeases,
} from "../../db/schema";

type SelectSource = {
  from(table: unknown): unknown;
};

/** Adds the durable account-mutation transaction surface to a focused DB mock. */
export function withAccountMutationLeaseSupport<
  Base extends { select: (...args: never[]) => SelectSource },
>(base: Base) {
  let operationId: string | null = null;
  const transactionClient = {
    ...base,
    select: (...args: unknown[]) => {
      const baseSelect = base.select(...args as never[]);
      return {
        from: (table: unknown) => {
          if (table === accountDeletionTombstones) {
            return { where: () => ({ limit: async () => [] }) };
          }
          if (table === accountMutationLeases) {
            return {
              where: () => ({
                limit: async () => operationId ? [{ operationId }] : [],
              }),
            };
          }
          return baseSelect.from(table);
        },
      };
    },
    execute: async () => undefined,
    delete: (table: unknown) => ({
      where: async () => {
        if (table === accountMutationLeases) operationId = null;
      },
    }),
    insert: (table: unknown) => ({
      values: async (values: unknown) => {
        if (table === accountMutationLeases) {
          operationId = (values as { readonly operationId: string }).operationId;
        }
      },
    }),
    update: () => ({
      set: () => ({ where: async () => undefined }),
    }),
  };
  return {
    ...transactionClient,
    transaction: async <Result>(
      operation: (tx: typeof transactionClient) => Promise<Result>,
    ) => await operation(transactionClient),
  };
}

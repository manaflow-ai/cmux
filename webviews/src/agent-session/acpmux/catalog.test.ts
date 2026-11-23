import { expect, test } from "bun:test";
import { followHarnessChanges } from "./catalog";

test("runtime catalog changes are wired alongside harness invalidation", () => {
  const client: { onHarnessesChanged?: () => void; onCatalogChanged?: () => void } = {};
  const invalidated: unknown[] = [];
  let catalogChanges = 0;
  const queryClient = {
    invalidateQueries: (options: unknown) => {
      invalidated.push(options);
      return Promise.resolve();
    },
  };

  followHarnessChanges(client, queryClient as never, 7, () => {
    catalogChanges += 1;
  });
  client.onCatalogChanged?.();
  client.onHarnessesChanged?.();

  expect(catalogChanges).toBe(1);
  expect(invalidated).toHaveLength(2);
});

import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";

import {
  accountAnalyticsForwardLeases,
  accountDeletionTombstones,
  cloudVmBaseGenerations,
  cloudVmBases,
  cloudVmBillingGrants,
  cloudVmLeases,
  cloudVmSessions,
  cloudVmUsageEvents,
  cloudVms,
  devices,
  stripeCustomers,
  stripeSubscriptions,
  subrouterTenants,
  vaultSessions,
  vaultSnapshots,
  vaultUploadGrants,
  vaultUploadTombstones,
} from "../db/schema";
import type { ProviderId } from "../services/vms/drivers";

process.env.RESEND_API_KEY ??= "test-resend-key";
process.env.CMUX_FEEDBACK_FROM_EMAIL ??= "feedback@example.com";
process.env.CMUX_FEEDBACK_RATE_LIMIT_ID ??= "test-feedback-rate-limit";
process.env.STACK_SECRET_SERVER_KEY ??= "test-stack-secret";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID ??= "00000000-0000-4000-8000-000000000000";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY ??= "test-stack-publishable";

const ACCOUNT_USER_ID = "account-user-1";
const originalPostHogPersonalApiKey = process.env.POSTHOG_PERSONAL_API_KEY;
const originalPostHogApiHost = process.env.POSTHOG_API_HOST;
const originalPostHogEnvironmentId = process.env.POSTHOG_ENVIRONMENT_ID;
const originalPostHogProjectId = process.env.POSTHOG_PROJECT_ID;
const stackModule = await import("../app/lib/stack");
const realGetStackServerApp = stackModule.getStackServerApp;
const realIsStackConfigured = stackModule.isStackConfigured;
const dbClientModule = await import("../db/client");
const realCloudDb = dbClientModule.cloudDb;
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const stripeModule = await import("../services/billing/stripe");
const realIsStripeBillingConfigured = stripeModule.isStripeBillingConfigured;
const realStripe = stripeModule.stripe;
const ascClientModule = await import("../services/asc/client");
const realIsAscConfigured = ascClientModule.isAscConfigured;
const ascTestflightModule = await import("../services/asc/testflight");
const realRemoveTester = ascTestflightModule.removeTester;
const errorsModule = await import("../services/errors");
const realCaptureAscError = errorsModule.captureAscError;
const storageModule = await import("../services/vault/storage");
const realDeleteObject = storageModule.deleteObject;
const vaultUsageModule = await import("../services/vault/usage");
const realWithVaultUserQuotaLock = vaultUsageModule.withVaultUserQuotaLock;
const subrouterClientModule = await import("../services/subrouter/client");
const realCreateSubrouterClientFromEnv = subrouterClientModule.createSubrouterClientFromEnv;
const vmErrorsModule = await import("../services/vms/errors");
const workflowsModule = await import("../services/vms/workflows");
const realDestroyVm = workflowsModule.destroyVm;
const realListUserVms = workflowsModule.listUserVms;
const realRevokeUserIdentityLeasesForAccountDeletion = workflowsModule.revokeUserIdentityLeasesForAccountDeletion;
const realRunVmWorkflow = workflowsModule.runVmWorkflow as (...args: unknown[]) => unknown;
type ListedAccountVm = string | {
  readonly providerVmId?: string | null;
  readonly provider?: ProviderId;
};
type StackPage = readonly unknown[] & { readonly nextCursor?: string | null };
type StackList =
  | StackPage
  | ((options?: { readonly cursor?: string; readonly limit?: number }) => StackPage | Promise<StackPage>);

const deleteStackUser = mock(async () => {
  routeEvents.push("stack-delete");
  if (stackDeleteError) throw stackDeleteError;
});
const updateStackUser = mock(async () => {
  routeEvents.push("metadata-update");
});
const getUser = mock(async () => stackUser(stackUserIds.shift()));
const transaction = mock(async (...args: unknown[]) => {
  const [callback] = args as [(tx: MockTransaction) => Promise<void>];
  routeEvents.push("transaction");
  return await callback(mockTransaction);
});
const transactionSelect = mock(() => {
  let selectedTable: unknown = null;
  const rows = () => {
    if (selectedTable === accountDeletionTombstones) return nextTransactionTombstoneSelectResult();
    if (selectedTable === accountAnalyticsForwardLeases) return nextTransactionAnalyticsLeaseSelectResult();
    if (
      selectedTable === vaultSnapshots ||
      selectedTable === vaultUploadGrants ||
      selectedTable === vaultUploadTombstones ||
      selectedTable === vaultSessions
    ) {
      return nextSelectResult();
    }
    return nextTransactionSelectResult();
  };
  const builder = {
    from: (table: unknown) => {
      selectedTable = table;
      return builder;
    },
    innerJoin: () => builder,
    where: () => builder,
    orderBy: () => builder,
    limit: () => builder,
    offset: () => builder,
    for: async () => rows(),
    then: (
      resolve: (value: unknown[]) => unknown,
      reject: (reason: unknown) => unknown,
    ) => Promise.resolve(rows()).then(resolve, reject),
  };
  return builder;
});
const transactionExecute = mock(async () => {
  routeEvents.push("transaction-lock");
});
const transactionDeleteRows = mock((table: unknown) => {
  if (table === accountAnalyticsForwardLeases) {
    return {
      where: async () => {
        routeEvents.push("analytics-lease-cleanup");
      },
    };
  }
  return deleteRows(table);
});
const deleteRows = mock((table: unknown) => {
  deletedTables.push(table);
  deletedTableCount += 1;
  return {
    where: async (condition: unknown) => {
      deletedWhere.push({ table, condition });
    },
  };
});
const updateRows = mock((table: unknown) => ({
  set: (values: unknown) => {
    if (table === accountDeletionTombstones) {
      tombstoneUpdates.push(values);
    } else {
      updatedRows.push({ table, values });
    }
    return {
      where: async () => {
        if (
          table === accountDeletionTombstones &&
          (values as { readonly status?: unknown }).status === "completed" &&
          tombstoneCompleteError
        ) {
          throw tombstoneCompleteError;
        }
        if (
          table === accountDeletionTombstones &&
          (values as { readonly status?: unknown }).status === "cleanup_incomplete" &&
          tombstoneCleanupIncompleteError
        ) {
          throw tombstoneCleanupIncompleteError;
        }
      },
    };
  },
}));
const insertRows = mock((table: unknown) => ({
  values: (values: unknown) => ({
    onConflictDoUpdate: async () => {
      routeEvents.push("tombstone-upsert");
    },
  }),
}));
const listUserVms = mock((...args: unknown[]) => {
  const [userId, billingTeamId] = args as [string, string | null | undefined];
  return { kind: "listUserVms" as const, userId, billingTeamId };
});
const revokeUserIdentityLeasesForAccountDeletion = mock((...args: unknown[]) => {
  const [userId, input] = args as [
    string,
    { readonly afterBatch?: () => unknown } | undefined,
  ];
  lastRevokeIdentityCall = { userId, afterBatch: input?.afterBatch };
  return {
    kind: "revokeUserIdentityLeasesForAccountDeletion" as const,
    userId,
    afterBatch: input?.afterBatch,
  };
});
const destroyVm = mock((...args: unknown[]) => {
  const [input] = args as [{
    readonly userId: string;
    readonly providerVmId: string;
    readonly afterProviderDestroy?: () => void;
  }];
  return {
    kind: "destroyVm" as const,
    input,
  };
});
const runVmWorkflow = mock(async (...args: unknown[]) => {
  const [program] = args as [WorkflowProgram];
  if (program.kind === "listUserVms") {
    routeEvents.push("list-vms");
    const providerVmIds = program.billingTeamId
      ? listedPersonalVmIdsByBillingTeam[program.billingTeamId] ?? []
      : listedPersonalVmIds;
    return providerVmIds.map((vm) =>
      typeof vm === "string"
        ? { providerVmId: vm, provider: "freestyle" as ProviderId }
        : { provider: "freestyle" as ProviderId, ...vm }
    );
  }
  if (program.kind === "revokeUserIdentityLeasesForAccountDeletion") {
    routeEvents.push("revoke-identities");
    if (revokeIdentityLeasesError) throw revokeIdentityLeasesError;
    return revokedIdentityLeaseCount;
  }
  routeEvents.push("destroy-vm");
  const destroyVmFailure = destroyVmFailureErrorsByProviderId.get(program.input.providerVmId);
  if (destroyVmFailure) throw destroyVmFailure;
  if (destroyVmFailureProviderIds.has(program.input.providerVmId)) {
    throw vmProviderOperationError("destroy", `destroy failed for ${program.input.providerVmId}`);
  }
  program.input.afterProviderDestroy?.();
  const afterProviderError = destroyVmAfterProviderErrorsByProviderId.get(program.input.providerVmId);
  if (afterProviderError) throw afterProviderError;
  return undefined;
});
const deleteObject = mock(async (...args: unknown[]) => {
  const [objectKey] = args as [string];
  routeEvents.push("vault-delete");
  deletedVaultObjects.push(objectKey);
  if (vaultDeleteError) throw vaultDeleteError;
  if (postStackVaultDeleteError && routeEvents.includes("stack-delete")) {
    throw postStackVaultDeleteError;
  }
});
const cancelSubscription = mock(async (...args: unknown[]) => {
  const [subscriptionId] = args as [string];
  routeEvents.push("stripe-cancel");
  cancelledStripeSubscriptions.push(subscriptionId);
  if (stripeCancelError) throw stripeCancelError;
});
const deleteCustomer = mock(async (...args: unknown[]) => {
  const [customerId] = args as [string];
  routeEvents.push("stripe-delete-customer");
  deletedStripeCustomers.push(customerId);
  if (stripeDeleteCustomerError) throw stripeDeleteCustomerError;
});
const updateCustomer = mock(async (...args: unknown[]) => {
  const [customerId, params] = args as [string, Record<string, unknown>];
  routeEvents.push("stripe-update-customer");
  updatedStripeCustomers.push({ id: customerId, params });
  if (stripeUpdateCustomerError) throw stripeUpdateCustomerError;
});
const updateSubscription = mock(async (...args: unknown[]) => {
  const [subscriptionId, params] = args as [string, Record<string, unknown>];
  routeEvents.push("stripe-update-subscription");
  updatedStripeSubscriptions.push({ id: subscriptionId, params });
  if (stripeUpdateSubscriptionError) throw stripeUpdateSubscriptionError;
});
const removeTester = mock(async (...args: unknown[]) => {
  const [email] = args as [string];
  routeEvents.push(`testflight-remove:${email}`);
  if (removeTesterError) throw removeTesterError;
});
const captureAscError = mock((..._args: unknown[]) => {
  routeEvents.push("testflight-error");
});
const revokeTenant = mock(async (...args: unknown[]) => {
  const [tenantId] = args as [string];
  routeEvents.push(`subrouter-revoke:${tenantId}`);
  const sequenceError = subrouterRevokeErrors.shift();
  if (sequenceError) throw sequenceError;
  if (subrouterRevokeError) throw subrouterRevokeError;
});
const realFetch = globalThis.fetch;
const postHogDeleteFetch = mock(async (...args: unknown[]) => {
  const fetchArgs = args as Parameters<typeof fetch>;
  routeEvents.push("posthog-delete");
  postHogDeleteRequests.push(fetchArgs);
  if (postHogDeleteError) throw postHogDeleteError;
  return new Response(JSON.stringify(postHogDeleteResponse), { status: postHogDeleteStatus });
});

let deletedTableCount = 0;
let deletedTables: unknown[] = [];
let deletedWhere: Array<{ readonly table: unknown; readonly condition: unknown }> = [];
let selectedWhere: Array<{ readonly table: unknown; readonly condition: unknown }> = [];
let updatedRows: Array<{ readonly table: unknown; readonly values: unknown }> = [];
let tombstoneUpdates: unknown[] = [];
let tombstoneCompleteError: unknown = null;
let tombstoneCleanupIncompleteError: unknown = null;
let routeEvents: string[] = [];
let stackDeleteError: unknown = null;
let stackUserIds: Array<string | undefined> = [];
let selectResults: unknown[][] = [];
let transactionSelectResults: unknown[][] = [];
let transactionTombstoneSelectResults: unknown[][] = [];
let transactionAnalyticsLeaseSelectResults: unknown[][] = [];
let deletedVaultObjects: string[] = [];
let vaultDeleteError: unknown = null;
let postStackVaultDeleteError: unknown = null;
let stripeConfigured = true;
let ascConfigured = false;
let cancelledStripeSubscriptions: string[] = [];
let deletedStripeCustomers: string[] = [];
let updatedStripeCustomers: Array<{ readonly id: string; readonly params: Record<string, unknown> }> = [];
let updatedStripeSubscriptions: Array<{ readonly id: string; readonly params: Record<string, unknown> }> = [];
let stripeCancelError: unknown = null;
let stripeDeleteCustomerError: unknown = null;
let stripeUpdateCustomerError: unknown = null;
let stripeUpdateSubscriptionError: unknown = null;
let removeTesterError: unknown = null;
let destroyVmFailureProviderIds = new Set<string>();
let destroyVmFailureErrorsByProviderId = new Map<string, unknown>();
let destroyVmAfterProviderErrorsByProviderId = new Map<string, unknown>();
let listedPersonalVmIds: ListedAccountVm[] = [];
let listedPersonalVmIdsByBillingTeam: Record<string, ListedAccountVm[]> = {};
let revokeIdentityLeasesError: unknown = null;
let revokedIdentityLeaseCount = 2;
let subrouterClientCreateError: unknown = null;
let subrouterRevokeError: unknown = null;
let subrouterRevokeErrors: unknown[] = [];
let stackUserSelectedTeam: unknown = null;
let stackUserTeams: StackList = [];
let useAccountRouteStubs = false;
let lastRevokeIdentityCall: { readonly userId: string; readonly afterBatch?: unknown } | null = null;
let vaultLockUsers: string[] = [];
let postHogDeleteRequests: Parameters<typeof fetch>[] = [];
let postHogDeleteError: unknown = null;
let postHogDeleteStatus = 202;
let postHogDeleteResponse: unknown = {
  persons_found: 1,
  persons_deleted: 1,
  events_queued_for_deletion: true,
  recordings_queued_for_deletion: true,
  deletion_errors: [],
};
const originalConsoleError = console.error;
const consoleError = mock(() => {});

type WorkflowProgram =
  | { readonly kind: "listUserVms"; readonly userId: string; readonly billingTeamId?: string | null }
  | {
      readonly kind: "revokeUserIdentityLeasesForAccountDeletion";
      readonly userId: string;
      readonly afterBatch?: () => unknown;
    }
  | {
      readonly kind: "destroyVm";
      readonly input: {
        readonly userId: string;
        readonly billingTeamId?: string | null;
        readonly providerVmId: string;
        readonly provider?: ProviderId;
        readonly afterProviderDestroy?: () => void;
      };
    };

type MockTransaction = {
  readonly select: (...args: unknown[]) => {
    readonly from: (...args: unknown[]) => {
      readonly where: (...args: unknown[]) => {
        readonly for: (...args: unknown[]) => Promise<unknown[]>;
      };
    };
  };
  readonly execute: (query: unknown) => Promise<void>;
  readonly delete: (table: unknown) => { readonly where: (condition: unknown) => Promise<void> };
  readonly insert: (table: unknown) => {
    readonly values: (values: unknown) => { readonly onConflictDoUpdate: () => Promise<void> };
  };
  readonly update: (table: unknown) => {
    readonly set: (values: unknown) => { readonly where: (condition: unknown) => Promise<void> };
  };
};

type SelectResult = Promise<unknown[]> & {
  readonly orderBy: (order: unknown) => SelectResult;
  readonly limit: (limit: number) => SelectResult;
  readonly offset: (offset: number) => SelectResult;
};

const mockTransaction: MockTransaction = {
  select: transactionSelect,
  execute: transactionExecute,
  delete: transactionDeleteRows,
  insert: insertRows,
  update: updateRows,
};

function nextSelectResult(): unknown[] {
  return selectResults.shift() ?? [];
}

function nextTransactionSelectResult(): unknown[] {
  return transactionSelectResults.shift() ?? [];
}

function nextTransactionTombstoneSelectResult(): unknown[] {
  return transactionTombstoneSelectResults.shift() ?? [];
}

function nextTransactionAnalyticsLeaseSelectResult(): unknown[] {
  return transactionAnalyticsLeaseSelectResults.shift() ?? [];
}

function chainableSelectResult(rows: unknown[]): SelectResult {
  const result = Promise.resolve(rows) as SelectResult;
  Object.defineProperties(result, {
    orderBy: { value: () => result },
    limit: { value: () => result },
    offset: { value: () => result },
  });
  return result;
}

function restoreEnv(name: string, value: string | undefined): void {
  if (value === undefined) {
    delete process.env[name];
  } else {
    process.env[name] = value;
  }
}

function expectPostHogAccountDeleteRequest(): void {
  expect(postHogDeleteRequests).toHaveLength(1);
  const [url, init] = postHogDeleteRequests[0]!;
  expect(String(url)).toBe("https://posthog.test/api/environments/env-244066/persons/bulk_delete/");
  expect(init?.method).toBe("POST");
  expect(init?.headers).toEqual({
    "Authorization": "Bearer test-posthog-personal-api-key",
    "Content-Type": "application/json",
  });
  expect(JSON.parse(String(init?.body))).toEqual({
    distinct_ids: [ACCOUNT_USER_ID],
    delete_events: true,
    delete_recordings: true,
    keep_person: false,
  });
  expect(init?.signal).toBeInstanceOf(AbortSignal);
}

const mockDb = {
  select: mock(() => {
    let selectedTable: unknown = null;
    return {
      from: (table: unknown) => {
        selectedTable = table;
        return {
          where: (condition: unknown) => {
            selectedWhere.push({ table: selectedTable, condition });
            return chainableSelectResult(nextSelectResult());
          },
          innerJoin: () => ({
            where: (condition: unknown) => {
              selectedWhere.push({ table: selectedTable, condition });
              return chainableSelectResult(nextSelectResult());
            },
          }),
        };
      },
    };
  }),
  delete: deleteRows,
  update: updateRows,
  transaction,
};

mock.module("../app/lib/stack", () => ({
  ...stackModule,
  getStackServerApp: () => useAccountRouteStubs ? { getUser } : realGetStackServerApp(),
  isStackConfigured: () => useAccountRouteStubs ? true : realIsStackConfigured(),
}));

mock.module("../db/client", () => ({
  ...dbClientModule,
  cloudDb: () => useAccountRouteStubs ? mockDb : realCloudDb(),
  closeCloudDbForTests: () => useAccountRouteStubs ? Promise.resolve() : realCloseCloudDbForTests(),
}));

mock.module("../services/vault/storage", () => ({
  ...storageModule,
  deleteObject: ((...args: Parameters<typeof realDeleteObject>) => {
    const [objectKey] = args;
    if (isAccountDeletionVaultObject(objectKey)) return deleteObject(...args);
    return realDeleteObject(...args);
  }) as typeof realDeleteObject,
}));

mock.module("../services/vault/usage", () => ({
  ...vaultUsageModule,
  withVaultUserQuotaLock: (async (...args: Parameters<typeof realWithVaultUserQuotaLock>) => {
    const [db, userId, run] = args;
    if (useAccountRouteStubs) {
      vaultLockUsers.push(userId);
      return await run(db);
    }
    return await realWithVaultUserQuotaLock(...args);
  }) as typeof realWithVaultUserQuotaLock,
}));

mock.module("../services/billing/stripe", () => ({
  ...stripeModule,
  isStripeBillingConfigured: () => useAccountRouteStubs
    ? stripeConfigured
    : realIsStripeBillingConfigured(),
  stripe: () => useAccountRouteStubs
    ? {
        subscriptions: { cancel: cancelSubscription, update: updateSubscription },
        customers: { del: deleteCustomer, update: updateCustomer },
      }
    : realStripe(),
}));

mock.module("../services/asc/client", () => ({
  ...ascClientModule,
  isAscConfigured: () => useAccountRouteStubs ? ascConfigured : realIsAscConfigured(),
}));

mock.module("../services/asc/testflight", () => ({
  ...ascTestflightModule,
  removeTester: ((...args: Parameters<typeof realRemoveTester>) => {
    const [email] = args;
    if (useAccountRouteStubs) return removeTester(email);
    return realRemoveTester(...args);
  }) as typeof realRemoveTester,
}));

mock.module("../services/errors", () => ({
  ...errorsModule,
  captureAscError: ((...args: Parameters<typeof realCaptureAscError>) => {
    if (useAccountRouteStubs) return captureAscError(...args);
    return realCaptureAscError(...args);
  }) as typeof realCaptureAscError,
}));

mock.module("../services/subrouter/client", () => ({
  ...subrouterClientModule,
  createSubrouterClientFromEnv: () => {
    if (!useAccountRouteStubs) return realCreateSubrouterClientFromEnv();
    if (subrouterClientCreateError) throw subrouterClientCreateError;
    return {
        revokeTenant,
      };
  },
}));

mock.module("../services/vms/workflows", () => ({
  ...workflowsModule,
  destroyVm: ((...args: Parameters<typeof realDestroyVm>) => {
    const [input] = args;
    if (input.userId === ACCOUNT_USER_ID) return destroyVm(...args);
    return realDestroyVm(...args);
  }) as typeof realDestroyVm,
  revokeUserIdentityLeasesForAccountDeletion: ((...args: Parameters<typeof realRevokeUserIdentityLeasesForAccountDeletion>) => {
    const [userId] = args;
    if (userId === ACCOUNT_USER_ID) return revokeUserIdentityLeasesForAccountDeletion(...args);
    return realRevokeUserIdentityLeasesForAccountDeletion(...args);
  }) as typeof realRevokeUserIdentityLeasesForAccountDeletion,
  listUserVms: ((...args: Parameters<typeof realListUserVms>) => {
    const [userId] = args;
    if (userId === ACCOUNT_USER_ID) return listUserVms(...args);
    return realListUserVms(...args);
  }) as typeof realListUserVms,
  runVmWorkflow: ((...args: unknown[]) => {
    const [program] = args;
    if (isAccountDeletionWorkflowProgram(program)) return runVmWorkflow(...args);
    return realRunVmWorkflow(...args);
  }) as typeof workflowsModule.runVmWorkflow,
}));

const { DELETE } = await import("../app/api/account/route");

beforeAll(() => {
  useAccountRouteStubs = true;
});

afterAll(() => {
  useAccountRouteStubs = false;
});

beforeEach(() => {
  console.error = consoleError as typeof console.error;
  globalThis.fetch = postHogDeleteFetch as typeof fetch;
  process.env.POSTHOG_PERSONAL_API_KEY = "test-posthog-personal-api-key";
  process.env.POSTHOG_API_HOST = "https://posthog.test";
  process.env.POSTHOG_ENVIRONMENT_ID = "env-244066";
  consoleError.mockClear();
  deleteStackUser.mockClear();
  updateStackUser.mockClear();
  getUser.mockClear();
  transaction.mockClear();
  transactionSelect.mockClear();
  transactionExecute.mockClear();
  transactionDeleteRows.mockClear();
  deleteRows.mockClear();
  insertRows.mockClear();
  updateRows.mockClear();
  mockDb.select.mockClear();
  listUserVms.mockClear();
  revokeUserIdentityLeasesForAccountDeletion.mockClear();
  destroyVm.mockClear();
  runVmWorkflow.mockClear();
  deleteObject.mockClear();
  cancelSubscription.mockClear();
  deleteCustomer.mockClear();
  updateCustomer.mockClear();
  updateSubscription.mockClear();
  removeTester.mockClear();
  captureAscError.mockClear();
  revokeTenant.mockClear();
  postHogDeleteFetch.mockClear();
  deletedTableCount = 0;
  deletedTables = [];
  deletedWhere = [];
  selectedWhere = [];
  updatedRows = [];
  tombstoneUpdates = [];
  tombstoneCompleteError = null;
  tombstoneCleanupIncompleteError = null;
  routeEvents = [];
  stackDeleteError = null;
  stackUserIds = [];
  selectResults = [[], [], [], [], [], []];
  transactionSelectResults = [];
  transactionTombstoneSelectResults = [];
  transactionAnalyticsLeaseSelectResults = [];
  deletedVaultObjects = [];
  vaultDeleteError = null;
  postStackVaultDeleteError = null;
  stripeConfigured = true;
  ascConfigured = false;
  cancelledStripeSubscriptions = [];
  deletedStripeCustomers = [];
  updatedStripeCustomers = [];
  updatedStripeSubscriptions = [];
  stripeCancelError = null;
  stripeDeleteCustomerError = null;
  stripeUpdateCustomerError = null;
  stripeUpdateSubscriptionError = null;
  removeTesterError = null;
  destroyVmFailureProviderIds = new Set();
  destroyVmFailureErrorsByProviderId = new Map();
  destroyVmAfterProviderErrorsByProviderId = new Map();
  listedPersonalVmIds = ["personal-vm-1", "personal-vm-2"];
  listedPersonalVmIdsByBillingTeam = {};
  revokeIdentityLeasesError = null;
  revokedIdentityLeaseCount = 2;
  lastRevokeIdentityCall = null;
  subrouterClientCreateError = null;
  subrouterRevokeError = null;
  subrouterRevokeErrors = [];
  stackUserSelectedTeam = null;
  stackUserTeams = [];
  vaultLockUsers = [];
  postHogDeleteRequests = [];
  postHogDeleteError = null;
  postHogDeleteStatus = 202;
  postHogDeleteResponse = {
    persons_found: 1,
    persons_deleted: 1,
    events_queued_for_deletion: true,
    recordings_queued_for_deletion: true,
    deletion_errors: [],
  };
});

afterEach(() => {
  console.error = originalConsoleError;
  globalThis.fetch = realFetch;
  restoreEnv("POSTHOG_PERSONAL_API_KEY", originalPostHogPersonalApiKey);
  restoreEnv("POSTHOG_API_HOST", originalPostHogApiHost);
  restoreEnv("POSTHOG_ENVIRONMENT_ID", originalPostHogEnvironmentId);
  restoreEnv("POSTHOG_PROJECT_ID", originalPostHogProjectId);
});

describe("account deletion route", () => {
  test("requires native auth headers", async () => {
    const response = await DELETE(new Request("https://cmux.test/api/account", { method: "DELETE" }));

    expect(response.status).toBe(401);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(transaction).not.toHaveBeenCalled();
  });

  test("destroys personal VMs, deletes cmux rows, then deletes the Stack user", async () => {
    selectResults = [
      [{ id: "sub_user_active" }],
      [{ id: "cus_user" }],
      [{ objectKey: "vault/u/account-user-1/snapshot.jsonl.zst" }],
      [{ objectKey: "vault/u/account-user-1/grant.jsonl.zst", uploadObjectKey: "vault/uploads/grant" }],
      [{ objectKey: "vault/u/account-user-1/tombstone.jsonl.zst", uploadObjectKey: "vault/uploads/tombstone" }],
      [{ latestObjectKey: "vault/u/account-user-1/latest.jsonl.zst" }],
    ];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, destroyedVms: 2 });
    expect(listUserVms).toHaveBeenCalledWith("account-user-1");
    expect(destroyVm).toHaveBeenCalledTimes(2);
    expect(destroyVm).toHaveBeenCalledWith(expect.objectContaining({
      userId: "account-user-1",
      teamIds: ["account-user-1"],
      providerVmId: "personal-vm-1",
      provider: "freestyle",
    }));
    expect(destroyVm).toHaveBeenCalledWith(expect.objectContaining({
      userId: "account-user-1",
      teamIds: ["account-user-1"],
      providerVmId: "personal-vm-2",
      provider: "freestyle",
    }));
    expect(transaction).toHaveBeenCalledTimes(4);
    expect(deletedTableCount).toBeGreaterThan(10);
    expect(deletedTables).toContain(cloudVmBillingGrants);
    expect(deletedTables).toContain(devices);
    const nonStripeUpdates = updatedRows.filter(({ table }) =>
      table !== stripeSubscriptions && table !== stripeCustomers
    );
    expect(nonStripeUpdates.map(({ table, values }) => ({
      table,
      values: stripUpdatedAt(values),
    }))).toEqual([
      { table: cloudVmBases, values: { createdByUserId: "deleted-account" } },
      { table: cloudVmBases, values: { lastOpenedByUserId: null } },
      { table: cloudVmBaseGenerations, values: { createdByUserId: "deleted-account" } },
      { table: cloudVmBases, values: { createdByUserId: "deleted-account" } },
      { table: cloudVmBases, values: { lastOpenedByUserId: null } },
      { table: cloudVmBaseGenerations, values: { createdByUserId: "deleted-account" } },
    ]);
    for (const update of updatedRows) {
      expect((update.values as { readonly updatedAt?: unknown }).updatedAt).toBeInstanceOf(Date);
    }
    expect(deletedVaultObjects).toEqual([
      "vault/u/account-user-1/snapshot.jsonl.zst",
      "vault/u/account-user-1/grant.jsonl.zst",
      "vault/uploads/grant",
      "vault/u/account-user-1/tombstone.jsonl.zst",
      "vault/uploads/tombstone",
      "vault/u/account-user-1/latest.jsonl.zst",
    ]);
    expect(cancelledStripeSubscriptions).toEqual(["sub_user_active"]);
    expect(deletedStripeCustomers).toEqual(["cus_user"]);
    expectPostHogAccountDeleteRequest();
    expect(updateStackUser).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(getUser).toHaveBeenCalledTimes(1);
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
    const completedTombstone = tombstoneUpdates.find((update) =>
      Boolean(
        update &&
          typeof update === "object" &&
          (update as { readonly userId?: unknown }).userId === null &&
          (update as { readonly status?: unknown }).status === "completed" &&
          (update as { readonly errorMessage?: unknown }).errorMessage === null,
      )
    );
    expect(completedTombstone).toBeTruthy();
    expect((completedTombstone as { readonly completedAt?: unknown }).completedAt).toBeInstanceOf(Date);
    expect(tombstoneUpdates.some((update) =>
      (update as { readonly status?: unknown }).status === "stack_delete_pending"
    )).toBe(true);
    const leaseRefreshes = tombstoneUpdates.filter((update) =>
      Boolean(
        update &&
          typeof update === "object" &&
          (update as { readonly updatedAt?: unknown }).updatedAt instanceof Date &&
          !("status" in update),
      )
    );
    expect(leaseRefreshes.length).toBeGreaterThanOrEqual(3);
    expect(routeEvents).toEqual([
      "transaction",
      "transaction-lock",
      "tombstone-upsert",
      "transaction",
      "transaction-lock",
      "analytics-lease-cleanup",
      "posthog-delete",
      "metadata-update",
      "stripe-cancel",
      "stripe-delete-customer",
      "revoke-identities",
      "list-vms",
      "destroy-vm",
      "destroy-vm",
      "vault-delete",
      "vault-delete",
      "vault-delete",
      "vault-delete",
      "vault-delete",
      "vault-delete",
      "transaction",
      "transaction-lock",
      "stack-delete",
      "transaction",
      "transaction-lock",
    ]);
  });

  test("blocks Stack deletion when PostHog account analytics deletion fails", async () => {
    postHogDeleteStatus = 500;

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 0,
    });
    expectPostHogAccountDeleteRequest();
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(routeEvents).toContain("posthog-delete");
    expect(routeEvents).not.toContain("stack-delete");
    expect(routeEvents).not.toContain("metadata-update");
    expect(routeEvents).not.toContain("stripe-cancel");
    expect(routeEvents).not.toContain("revoke-identities");
    expect(routeEvents).not.toContain("destroy-vm");
    expect(routeEvents).not.toContain("vault-delete");
    expect(tombstoneUpdates.some((values) =>
      (values as { readonly status?: unknown; readonly errorMessage?: unknown }).status === "failed" &&
      (values as { readonly errorMessage?: unknown }).errorMessage === "Error: PostHog account deletion failed with status 500"
    )).toBe(true);
  });

  test("blocks Stack deletion when PostHog reports partial deletion errors", async () => {
    postHogDeleteResponse = {
      persons_found: 1,
      persons_deleted: 0,
      events_queued_for_deletion: false,
      recordings_queued_for_deletion: false,
      deletion_errors: [{ distinct_id: ACCOUNT_USER_ID, error: "person delete failed" }],
    };

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 0,
    });
    expectPostHogAccountDeleteRequest();
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(routeEvents).not.toContain("stack-delete");
    expect(routeEvents).not.toContain("metadata-update");
    expect(routeEvents).not.toContain("destroy-vm");
  });

  test("blocks Stack deletion until PostHog queues event and recording deletion", async () => {
    postHogDeleteResponse = {
      persons_found: 1,
      persons_deleted: 1,
      events_queued_for_deletion: false,
      recordings_queued_for_deletion: false,
      deletion_errors: [],
    };

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(tombstoneUpdates.some((values) =>
      (values as { readonly analyticsDeletedAt?: unknown }).analyticsDeletedAt instanceof Date
    )).toBe(false);
  });

  test("accepts a complete PostHog deletion response when optional deletion errors are omitted", async () => {
    postHogDeleteResponse = {
      persons_found: 1,
      persons_deleted: 1,
      events_queued_for_deletion: true,
      recordings_queued_for_deletion: true,
    };

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
    expect(tombstoneUpdates.some((values) =>
      (values as { readonly analyticsDeletedAt?: unknown }).analyticsDeletedAt instanceof Date
    )).toBe(true);
  });

  test("accepts PostHog zero matches as an already-complete deletion", async () => {
    postHogDeleteResponse = {
      persons_found: 0,
      persons_deleted: 0,
      events_queued_for_deletion: false,
      recordings_queued_for_deletion: false,
      deletion_errors: [],
    };

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
    expect(tombstoneUpdates.some((values) =>
      (values as { readonly analyticsDeletedAt?: unknown }).analyticsDeletedAt instanceof Date
    )).toBe(true);
  });

  test("fails closed before PostHog deletion while an analytics forward lease is active", async () => {
    transactionAnalyticsLeaseSelectResults = [[{ id: "active-forward-lease" }]];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 0,
    });
    expect(postHogDeleteFetch).not.toHaveBeenCalled();
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).not.toHaveBeenCalled();
    expect(destroyVm).not.toHaveBeenCalled();
  });

  test("cleans stale analytics leases and retries PostHog deletion", async () => {
    transactionAnalyticsLeaseSelectResults = [[]];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(routeEvents).toContain("analytics-lease-cleanup");
    expect(postHogDeleteFetch).toHaveBeenCalledTimes(1);
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
  });

  test("fails closed before PostHog deletion when no explicit environment is configured", async () => {
    delete process.env.POSTHOG_ENVIRONMENT_ID;
    delete process.env.POSTHOG_PROJECT_ID;

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "account_delete_failed" });
    expect(postHogDeleteFetch).not.toHaveBeenCalled();
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).not.toHaveBeenCalled();
    expect(cancelSubscription).not.toHaveBeenCalled();
    expect(removeTester).not.toHaveBeenCalled();
    expect(revokeUserIdentityLeasesForAccountDeletion).not.toHaveBeenCalled();
    expect(listUserVms).not.toHaveBeenCalled();
    expect(destroyVm).not.toHaveBeenCalled();
    expect(deleteObject).not.toHaveBeenCalled();
    expect(revokeTenant).not.toHaveBeenCalled();
    expect(consoleError).toHaveBeenCalledWith(
      "account.delete.failed",
      "Error: POSTHOG_ENVIRONMENT_ID is required for account deletion",
    );
  });

  test("destroys personal VMs with the same provider id on different providers", async () => {
    listedPersonalVmIds = [
      { providerVmId: "shared-provider-id", provider: "freestyle" },
      { providerVmId: "shared-provider-id", provider: "e2b" },
    ];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, destroyedVms: 2 });
    expect(destroyVm).toHaveBeenCalledTimes(2);
    expect(destroyVm).toHaveBeenCalledWith(expect.objectContaining({
      userId: "account-user-1",
      teamIds: ["account-user-1"],
      providerVmId: "shared-provider-id",
      provider: "freestyle",
    }));
    expect(destroyVm).toHaveBeenCalledWith(expect.objectContaining({
      userId: "account-user-1",
      teamIds: ["account-user-1"],
      providerVmId: "shared-provider-id",
      provider: "e2b",
    }));
  });

  test("destroys personal-team scoped VMs before deleting account rows", async () => {
    listedPersonalVmIds = [];
    listedPersonalVmIdsByBillingTeam = { "team-personal": ["personal-team-vm"] };
    stackUserTeams = [stackTeam("team-personal", ["account-user-1"])];
    selectResults = [
      [
        { id: "sub_user_active", stackTeamId: "legacy-user-team", scope: "user", status: "active" },
        { id: "sub_team_active", stackTeamId: "team-personal", scope: "team", status: "active" },
      ],
      [{ id: "cus_user" }, { id: "cus_team", stackTeamId: "team-personal" }],
      [],
      [],
      [],
      [],
      [{ tenantId: "tenant-team-personal" }],
    ];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, destroyedVms: 1 });
    expect(listUserVms).toHaveBeenCalledWith("account-user-1");
    expect(listUserVms).toHaveBeenCalledWith("account-user-1", "team-personal");
    expect(destroyVm).toHaveBeenCalledWith(expect.objectContaining({
      userId: "account-user-1",
      billingTeamId: "team-personal",
      teamIds: ["account-user-1", "team-personal"],
      providerVmId: "personal-team-vm",
      provider: "freestyle",
    }));
    expect(cancelledStripeSubscriptions).toEqual(["sub_user_active", "sub_team_active"]);
    expect(deletedStripeCustomers).toEqual(["cus_user", "cus_team"]);
    const subscriptionSelect = selectedWhere.find((entry) => entry.table === stripeSubscriptions);
    expect(conditionColumnNames(subscriptionSelect?.condition)).toContain("stack_team_id");
    const customerSelect = selectedWhere.find((entry) => entry.table === stripeCustomers);
    expect(conditionColumnNames(customerSelect?.condition)).toContain("stack_team_id");
    const subscriptionDelete = deletedWhere.find((entry) => entry.table === stripeSubscriptions);
    expect(conditionColumnNames(subscriptionDelete?.condition)).toContain("stack_team_id");
    const customerDelete = deletedWhere.find((entry) => entry.table === stripeCustomers);
    expect(conditionColumnNames(customerDelete?.condition)).toContain("stack_team_id");
    expect(revokeTenant).toHaveBeenCalledWith("tenant-team-personal");
    expect(transactionExecute).toHaveBeenCalledTimes(6);
    const grantDelete = deletedWhere.find((entry) => entry.table === cloudVmBillingGrants);
    expect(conditionColumnNames(grantDelete?.condition)).toContain("billing_customer_id");
    const baseDelete = deletedWhere.find((entry) => entry.table === cloudVmBases);
    expect(conditionColumnNames(baseDelete?.condition)).toContain("scope_id");
  });

  test("deletes account-owned team VM rows created by another user", async () => {
    listedPersonalVmIds = [];
    listedPersonalVmIdsByBillingTeam = { "team-personal": ["personal-team-vm"] };
    stackUserTeams = [stackTeam("team-personal", ["account-user-1"])];
    transactionSelectResults = [[{
      id: "00000000-0000-4000-8000-000000000768",
      billingTeamId: "team-personal",
      providerVmId: "personal-team-vm",
      status: "destroyed",
    }]];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(destroyVm).toHaveBeenCalledWith(expect.objectContaining({
      userId: "account-user-1",
      billingTeamId: "team-personal",
      teamIds: ["account-user-1", "team-personal"],
      providerVmId: "personal-team-vm",
    }));
    expect(deletedTables).toContain(cloudVms);
    expect(updatedRows.map(({ table }) => table)).not.toContain(cloudVms);
    const usageDelete = deletedWhere.find((entry) => entry.table === cloudVmUsageEvents);
    expect(conditionColumnNames(usageDelete?.condition)).toContain("billing_team_id");
    expect(conditionColumnNames(usageDelete?.condition)).toContain("vm_id");
    const leaseDelete = deletedWhere.find((entry) => entry.table === cloudVmLeases);
    expect(conditionColumnNames(leaseDelete?.condition)).toContain("vm_id");
    const sessionDelete = deletedWhere.find((entry) => entry.table === cloudVmSessions);
    expect(conditionColumnNames(sessionDelete?.condition)).toContain("vm_id");
  });

  test("joins an in-progress account deletion instead of rerunning destructive cleanup", async () => {
    transactionTombstoneSelectResults = [[{
      userIdHash: "existing-hash",
      status: "pending",
      updatedAt: new Date(),
    }]];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({
      ok: true,
      deletionPending: true,
      destroyedVms: 0,
    });
    expect(updateStackUser).not.toHaveBeenCalled();
    expect(cancelSubscription).not.toHaveBeenCalled();
    expect(listUserVms).not.toHaveBeenCalled();
    expect(deleteStackUser).not.toHaveBeenCalled();
  });

  test("returns completed when a retry sees a completed account deletion tombstone", async () => {
    transactionTombstoneSelectResults = [[{
      userIdHash: "existing-hash",
      status: "completed",
      updatedAt: new Date(),
    }]];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      destroyedVms: 0,
    });
    expect(updateStackUser).not.toHaveBeenCalled();
    expect(cancelSubscription).not.toHaveBeenCalled();
    expect(listUserVms).not.toHaveBeenCalled();
    expect(deleteStackUser).not.toHaveBeenCalled();
  });

  test("resumes post-Stack cleanup when a retry sees a cleanup-incomplete tombstone", async () => {
    transactionTombstoneSelectResults = [[{
      userIdHash: "existing-hash",
      status: "cleanup_incomplete",
      updatedAt: new Date(),
    }]];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      destroyedVms: 0,
    });
    expect(updateStackUser).not.toHaveBeenCalled();
    expect(cancelSubscription).not.toHaveBeenCalled();
    expect(listUserVms).not.toHaveBeenCalled();
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(postHogDeleteFetch).not.toHaveBeenCalled();
    expect(tombstoneUpdates.some((values) =>
      (values as { readonly status?: unknown }).status === "completed"
    )).toBe(true);
  });

  test("adopts a stale in-progress account deletion instead of blocking forever", async () => {
    transactionTombstoneSelectResults = [[{
      userIdHash: "existing-hash",
      status: "pending",
      updatedAt: new Date(Date.now() - 20 * 60 * 1000),
    }]];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, destroyedVms: 2 });
    expect(routeEvents).toContain("tombstone-upsert");
    expect(updateStackUser).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
  });

  test("does not treat a selected shared Stack team as account-owned data", async () => {
    listedPersonalVmIds = [];
    listedPersonalVmIdsByBillingTeam = { "team-shared": ["shared-team-vm"] };
    stackUserSelectedTeam = stackTeam("team-shared", ["account-user-1", "other-user"]);

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, destroyedVms: 0 });
    expect(listUserVms).toHaveBeenCalledWith("account-user-1");
    expect(listUserVms).not.toHaveBeenCalledWith("account-user-1", "team-shared");
    expect(destroyVm).not.toHaveBeenCalledWith({
      userId: "account-user-1",
      billingTeamId: "team-shared",
      teamIds: ["account-user-1", "team-shared"],
      providerVmId: "shared-team-vm",
      provider: "freestyle",
    });
    expect(transactionExecute).toHaveBeenCalledTimes(4);
  });

  test("uses the listed Stack team when selectedTeam has no member listing", async () => {
    listedPersonalVmIds = [];
    listedPersonalVmIdsByBillingTeam = { "team-personal": ["personal-team-vm"] };
    stackUserSelectedTeam = { id: "team-personal" };
    stackUserTeams = [stackTeam("team-personal", ["account-user-1"])];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, destroyedVms: 1 });
    expect(listUserVms).toHaveBeenCalledWith("account-user-1");
    expect(listUserVms).toHaveBeenCalledWith("account-user-1", "team-personal");
    expect(destroyVm).toHaveBeenCalledWith(expect.objectContaining({
      userId: "account-user-1",
      billingTeamId: "team-personal",
      teamIds: ["account-user-1", "team-personal"],
      providerVmId: "personal-team-vm",
      provider: "freestyle",
    }));
  });

  test("pages through Stack teams before selecting account-owned data", async () => {
    listedPersonalVmIds = [];
    listedPersonalVmIdsByBillingTeam = { "team-personal-page-2": ["personal-team-vm"] };
    let listedTeamsAfterTombstone = false;
    stackUserTeams = ({ cursor } = {}) => {
      listedTeamsAfterTombstone = listedTeamsAfterTombstone || routeEvents.includes("tombstone-upsert");
      return cursor === "page-2"
        ? stackPage([stackTeam("team-personal-page-2", ["account-user-1"])])
        : stackPage([stackTeam("team-shared-page-1", ["account-user-1", "other-user"])], "page-2");
    };

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, destroyedVms: 1 });
    expect(listedTeamsAfterTombstone).toBe(true);
    expect(listUserVms).toHaveBeenCalledWith("account-user-1");
    expect(listUserVms).toHaveBeenCalledWith("account-user-1", "team-personal-page-2");
    expect(destroyVm).toHaveBeenCalledWith(expect.objectContaining({
      userId: "account-user-1",
      billingTeamId: "team-personal-page-2",
      teamIds: ["account-user-1", "team-personal-page-2"],
      providerVmId: "personal-team-vm",
      provider: "freestyle",
    }));
  });

  test("accepts non-paginated Stack team member arrays with 100 members", async () => {
    listedPersonalVmIds = [];
    const teamMembers = [
      "account-user-1",
      ...Array.from({ length: 99 }, (_, index) => `member-${index}`),
    ];
    stackUserSelectedTeam = stackTeam("large-team", teamMembers);

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, destroyedVms: 0 });
    expect(listUserVms).toHaveBeenCalledWith("account-user-1");
    expect(listUserVms).not.toHaveBeenCalledWith("account-user-1", "large-team");
  });

  test("reassigns retained shared-team Stripe billing to another team member", async () => {
    listedPersonalVmIds = [];
    stackUserSelectedTeam = stackTeam("team-shared", ["account-user-1", "other-user"]);
    selectResults = [
      [{ id: "sub_shared", stackTeamId: "team-shared", scope: "team", status: "active" }],
      [{ id: "cus_shared", stackTeamId: "team-shared" }],
      [],
      [],
      [],
      [],
    ];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(cancelledStripeSubscriptions).toEqual([]);
    expect(deletedStripeCustomers).toEqual([]);
    expect(updatedStripeCustomers).toEqual([{
      id: "cus_shared",
      params: {
        email: "",
        metadata: expect.objectContaining({ stackUserId: "other-user" }),
      },
    }]);
    expect(updatedStripeSubscriptions).toEqual([{
      id: "sub_shared",
      params: {
        metadata: expect.objectContaining({ stackUserId: "other-user" }),
      },
    }]);
    expect(updatedRows.map(({ table, values }) => ({
      table,
      values: stripUpdatedAt(values),
    }))).toContainEqual({
      table: stripeCustomers,
      values: { stackUserId: "other-user", email: null },
    });
    expect(updatedRows.map(({ table, values }) => ({
      table,
      values: stripUpdatedAt(values),
    }))).toContainEqual({
      table: stripeSubscriptions,
      values: { stackUserId: "other-user", raw: null },
    });
  });

  test("restores Stack metadata when retained shared-team Stripe transfer fails before mutation", async () => {
    listedPersonalVmIds = [];
    stackUserSelectedTeam = stackTeam("team-shared", ["account-user-1", "other-user"]);
    selectResults = [
      [],
      [{ id: "cus_shared", stackTeamId: "team-shared" }],
    ];
    stripeUpdateCustomerError = new Error("stripe update timed out");

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 0,
    });
    expect(updateCustomer).toHaveBeenCalledWith("cus_shared", expect.objectContaining({
      metadata: expect.objectContaining({ stackUserId: "other-user" }),
    }));
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).toHaveBeenNthCalledWith(1, {
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenNthCalledWith(2, {
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
  });

  test("fails closed when Stack cannot list selected team members", async () => {
    stackUserSelectedTeam = { id: "team-shared" };

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "account_delete_failed" });
    expect(updateStackUser).not.toHaveBeenCalled();
    expect(cancelSubscription).not.toHaveBeenCalled();
    expect(deleteStackUser).not.toHaveBeenCalled();
  });

  test("fails closed when Stack team pagination loops", async () => {
    stackUserTeams = () => stackPage([], "repeat");

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "account_delete_failed" });
    expect(transaction).toHaveBeenCalledTimes(1);
    expect(routeEvents).toContain("tombstone-upsert");
    expect(tombstoneUpdates.some((values) =>
      Boolean(values && typeof values === "object" && (values as { readonly status?: unknown }).status === "failed")
    )).toBe(true);
    expect(updateStackUser).not.toHaveBeenCalled();
    expect(deleteStackUser).not.toHaveBeenCalled();
  });

  test("revokes the personal Subrouter tenant before deleting local rows", async () => {
    selectResults = [
      [],
      [],
      [],
      [],
      [],
      [],
      [{ tenantId: "tenant-personal" }],
    ];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(revokeTenant).toHaveBeenCalledWith("tenant-personal");
    expect(deletedTables).toContain(subrouterTenants);
    expect(routeEvents.indexOf("subrouter-revoke:tenant-personal")).toBeLessThan(
      routeEvents.lastIndexOf("transaction"),
    );
  });

  test("removes TestFlight access during account deletion when ASC is configured", async () => {
    ascConfigured = true;
    listedPersonalVmIds = [];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(removeTester).toHaveBeenCalledWith("account@example.com");
    expect(routeEvents).toContain("testflight-remove:account@example.com");
  });

  test("revokes active account SSH identities before deleting cmux rows", async () => {
    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expectIdentityRevocationHeartbeatConfigured();
    expect(routeEvents.indexOf("revoke-identities")).toBeGreaterThan(-1);
    expect(routeEvents.indexOf("revoke-identities")).toBeLessThan(routeEvents.indexOf("list-vms"));
    expect(routeEvents.indexOf("revoke-identities")).toBeLessThan(routeEvents.indexOf("destroy-vm"));
    expect(routeEvents.indexOf("revoke-identities")).toBeLessThan(routeEvents.lastIndexOf("transaction"));
    expect(deletedTables).toContain(cloudVmLeases);
  });

  test("restores Stack metadata when pre-destructive cleanup fails", async () => {
    listedPersonalVmIds = [];
    revokeIdentityLeasesError = new Error("identity lookup failed");

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 0,
    });
    expect(deletedVaultObjects).toEqual([]);
    expect(transaction).toHaveBeenCalledTimes(2);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).toHaveBeenNthCalledWith(1, {
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenNthCalledWith(2, {
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
    expect(consoleError).toHaveBeenCalledWith(
      "account.delete.failed",
      "Error: identity lookup failed",
    );
  });

  test("keeps deletion retryable when identity revocation partially mutates provider state", async () => {
    listedPersonalVmIds = [];
    revokeIdentityLeasesError = new vmErrorsModule.VmAccountDeletionIdentityRevocationError({
      cause: new Error("provider identity revoke failed"),
    });

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 0,
    });
    expectIdentityRevocationHeartbeatConfigured();
    expect(transaction).toHaveBeenCalledTimes(2);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).toHaveBeenNthCalledWith(1, {
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenCalledTimes(1);
  });

  test("does not destroy personal VMs when account SSH identity revocation fails before external mutation", async () => {
    revokeIdentityLeasesError = new Error("provider identity revoke failed");

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 0,
    });
    expectIdentityRevocationHeartbeatConfigured();
    expect(listUserVms).not.toHaveBeenCalled();
    expect(destroyVm).not.toHaveBeenCalled();
    expect(transaction).toHaveBeenCalledTimes(2);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).toHaveBeenNthCalledWith(1, {
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenNthCalledWith(2, {
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
    expect(deletedTables).not.toContain(cloudVmLeases);
  });

  test("restores Stack metadata when VM cleanup fails before provider deletion starts", async () => {
    listedPersonalVmIds = ["personal-vm-1"];
    revokedIdentityLeaseCount = 0;
    destroyVmFailureErrorsByProviderId = new Map([
      [
        "personal-vm-1",
        vmProviderOperationError("revokeSSHIdentity", "too many active identity leases pending cleanup: 9"),
      ],
    ]);

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 0,
    });
    expect(routeEvents.indexOf("revoke-identities")).toBeLessThan(routeEvents.indexOf("destroy-vm"));
    expect(destroyVm).toHaveBeenCalledTimes(1);
    expect(transaction).toHaveBeenCalledTimes(2);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).toHaveBeenNthCalledWith(1, {
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenNthCalledWith(2, {
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
    expect(consoleError).toHaveBeenCalledWith(
      "account.delete.failed",
      "AccountDeletionDestructiveCleanupError: Failed to destroy 1 personal cloud VM",
    );
  });

  test("keeps VM cleanup retryable when prior identity revocation changed provider state", async () => {
    listedPersonalVmIds = ["personal-vm-1"];
    revokedIdentityLeaseCount = 2;
    destroyVmFailureErrorsByProviderId = new Map([
      [
        "personal-vm-1",
        vmProviderOperationError("revokeSSHIdentity", "too many active identity leases pending cleanup: 9"),
      ],
    ]);

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 0,
    });
    expect(routeEvents.indexOf("revoke-identities")).toBeLessThan(routeEvents.indexOf("destroy-vm"));
    expect(transaction).toHaveBeenCalledTimes(2);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).toHaveBeenNthCalledWith(1, {
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenCalledTimes(1);
    expect(consoleError).toHaveBeenCalledWith(
      "account.delete.partial_after_destructive_cleanup",
      "AccountDeletionDestructiveCleanupError: Failed to destroy 1 personal cloud VM",
    );
  });

  test("keeps VM cleanup retryable when provider destroy succeeds but DB mark fails", async () => {
    listedPersonalVmIds = ["personal-vm-1"];
    revokedIdentityLeaseCount = 0;
    destroyVmAfterProviderErrorsByProviderId = new Map([
      ["personal-vm-1", new Error("mark destroyed failed")],
    ]);

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 0,
    });
    expect(destroyVm).toHaveBeenCalledWith(expect.objectContaining({
      userId: "account-user-1",
      teamIds: ["account-user-1"],
      providerVmId: "personal-vm-1",
      provider: "freestyle",
    }));
    const destroyVmCalls = (destroyVm as unknown as {
      mock: { calls: Array<[{ readonly afterProviderDestroy?: unknown }]> };
    }).mock.calls;
    const [destroyInput] = destroyVmCalls[0];
    expect(typeof destroyInput.afterProviderDestroy).toBe("function");
    expect(transaction).toHaveBeenCalledTimes(2);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).toHaveBeenNthCalledWith(1, {
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenCalledTimes(1);
    expect(consoleError).toHaveBeenCalledWith(
      "account.delete.partial_after_destructive_cleanup",
      "AccountDeletionDestructiveCleanupError: Failed to destroy 1 personal cloud VM",
    );
  });

  test("keeps deletion retryable after Subrouter 404 removes local tenant state", async () => {
    listedPersonalVmIds = [];
    revokedIdentityLeaseCount = 0;
    selectResults = [
      [],
      [],
      [],
      [],
      [],
      [],
      [{ tenantId: "tenant-personal" }],
    ];
    subrouterRevokeError = new subrouterClientModule.SubrouterClientError("revokeTenant", 404);
    stackDeleteError = new Error("stack unavailable after subrouter cleanup");

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 0,
    });
    expect(revokeTenant).toHaveBeenCalledWith("tenant-personal");
    expect(deletedTables).toContain(subrouterTenants);
    expect(transaction).toHaveBeenCalledTimes(3);
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
    expect(updateStackUser).toHaveBeenNthCalledWith(1, {
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenCalledTimes(1);
  });

  test("restores Stack metadata when Subrouter revoke fails before external mutation", async () => {
    listedPersonalVmIds = [];
    revokedIdentityLeaseCount = 0;
    selectResults = [
      [],
      [],
      [],
      [],
      [],
      [],
      [{ tenantId: "tenant-personal" }],
    ];
    subrouterRevokeError = new Error("subrouter request timed out");

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 0,
    });
    expect(revokeTenant).toHaveBeenCalledWith("tenant-personal");
    expect(deletedTables).not.toContain(subrouterTenants);
    expect(transaction).toHaveBeenCalledTimes(2);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).toHaveBeenNthCalledWith(1, {
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenNthCalledWith(2, {
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
  });

  test("restores Stack metadata when Subrouter 404 is followed by a pre-mutation failure", async () => {
    listedPersonalVmIds = [];
    revokedIdentityLeaseCount = 0;
    selectResults = [
      [],
      [],
      [],
      [],
      [],
      [],
      [{ tenantId: "tenant-missing" }, { tenantId: "tenant-timeout" }],
    ];
    subrouterRevokeErrors = [
      new subrouterClientModule.SubrouterClientError("revokeTenant", 404),
      new Error("subrouter request timed out"),
    ];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 0,
    });
    expect(revokeTenant).toHaveBeenCalledWith("tenant-missing");
    expect(revokeTenant).toHaveBeenCalledWith("tenant-timeout");
    expect(deletedTables).not.toContain(subrouterTenants);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).toHaveBeenNthCalledWith(1, {
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenNthCalledWith(2, {
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
  });

  test("restores Stack metadata when local Subrouter configuration fails before external mutation", async () => {
    listedPersonalVmIds = [];
    revokedIdentityLeaseCount = 0;
    selectResults = [
      [],
      [],
      [],
      [],
      [],
      [],
      [{ tenantId: "tenant-personal" }],
    ];
    subrouterClientCreateError = new Error("subrouter not configured");

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 0,
    });
    expect(revokeTenant).not.toHaveBeenCalled();
    expect(deletedTables).not.toContain(subrouterTenants);
    expect(transaction).toHaveBeenCalledTimes(2);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).toHaveBeenNthCalledWith(1, {
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenNthCalledWith(2, {
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
  });

  test("does not delete personal VM rows that gained a provider id before account row deletion", async () => {
    transactionSelectResults = [[{
      id: "00000000-0000-4000-8000-000000000764",
      providerVmId: "provider-vm-raced",
      status: "running",
    }]];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 2,
    });
    expect(transaction).toHaveBeenCalledTimes(3);
    expect(transactionExecute).toHaveBeenCalledTimes(3);
    expect(transactionSelect).toHaveBeenCalledTimes(3);
    expect(deletedTableCount).toBe(0);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(consoleError).toHaveBeenCalledWith(
      "account.delete.partial_after_destructive_cleanup",
      "Error: Personal cloud VM provider teardown or creation is still pending for 1 row",
    );
  });

  test("deletes destroyed personal VM rows after provider teardown completed", async () => {
    transactionSelectResults = [[{
      id: "00000000-0000-4000-8000-000000000765",
      providerVmId: "provider-vm-destroyed",
      status: "destroyed",
    }]];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(deletedTables).toContain(cloudVms);
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
  });

  test("deletes failed providerless VM rows without provider teardown", async () => {
    listedPersonalVmIds = [
      { providerVmId: null, provider: "freestyle" },
      "personal-vm-1",
    ];
    transactionSelectResults = [[{
      id: "00000000-0000-4000-8000-000000000767",
      providerVmId: null,
      status: "failed",
    }]];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, destroyedVms: 1 });
    expect(destroyVm).toHaveBeenCalledTimes(1);
    expect(destroyVm).toHaveBeenCalledWith(expect.objectContaining({
      userId: "account-user-1",
      teamIds: ["account-user-1"],
      providerVmId: "personal-vm-1",
      provider: "freestyle",
    }));
    expect(deletedTables).toContain(cloudVms);
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
  });

  test("anonymizes retained shared-team VM rows without blocking deletion", async () => {
    transactionSelectResults = [[{
      id: "00000000-0000-4000-8000-000000000766",
      billingTeamId: "team-shared",
      providerVmId: "provider-vm-shared",
      status: "running",
    }]];
    stackUserSelectedTeam = stackTeam("team-shared", ["account-user-1", "other-user"]);

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(listUserVms).not.toHaveBeenCalledWith("account-user-1", "team-shared");
    expect(deletedTables).not.toContain(cloudVms);
    expect(updatedRows.map(({ table, values }) => ({
      table,
      values: stripUpdatedAt(values),
    }))).toContainEqual({ table: cloudVms, values: { userId: "deleted-account" } });
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
  });

  test("deletes owned team and shared team devices registered by the deleted user", async () => {
    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(deletedTables).toContain(devices);
    const deviceDelete = deletedWhere.find((entry) => entry.table === devices);
    expect(conditionColumnNames(deviceDelete?.condition)).toContain("user_id");
    expect(conditionColumnNames(deviceDelete?.condition)).toContain("team_id");
    expect(updatedRows.map(({ table }) => table)).not.toContain(devices);
  });

  test("deletes vault rows in bounded batches after their objects are removed", async () => {
    selectResults = [
      [],
      [],
      [
        { id: "snapshot-1", objectKey: "vault/u/account-user-1/snapshot-1.jsonl.zst" },
        { id: "snapshot-2", objectKey: "vault/u/account-user-1/snapshot-2.jsonl.zst" },
      ],
      [{ id: "grant-1", objectKey: "vault/u/account-user-1/grant.jsonl.zst", uploadObjectKey: "vault/uploads/grant" }],
      [{
        id: "tombstone-1",
        objectKey: "vault/u/account-user-1/tombstone.jsonl.zst",
        uploadObjectKey: "vault/uploads/tombstone",
      }],
      [{ id: "session-1", latestObjectKey: "vault/u/account-user-1/latest.jsonl.zst" }],
    ];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(deletedVaultObjects).toEqual([
      "vault/u/account-user-1/snapshot-1.jsonl.zst",
      "vault/u/account-user-1/snapshot-2.jsonl.zst",
      "vault/u/account-user-1/grant.jsonl.zst",
      "vault/uploads/grant",
      "vault/u/account-user-1/tombstone.jsonl.zst",
      "vault/uploads/tombstone",
      "vault/u/account-user-1/latest.jsonl.zst",
    ]);
    expect(deletedTables).toContain(vaultSnapshots);
    expect(deletedTables).toContain(vaultUploadGrants);
    expect(deletedTables).toContain(vaultUploadTombstones);
    expect(deletedTables).toContain(vaultSessions);
    expect(vaultLockUsers).toContain("account-user-1");
  });

  test("keeps deletion retryable when vault object cleanup fails after VMs are destroyed", async () => {
    selectResults = [
      [],
      [],
      [{ id: "snapshot-1", objectKey: "vault/u/account-user-1/snapshot.jsonl.zst" }],
      [],
      [],
      [],
    ];
    vaultDeleteError = new Error("vault unavailable");

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 2,
    });
    expect(transaction).toHaveBeenCalledTimes(2);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).toHaveBeenNthCalledWith(1, {
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenCalledTimes(1);
  });

  test("keeps deletion retryable when cleanup fails after Stripe and VM cleanup", async () => {
    selectResults = [
      [{ id: "sub_user_active" }],
      [{ id: "cus_user" }],
      [{ id: "snapshot-1", objectKey: "vault/u/account-user-1/snapshot.jsonl.zst" }],
      [],
      [],
      [],
    ];
    vaultDeleteError = new Error("vault unavailable");

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 2,
    });
    expect(cancelledStripeSubscriptions).toEqual(["sub_user_active"]);
    expect(deletedStripeCustomers).toEqual(["cus_user"]);
    expect(transaction).toHaveBeenCalledTimes(2);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).toHaveBeenNthCalledWith(1, {
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenCalledTimes(1);
  });

  test("keeps deletion retryable when Stripe cleanup mutates billing before failing", async () => {
    selectResults = [
      [{ id: "sub_user_active" }],
      [{ id: "cus_user" }],
    ];
    stripeDeleteCustomerError = new Error("stripe unavailable");

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 0,
    });
    expect(cancelledStripeSubscriptions).toEqual(["sub_user_active"]);
    expect(deletedStripeCustomers).toEqual(["cus_user"]);
    expect(listUserVms).not.toHaveBeenCalled();
    expect(transaction).toHaveBeenCalledTimes(2);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).toHaveBeenNthCalledWith(1, {
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenCalledTimes(1);
  });

  test("keeps deletion retryable when a Stripe cancellation attempt is ambiguous", async () => {
    selectResults = [
      [{ id: "sub_user_active" }],
      [],
    ];
    stripeCancelError = new Error("request timed out after reaching Stripe");

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 0,
    });
    expect(cancelledStripeSubscriptions).toEqual(["sub_user_active"]);
    expect(listUserVms).not.toHaveBeenCalled();
    expect(transaction).toHaveBeenCalledTimes(2);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).toHaveBeenNthCalledWith(1, {
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenCalledTimes(1);
  });

  test("keeps deletion retryable when any VM was destroyed before a teardown error", async () => {
    destroyVmFailureProviderIds = new Set(["personal-vm-1"]);

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 1,
    });
    expect(destroyVm).toHaveBeenCalledTimes(2);
    expect(destroyVm).toHaveBeenCalledWith(expect.objectContaining({
      userId: "account-user-1",
      teamIds: ["account-user-1"],
      providerVmId: "personal-vm-1",
      provider: "freestyle",
    }));
    expect(destroyVm).toHaveBeenCalledWith(expect.objectContaining({
      userId: "account-user-1",
      teamIds: ["account-user-1"],
      providerVmId: "personal-vm-2",
      provider: "freestyle",
    }));
    expect(transaction).toHaveBeenCalledTimes(2);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).toHaveBeenNthCalledWith(1, {
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenCalledTimes(1);
    expect(consoleError).toHaveBeenCalledWith(
      "account.delete.vm_destroy_failed",
      "Error: destroy failed for personal-vm-1",
    );
    expect(consoleError).toHaveBeenCalledWith(
      "account.delete.partial_after_destructive_cleanup",
      "AccountDeletionDestructiveCleanupError: Failed to destroy 1 personal cloud VM",
    );
  });

  test("keeps deletion retryable when VM teardown may have reached the provider", async () => {
    destroyVmFailureProviderIds = new Set(["personal-vm-1", "personal-vm-2"]);

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 0,
    });
    expect(destroyVm).toHaveBeenCalledTimes(2);
    expect(destroyVm).toHaveBeenCalledWith(expect.objectContaining({
      userId: "account-user-1",
      teamIds: ["account-user-1"],
      providerVmId: "personal-vm-1",
      provider: "freestyle",
    }));
    expect(destroyVm).toHaveBeenCalledWith(expect.objectContaining({
      userId: "account-user-1",
      teamIds: ["account-user-1"],
      providerVmId: "personal-vm-2",
      provider: "freestyle",
    }));
    expect(transaction).toHaveBeenCalledTimes(2);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).toHaveBeenNthCalledWith(1, {
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenCalledTimes(1);
    expect(consoleError).toHaveBeenCalledWith(
      "account.delete.partial_after_destructive_cleanup",
      "AccountDeletionDestructiveCleanupError: Failed to destroy 2 personal cloud VMs",
    );
  });

  test("does not delete rows or Stack user when active billing cleanup cannot run", async () => {
    selectResults = [
      [{ id: "sub_user_active" }],
      [],
      [],
      [],
      [],
      [],
    ];
    stripeConfigured = false;

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 0,
    });
    expect(cancelSubscription).not.toHaveBeenCalled();
    expect(transaction).toHaveBeenCalledTimes(2);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(updateStackUser).toHaveBeenNthCalledWith(1, {
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenNthCalledWith(2, {
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
  });

  test("returns a retryable partial-failure response when Stack deletion fails after cmux data deletion", async () => {
    stackDeleteError = new Error(
      "raw eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhY2NvdW50LXVzZXItMSJ9.signaturePart leaked by upstream",
    );

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 2,
    });
    expect(transaction).toHaveBeenCalledTimes(3);
    expect(deletedTableCount).toBeGreaterThan(10);
    expect(updateStackUser).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(updateStackUser).toHaveBeenCalledTimes(1);
    expectPostHogAccountDeleteRequest();
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
    expect(tombstoneUpdates.some((values) =>
      (values as { readonly analyticsDeletedAt?: unknown }).analyticsDeletedAt instanceof Date
    )).toBe(true);
    expect(tombstoneUpdates.some((values) =>
      (values as { readonly status?: unknown; readonly errorMessage?: unknown }).status === "failed" &&
      (values as { readonly errorMessage?: unknown }).errorMessage === "Error: raw [redacted] leaked by upstream"
    )).toBe(true);
    expect(routeEvents).toEqual([
      "transaction",
      "transaction-lock",
      "tombstone-upsert",
      "transaction",
      "transaction-lock",
      "analytics-lease-cleanup",
      "posthog-delete",
      "metadata-update",
      "revoke-identities",
      "list-vms",
      "destroy-vm",
      "destroy-vm",
      "transaction",
      "transaction-lock",
      "stack-delete",
    ]);
    expect(consoleError).toHaveBeenCalledWith(
      "account.delete.stack_user_failed_after_data_delete",
      "Error: raw [redacted] leaked by upstream",
    );
  });

  test("returns accepted deletion when post-Stack cleanup fails after the account is deleted", async () => {
    postStackVaultDeleteError = new Error("post-delete vault unavailable");
    selectResults = [
      [],
      [],
      [],
      [],
      [],
      [],
      [],
      [],
      [],
      [],
      [{ id: "post-stack-session", latestObjectKey: "vault/u/account-user-1/post-stack-latest.jsonl.zst" }],
    ];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({
      ok: true,
      cleanupIncomplete: true,
      destroyedVms: 2,
    });
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
    expect(transaction).toHaveBeenCalledTimes(3);
    expect(tombstoneUpdates.some((values) =>
      (values as { readonly status?: unknown }).status === "completed"
    )).toBe(false);
    expect(tombstoneUpdates.some((values) =>
      (values as { readonly status?: unknown }).status === "failed"
    )).toBe(false);
    expect(tombstoneUpdates.some((values) =>
      (values as { readonly status?: unknown }).status === "cleanup_incomplete"
    )).toBe(true);
    expect(consoleError).toHaveBeenCalledWith(
      "account.delete.post_stack_cleanup_failed",
      "Error: post-delete vault unavailable",
    );
  });

  test("records Stack-delete phase before post-Stack cleanup-incomplete marking can fail", async () => {
    postStackVaultDeleteError = new Error("post-delete vault unavailable");
    tombstoneCleanupIncompleteError = new Error("tombstone unavailable");
    selectResults = [
      [],
      [],
      [],
      [],
      [],
      [],
      [],
      [],
      [],
      [],
      [{ id: "post-stack-session", latestObjectKey: "vault/u/account-user-1/post-stack-latest.jsonl.zst" }],
    ];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({
      ok: true,
      cleanupIncomplete: true,
      destroyedVms: 2,
    });
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
    const statusUpdates = tombstoneUpdates
      .map((values) => (values as { readonly status?: unknown }).status)
      .filter(Boolean);
    expect(statusUpdates).toContain("stack_delete_pending");
    expect(statusUpdates.indexOf("stack_delete_pending")).toBeLessThan(
      statusUpdates.indexOf("cleanup_incomplete"),
    );
    expect(consoleError).toHaveBeenCalledWith(
      "account.delete.post_stack_cleanup_mark_incomplete",
      "Error: tombstone unavailable",
    );
  });

  test("returns accepted deletion when tombstone completion fails after the account is deleted", async () => {
    tombstoneCompleteError = new Error("tombstone unavailable");

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({
      ok: true,
      cleanupIncomplete: true,
      destroyedVms: 2,
    });
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
    expect(tombstoneUpdates.some((values) =>
      (values as { readonly status?: unknown }).status === "failed"
    )).toBe(false);
    expect(tombstoneUpdates.some((values) =>
      (values as { readonly status?: unknown }).status === "cleanup_incomplete"
    )).toBe(true);
    expect(consoleError).toHaveBeenCalledWith(
      "account.delete.post_stack_cleanup_failed",
      "Error: tombstone unavailable",
    );
  });

  test("continues when Stripe resources are already in the deletion target state", async () => {
    selectResults = [
      [{ id: "sub_user_active" }],
      [{ id: "cus_user" }],
      [],
      [],
      [],
      [],
    ];
    stripeCancelError = new Error("This subscription has already been canceled");
    stripeDeleteCustomerError = { statusCode: 404, message: "No such customer" };

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, destroyedVms: 2 });
    expect(cancelledStripeSubscriptions).toEqual(["sub_user_active"]);
    expect(deletedStripeCustomers).toEqual(["cus_user"]);
    expect(transaction).toHaveBeenCalledTimes(4);
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
  });

  test("uses a single native Stack session lookup for deletion auth", async () => {
    stackUserIds = ["account-user-1", "other-user"];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(getUser).toHaveBeenCalledTimes(1);
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
  });
});

function accountDeletionRequest(): Request {
  return new Request("https://cmux.test/api/account", {
    method: "DELETE",
    headers: {
      authorization: "Bearer access-token",
      "x-stack-refresh-token": "refresh-token",
    },
  });
}

function stackUser(id = "account-user-1") {
  return {
    id,
    displayName: null,
    primaryEmail: "account@example.com",
    clientReadOnlyMetadata: { cmuxPlan: "pro" },
    selectedTeam: stackUserSelectedTeam,
    listTeams: async (options?: { readonly cursor?: string; readonly limit?: number }) =>
      typeof stackUserTeams === "function" ? await stackUserTeams(options) : stackUserTeams,
    update: updateStackUser,
    delete: deleteStackUser,
  };
}

function stackTeam(id: string, userIds: readonly string[]) {
  return {
    id,
    listUsers: async () => userIds.map((userId) => ({ id: userId })),
  };
}

function stackPage(items: readonly unknown[], nextCursor?: string | null): StackPage {
  const page = [...items] as unknown[] & { nextCursor?: string | null };
  if (nextCursor !== undefined) page.nextCursor = nextCursor;
  return page;
}

function stripUpdatedAt(values: unknown): Record<string, unknown> {
  const copy = { ...(values as Record<string, unknown>) };
  delete copy.updatedAt;
  return copy;
}

function conditionColumnNames(condition: unknown): string[] {
  const names: string[] = [];
  const visit = (value: unknown) => {
    if (!value || typeof value !== "object") return;
    const candidate = value as {
      readonly name?: unknown;
      readonly table?: unknown;
      readonly queryChunks?: readonly unknown[];
    };
    if (typeof candidate.name === "string" && candidate.table) {
      names.push(candidate.name);
    }
    if (Array.isArray(candidate.queryChunks)) {
      for (const chunk of candidate.queryChunks) visit(chunk);
    }
  };
  visit(condition);
  return names;
}

function isAccountDeletionVaultObject(objectKey: string): boolean {
  return objectKey.startsWith(`vault/u/${ACCOUNT_USER_ID}/`) ||
    objectKey.startsWith("vault/uploads/");
}

function isAccountDeletionWorkflowProgram(program: unknown): boolean {
  if (!program || typeof program !== "object") return false;
  const candidate = program as {
    readonly kind?: unknown;
    readonly userId?: unknown;
    readonly input?: { readonly userId?: unknown };
  };
  if (candidate.kind === "listUserVms") return candidate.userId === ACCOUNT_USER_ID;
  if (candidate.kind === "revokeUserIdentityLeasesForAccountDeletion") {
    return candidate.userId === ACCOUNT_USER_ID;
  }
  if (candidate.kind === "destroyVm") return candidate.input?.userId === ACCOUNT_USER_ID;
  return false;
}

function expectIdentityRevocationHeartbeatConfigured(): void {
  expect(lastRevokeIdentityCall?.userId).toBe(ACCOUNT_USER_ID);
  expect(typeof lastRevokeIdentityCall?.afterBatch).toBe("function");
}

function vmProviderOperationError(operation: string, message: string): Error & {
  _tag: "VmProviderOperationError";
  provider: ProviderId;
  operation: string;
  cause: Error;
} {
  const error = new Error(message) as Error & {
    _tag: "VmProviderOperationError";
    provider: ProviderId;
    operation: string;
    cause: Error;
  };
  error._tag = "VmProviderOperationError";
  error.provider = "freestyle";
  error.operation = operation;
  error.cause = new Error(message);
  return error;
}

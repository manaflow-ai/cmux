import { afterEach, describe, expect, test } from "bun:test";

import {
  createAuthenticatedWorkspaceProvisioner,
  configureRuntimeCompositionFromEnv,
  createRequestScopedWorkspaceService,
  installRuntimeComposition,
} from "../services/runtimeComposition";
import {
  configurePersistentWorkspaceService,
  persistentWorkspaceService,
  type PersistentWorkspaceProvider,
  type PersistentWorkspaceStore,
} from "../services/vms/persistentWorkspace";
import {
  installRunAttemptPromotionDependencies,
  runAttemptPromotionDependencies,
  type AttemptPromotionStorePort,
} from "../services/runs/promotion";

const savedEnv = {
  image: process.env.CMUX_PERSISTENT_WORKSPACE_IMAGE,
  leaseUrl: process.env.CMUX_RUNTIME_HOST_LEASE_URL,
  leaseToken: process.env.CMUX_RUNTIME_HOST_LEASE_TOKEN,
  worker: process.env.CMUX_RUNTIME_WORKER_ID,
  freestyleKey: process.env.FREESTYLE_API_KEY,
  freestyleStack: process.env.FREESTYLE_STACK_ACCESS_TOKEN,
  freestyleTeam: process.env.FREESTYLE_TEAM_ID,
};

const store = {} as PersistentWorkspaceStore;
const provider = {} as PersistentWorkspaceProvider;
const promotionStore = {} as AttemptPromotionStorePort;
const requestContext = {
  userId: "user-request-scoped",
  entitlements: {
    planId: "pro",
    billingCustomerType: "team" as const,
    billingTeamId: "team-request-scoped",
    maxActiveVms: 3,
    resourcePool: null,
  },
};

afterEach(() => {
  configurePersistentWorkspaceService(null);
  installRunAttemptPromotionDependencies(null);
  for (const [key, value] of Object.entries({
    CMUX_PERSISTENT_WORKSPACE_IMAGE: savedEnv.image,
    CMUX_RUNTIME_HOST_LEASE_URL: savedEnv.leaseUrl,
    CMUX_RUNTIME_HOST_LEASE_TOKEN: savedEnv.leaseToken,
    CMUX_RUNTIME_WORKER_ID: savedEnv.worker,
    FREESTYLE_API_KEY: savedEnv.freestyleKey,
    FREESTYLE_STACK_ACCESS_TOKEN: savedEnv.freestyleStack,
    FREESTYLE_TEAM_ID: savedEnv.freestyleTeam,
  })) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
});

describe("runtime composition", () => {
  test("installs both route dependency graphs from explicit adapters", () => {
    const composition = installRuntimeComposition({ workspaceStore: store, workspaceProvider: provider, promotionStore });
    expect(composition.workspaceService).toBe(persistentWorkspaceService());
    expect(composition.promotionDependencies).toBe(runAttemptPromotionDependencies());
  });

  test("keeps both seams disabled when credential-bearing config is incomplete", async () => {
    delete process.env.CMUX_PERSISTENT_WORKSPACE_IMAGE;
    delete process.env.CMUX_RUNTIME_HOST_LEASE_URL;
    delete process.env.CMUX_RUNTIME_HOST_LEASE_TOKEN;
    delete process.env.CMUX_RUNTIME_WORKER_ID;
    const result = await configureRuntimeCompositionFromEnv();
    expect(result.configured).toBe(false);
    expect(persistentWorkspaceService()).toBeNull();
    expect(() => runAttemptPromotionDependencies()).toThrow("not configured");
  });

  test("builds a request-scoped service without mutating the global seam", () => {
    const scopedProvider = { create: async () => ({ providerVmId: "vm", providerWorkspaceId: "workspace" }) } as unknown as PersistentWorkspaceProvider;
    let receivedContext: unknown;
    const service = createRequestScopedWorkspaceService({
      context: requestContext,
      workspaceStore: store,
      providerFactory: (context) => {
        receivedContext = context;
        return scopedProvider;
      },
    });

    expect(service).not.toBeNull();
    expect(receivedContext).toBe(requestContext);
    expect(persistentWorkspaceService()).toBeNull();
  });

  test("returns null when no request-scoped provider adapter is installed", () => {
    const service = createRequestScopedWorkspaceService({
      context: requestContext,
      workspaceStore: store,
      providerFactory: () => null,
    });

    expect(service).toBeNull();
    expect(persistentWorkspaceService()).toBeNull();
  });

  test("rejects incomplete scope before asking the provider factory", () => {
    let called = false;
    expect(() => createRequestScopedWorkspaceService({
      context: { ...requestContext, userId: " " },
      workspaceStore: store,
      providerFactory: () => {
        called = true;
        return null;
      },
    })).toThrow("request-scoped workspace context is incomplete");
    expect(called).toBe(false);
  });

  test("maps resolved entitlements into the authenticated createVm workflow", async () => {
    let captured: unknown;
    const provision = createAuthenticatedWorkspaceProvisioner({
      context: requestContext,
      provider: "freestyle",
      resolveImage: () => ({ image: "cmux-base", imageVersion: "v1" }),
      createVm: async (input) => {
        captured = input;
        return { providerVmId: "vm-1" };
      },
    });
    await provision(requestContext, {
      runtimeId: "runtime-1",
      workspaceId: "workspace-1",
      tenantId: "team-request-scoped",
      ownerId: "user-request-scoped",
      generation: 1,
      effectKey: "effect-1",
      workspaceName: "review",
      workspaceKey: "workspace-key",
      providerInput: { memoryMb: 8192 },
    } as never);
    expect(captured).toMatchObject({
      userId: "user-request-scoped",
      billingTeamId: "team-request-scoped",
      billingPlanId: "pro",
      provider: "freestyle",
      image: "cmux-base",
      imageVersion: "v1",
      memoryMb: 8192,
      perMachineHome: true,
      idempotencyKey: "runtime-1",
    });
  });
});

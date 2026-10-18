import { afterEach, describe, expect, test } from "bun:test";

import {
  configureRuntimeCompositionFromEnv,
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

  test("keeps both seams disabled when credential-bearing config is incomplete", () => {
    delete process.env.CMUX_PERSISTENT_WORKSPACE_IMAGE;
    delete process.env.CMUX_RUNTIME_HOST_LEASE_URL;
    delete process.env.CMUX_RUNTIME_HOST_LEASE_TOKEN;
    delete process.env.CMUX_RUNTIME_WORKER_ID;
    const result = configureRuntimeCompositionFromEnv();
    expect(result.configured).toBe(false);
    expect(persistentWorkspaceService()).toBeNull();
    expect(() => runAttemptPromotionDependencies()).toThrow("not configured");
  });
});

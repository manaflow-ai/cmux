import { afterEach, describe, expect, mock, test } from "bun:test";

// The Run worker records only a redacted error, so a session-setup failure on
// staging read "could not open the owner's Cloud session" with no hint of
// which call failed. Each setup step must name itself without carrying the
// provider's raw message.
type FakeUser = { createSession: (options: unknown) => Promise<{ getTokens: () => Promise<{ accessToken?: string; refreshToken?: string }> }> };
let user: FakeUser | null = null;

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser: async () => user }),
}));

const { runCloudClient, runCloudOrigin, RunSessionSetupError } = await import("../services/runs/cloudClient");
const { projects } = await import("../scripts/cloud-vm/projects.mjs");
const savedUrl = process.env.VERCEL_PROJECT_PRODUCTION_URL;
const savedProject = process.env.VERCEL_PROJECT_ID;

afterEach(() => {
  user = null;
  if (savedUrl === undefined) delete process.env.VERCEL_PROJECT_PRODUCTION_URL;
  else process.env.VERCEL_PROJECT_PRODUCTION_URL = savedUrl;
  if (savedProject === undefined) delete process.env.VERCEL_PROJECT_ID;
  else process.env.VERCEL_PROJECT_ID = savedProject;
});

async function setupStage(): Promise<string> {
  try {
    await runCloudClient("user-1", "team-1");
  } catch (error) {
    expect(error).toBeInstanceOf(RunSessionSetupError);
    const setup = error as InstanceType<typeof RunSessionSetupError>;
    expect(setup.message).not.toContain("provider secret detail");
    return setup.stage;
  }
  throw new Error("runCloudClient unexpectedly succeeded");
}

const tokens = (value: { accessToken?: string; refreshToken?: string }) => async () => ({ getTokens: async () => value });

describe("Run worker Cloud session setup", () => {
  test("names the owner lookup when the owner is gone", async () => {
    user = null;
    expect(await setupStage()).toBe("owner-lookup");
  });

  test("names session creation when Stack refuses the impersonation session", async () => {
    user = { createSession: async () => { throw new Error("provider secret detail"); } };
    expect(await setupStage()).toBe("session-create");
  });

  test("names the token step when the session has no token pair", async () => {
    user = { createSession: tokens({ accessToken: "a" }) };
    expect(await setupStage()).toBe("session-tokens");
  });

  test("names the Cloud origin when the deployment URL is not recognized", async () => {
    delete process.env.VERCEL_PROJECT_ID;
    process.env.VERCEL_PROJECT_PRODUCTION_URL = "staging.example.invalid";
    user = { createSession: tokens({ accessToken: "a", refreshToken: "r" }) };
    expect(await setupStage()).toBe("cloud-origin");
  });

  test("returns a client when every step succeeds", async () => {
    process.env.VERCEL_PROJECT_PRODUCTION_URL = "cmux-staging.vercel.app";
    user = { createSession: tokens({ accessToken: "a", refreshToken: "r" }) };
    expect(typeof await runCloudClient("user-1", "team-1")).toBe("function");
  });
});

// Staging dogfood run 39356945500 failed at cloud-origin: Vercel sets
// VERCEL_PROJECT_PRODUCTION_URL to the project's shortest production domain,
// which on staging is not cmux-staging.vercel.app. The project ID is fixed per
// deployment, so it picks the origin the Cloud ops scripts already use.
describe("Run worker Cloud origin", () => {
  test("each Cloud project resolves to its ops origin whatever its production domain", () => {
    for (const project of Object.values(projects)) {
      process.env.VERCEL_PROJECT_ID = project.projectId;
      process.env.VERCEL_PROJECT_PRODUCTION_URL = "some-custom-domain.example";
      expect(runCloudOrigin()).toBe(project.url);
    }
  });

  test("an unknown project never takes its origin from the production domain", () => {
    process.env.VERCEL_PROJECT_PRODUCTION_URL = "cmux-staging.vercel.app";
    for (const project of ["prj_unknown", "constructor", "__proto__", "toString"]) {
      process.env.VERCEL_PROJECT_ID = project;
      expect(() => runCloudOrigin()).toThrow();
    }
  });
});

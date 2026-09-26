import production, { TeamControl as ProductionTeamControl, UserUsage as ProductionUserUsage } from "../src/index";
import type { Environment } from "../src/environment";
import { TeamStore } from "../src/storage/team-store";
import { objectName } from "../src/routing";

const TEAM_ID = "team-control";

/** Test-only fixture. It seeds the local TeamStore and leaves all routing/auth code production. */
export class TestTeamControl extends ProductionTeamControl {
  constructor(ctx: DurableObjectState, env: Environment) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      const fixtureEnv = env as Environment & { FIXTURE_ENDPOINT_ID: string };
      const identity = {
        environment: env.ENVIRONMENT,
        projectId: env.STACK_PROJECT_ID,
        teamId: TEAM_ID,
        userId: "control-user",
        deviceId: "control-device",
        appNamespace: "cmux",
        buildTag: "test",
      };
      const descriptor = {
        identity,
        endpointId: fixtureEnv.FIXTURE_ENDPOINT_ID,
        identityGeneration: 0,
        metadata: {
          platform: "mac" as const,
          displayName: "Control fixture",
          appVersion: "1",
          pairingEnabled: true,
          capabilities: ["directory", "relay"],
          relayURLs: ["https://relay.test"],
        },
      };
      const store = new TeamStore(ctx.storage, {
        environment: env.ENVIRONMENT,
        projectId: env.STACK_PROJECT_ID,
        teamId: TEAM_ID,
      }, { initialize: false });
      store.initialize();
      if (!store.getDevice(identity)) {
        store.issueChallenge(identity, {
          challengeId: "control-fixture-challenge",
          nonceHash: "control-fixture-nonce",
          payloadHash: "control-fixture-payload",
          issuedAt: 1,
          expiresAt: 2_000_000_000,
        });
        store.commitRegistration({
          descriptor,
          challengeId: "control-fixture-challenge",
          nonceHash: "control-fixture-nonce",
          payloadHash: "control-fixture-payload",
          requestId: "control-fixture-registration",
          requestHash: "control-fixture-request",
          now: 2,
        });
      }
    });
  }
}

export class TestUserUsage extends ProductionUserUsage {}

export default {
  fetch(request: Request, env: Environment, ctx: ExecutionContext) {
    if (new URL(request.url).pathname !== "/fixture/stack/socket") return production.fetch(request, env, ctx);
    // Only the local test entrypoint supplies a verified Stack result. The
    // Durable Object's enrollment, delivery and socket code are production.
    const now = Math.floor(Date.now() / 1000);
    const forwarded = new Request("https://iroh-v2.internal/socket", {
      headers: { upgrade: "websocket", "x-cmux-v2-setup": request.headers.get("x-cmux-v2-setup")!,
        "x-cmux-v2-verified-authority": JSON.stringify({
          authority: { environment: env.ENVIRONMENT, projectId: env.STACK_PROJECT_ID, teamId: TEAM_ID, userId: "control-user", verifiedAt: now },
          expiresAt: now + 3600, issueTicket: true,
        }) },
    });
    return env.TEAM_CONTROL.getByName(objectName(env.ENVIRONMENT, env.STACK_PROJECT_ID, TEAM_ID)).fetch(forwarded);
  },
};

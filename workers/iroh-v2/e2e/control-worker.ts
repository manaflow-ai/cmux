import production, { TeamControl as ProductionTeamControl, UserUsage as ProductionUserUsage } from "../src/index";
import type { Environment } from "../src/environment";
import { TEAM_ID_STORAGE_KEY } from "../src/team-control";
import { TeamStore } from "../src/storage/team-store";

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

  async fetch(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (path === "/__test/retention/seed") {
      const now = Math.floor(Date.now() / 1000);
      const store = new TeamStore(this.ctx.storage, {
        environment: this.env.ENVIRONMENT,
        projectId: this.env.STACK_PROJECT_ID,
        teamId: TEAM_ID,
      }, { initialize: false });
      await this.ctx.storage.put(TEAM_ID_STORAGE_KEY, TEAM_ID);
      const identity = {
        environment: this.env.ENVIRONMENT,
        projectId: this.env.STACK_PROJECT_ID,
        teamId: TEAM_ID,
        userId: "retention-user",
        deviceId: "retention-device",
        appNamespace: "cmux",
        buildTag: "test",
      };
      store.issueChallenge(identity, {
        challengeId: "retention-expired",
        nonceHash: "retention-expired-nonce",
        payloadHash: "retention-expired-payload",
        issuedAt: now - 120,
        expiresAt: now - 60,
      });
      store.issueChallenge({ ...identity, deviceId: "retention-live-device" }, {
        challengeId: "retention-live",
        nonceHash: "retention-live-nonce",
        payloadHash: "retention-live-payload",
        issuedAt: now,
        expiresAt: now + 60,
      });
      return Response.json({ now });
    }
    if (path === "/__test/retention/alarm") {
      await this.alarm();
      const store = new TeamStore(this.ctx.storage, {
        environment: this.env.ENVIRONMENT,
        projectId: this.env.STACK_PROJECT_ID,
        teamId: TEAM_ID,
      }, { initialize: false });
      return Response.json({ nextExpiresAt: store.nextRetentionAt(), alarm: await this.ctx.storage.getAlarm() });
    }
    return super.fetch(request);
  }
}

export class TestUserUsage extends ProductionUserUsage {}

export default production;

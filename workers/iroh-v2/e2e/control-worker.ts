import production, { TeamControl as ProductionTeamControl, UserUsage as ProductionUserUsage } from "../src/index";
import type { Environment } from "../src/environment";
export { AccountControl } from "../src/index";
import { TeamStore } from "../src/storage/team-store";
import { objectName } from "../src/routing";
import { TEAM_SOCKET_LIMIT } from "../src/team-control";

const TEAM_ID = "team-control";

/** Test-only fixture. It seeds the local TeamStore and leaves all routing/auth code production. */
export class TestTeamControl extends ProductionTeamControl {
  #socketLimit = TEAM_SOCKET_LIMIT;

  protected override socketLimit(): number { return this.#socketLimit; }

  /** Test-only: 4096 live sockets are not reachable here, so the suite lowers the cap instead. */
  setSocketLimit(limit: number): void { this.#socketLimit = limit; }
  restoreSocketLimit(): void { this.#socketLimit = TEAM_SOCKET_LIMIT; }

  /** Test-only: the team revision without a socket round trip, so cap tests can read it directly. */
  teamRevision(): number {
    return new TeamStore(this.ctx.storage, {
      environment: this.env.ENVIRONMENT, projectId: this.env.STACK_PROJECT_ID, teamId: TEAM_ID,
    }, { initialize: false }).readRevision();
  }

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

/**
 * The output budget call is a Durable Object RPC, so a control object is parked
 * while it runs and other events reach that object in the meantime. Production
 * code cannot be asked to stall, so the fixture stalls one budget call on
 * request. That lets a test land an ordinary mutation inside the window instead
 * of racing it, and keeps the delivery code under test production.
 */
export class TestUserUsage extends ProductionUserUsage {
  private stallMilliseconds = 0;

  armOutputStall(milliseconds: number): void { this.stallMilliseconds = milliseconds; }

  // Durable Object RPC awaits whatever a method returns, so returning a promise
  // where production returns a value changes nothing for the caller.
  setOutput(userId: string, sessionId: string, revision: number, bytes: number, messages: number): ReturnType<ProductionUserUsage["setOutput"]> {
    const stall = this.stallMilliseconds;
    if (stall <= 0) return super.setOutput(userId, sessionId, revision, bytes, messages);
    this.stallMilliseconds = 0;
    const stalled = new Promise<void>(resolve => setTimeout(resolve, stall))
      .then(() => super.setOutput(userId, sessionId, revision, bytes, messages));
    return stalled as unknown as ReturnType<ProductionUserUsage["setOutput"]>;
  }
}

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

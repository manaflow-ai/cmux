import { expect, test } from "bun:test";
import { TeamBroker, type BrokerDependencies } from "../src/broker";
import type { DashboardClaims } from "../src/dashboard-auth";

const authority = {
  environment: "staging",
  projectId: "project",
  teamId: "team",
  userId: "user",
  verifiedAt: 1000,
} as const;
const directoryRequest = { schemaId: "directory.request.v1", requestId: "directory" } as const;

function fixture() {
  let member = true;
  let manager = true;
  const managerArguments: boolean[] = [];
  const dependencies = {
    store: {
      readRevision: () => 1,
      getRelayPreferences: () => ({ relayURLs: [], revision: 1 }),
      listDashboardDevices: (_userId: string, canManageTeam: boolean) => {
        managerArguments.push(canManageTeam);
        return [];
      },
    },
    ownership: { reserve: async () => {} },
    relays: { configuration: { relayURLs: ["https://relay.example/"] } },
    now: () => 1100,
    charge: async () => {},
    issueTicket: async () => ({ token: "ticket", expiresAt: 4600, refreshAfter: 4300 }),
    verifyStack: async () => ({ ...authority }),
    canManageTeam: async () => manager,
    verifyTeamMember: async () => member,
  } as unknown as BrokerDependencies;
  const session: DashboardClaims = {
    version: 2,
    audience: "cmux-iroh-dashboard-v2",
    authority,
    origin: "https://cmux.com",
    clientInstanceId: "tab",
    canManageTeam: true,
    expiresAt: 4600,
    keyId: "key-1",
  };
  return {
    broker: new TeamBroker(dependencies),
    session,
    managerArguments,
    removeMember: () => { member = false; },
    demote: () => { manager = false; },
  };
}

test("dashboard uses current management rights after demotion", async () => {
  const fixtureValue = fixture();

  const first = await fixtureValue.broker.executeDashboard(fixtureValue.session, directoryRequest);
  expect(first.response.schemaId).toBe("dashboard.directory.v1");
  expect(fixtureValue.managerArguments.at(-1)).toBe(true);

  fixtureValue.demote();
  const afterDemotion = await fixtureValue.broker.executeDashboard(fixtureValue.session, {
    ...directoryRequest,
    requestId: "after-demotion",
  });
  expect(afterDemotion.response.schemaId).toBe("dashboard.directory.v1");
  if (afterDemotion.response.schemaId === "dashboard.directory.v1") {
    expect(afterDemotion.response.directory.canManageTeam).toBe(false);
  }
  expect(fixtureValue.managerArguments.at(-1)).toBe(false);

});

test("dashboard rejects a removed member even with an old ticket", async () => {
  const fixtureValue = fixture();
  fixtureValue.removeMember();
  await expect(fixtureValue.broker.executeDashboard(fixtureValue.session, {
    ...directoryRequest,
    requestId: "removed-member",
  })).rejects.toMatchObject({ code: "team_access_revoked" });
});

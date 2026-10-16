import { afterAll, beforeAll, expect, test } from "bun:test";
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { encodeResponse } from "../src/boundary";
import { CONTROL_PLANE_RULES } from "../src/rules";
import { deterministicRandom, descriptor, deviceKey, identity, teamHarness } from "./support/team-fixture";

/**
 * Byte-for-byte team wire responses that existing iOS and Mac clients parse,
 * captured from main before the account directory existed. Any change to these
 * frames, the published rules or an existing generated contract is a protocol
 * change for shipped clients and fails here.
 *
 * Regenerate only for a deliberate, reviewed protocol change:
 *   UPDATE_TEAM_WIRE_GOLDEN=1 bun test ./test/team-wire-golden.test.ts
 */
const goldenPath = resolve(import.meta.dir, "fixtures/team-wire-golden.json");
const generatedRoot = resolve(import.meta.dir, "../generated");
const NOW = 1_800_000_000;
let restore: () => void;

beforeAll(() => { restore = deterministicRandom(); });
afterAll(() => restore());

async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
}

async function captureFrames(): Promise<Record<string, string>> {
  const now = () => NOW;
  const team = await teamHarness("team-x", now);
  const [macAKey, macBKey, phoneKey, teammateKey, newMacKey] = await Promise.all([11, 12, 13, 14, 15].map(deviceKey));
  const macA = descriptor(macAKey!, identity("team-x", "user-u", "mac-a"), "mac", ["cmux.mac-host.v1", "cmux.mac-devices.v1"]);
  const macB = descriptor(macBKey!, identity("team-x", "user-u", "mac-b"), "mac", ["cmux.mac-devices.v1"], false);
  const phone = descriptor(phoneKey!, identity("team-x", "user-u", "iphone"), "ios", []);
  const teammate = descriptor(teammateKey!, identity("team-x", "user-t", "mac-t"), "mac", ["cmux.mac-host.v1", "cmux.mac-devices.v1"]);
  const newMac = descriptor(newMacKey!, identity("team-x", "user-u", "mac-new"), "mac", ["cmux.mac-host.v1"]);
  for (const device of [macA, macB, phone, teammate]) team.enroll(device, NOW - 100);
  team.store.observeAuthority("user-u", NOW - 50, NOW - 50 + 3600, NOW);
  team.store.observeAuthority("user-t", NOW - 40, NOW - 40 + 3600, NOW);

  const frames: Record<string, string> = {};
  const macReady = await team.broker.open(await team.openSetup(macAKey!, macA, "open-mac", NOW), team.authority(macA.identity, NOW - 20), NOW + 3580, true);
  frames["session.ready.v1/mac-stack"] = encodeResponse(macReady.response);
  const phoneReady = await team.broker.open(await team.openSetup(phoneKey!, phone, "open-phone", NOW), team.authority(phone.identity, NOW - 20), NOW + 3580, false);
  frames["session.ready.v1/ios-ticket"] = encodeResponse(phoneReady.response);
  for (const [name, device] of [["mac-host", macA], ["mac-devices", macB], ["ios", phone], ["teammate", teammate]] as const) {
    const result = await team.broker.execute(team.session(device, NOW - 10), { schemaId: "directory.request.v1", requestId: `directory-${name}` });
    frames[`directory.result.v1/${name}`] = encodeResponse(result.response);
  }
  const newSession = team.session(newMac, NOW - 5);
  const challenge = await team.broker.execute(newSession, { schemaId: "challenge.request.v1", requestId: "challenge-new", device: newMac });
  frames["challenge.result.v1"] = encodeResponse(challenge.response);
  if (challenge.response.schemaId !== "challenge.result.v1") throw new Error("expected a challenge");
  const { challengeId, nonce } = challenge.response.challenge;
  const registered = await team.broker.execute(newSession, {
    schemaId: "device.register.v1", requestId: "register-new", device: newMac, challengeId, nonce,
    signature: await team.registerSignature(newMacKey!, newMac, challengeId, nonce),
  });
  frames["device.registered.v1"] = encodeResponse(registered.response);
  const ticket = await team.broker.execute(team.session(macA, NOW - 5), { schemaId: "ticket.request.v1", requestId: "ticket-mac", stackAccessToken: "stack-token" });
  frames["ticket.result.v1"] = encodeResponse(ticket.response);
  const relay = await team.broker.execute(team.session(phone, NOW - 5), { schemaId: "relay.request.v1", requestId: "relay-phone" });
  frames["relay.result.v1"] = encodeResponse(relay.response);
  const directoryAfter = await team.broker.execute(team.session(phone, NOW - 5), { schemaId: "directory.request.v1", requestId: "directory-ios-after" });
  frames["directory.result.v1/ios-after-register"] = encodeResponse(directoryAfter.response);
  return frames;
}

/** Every generated contract that shipped before the account directory, by content hash. */
async function generatedContracts(names?: string[]): Promise<Record<string, string>> {
  const files = names ?? readdirSync(generatedRoot).filter(name => name.endsWith(".schema.json")).sort();
  const result: Record<string, string> = {};
  for (const name of files) result[name] = await sha256(readFileSync(resolve(generatedRoot, name), "utf8"));
  return result;
}

test("team wire responses, rules and existing generated contracts are byte-for-byte unchanged", async () => {
  const frames = await captureFrames();
  if (process.env.UPDATE_TEAM_WIRE_GOLDEN === "1") {
    writeFileSync(goldenPath, JSON.stringify({ rules: [...CONTROL_PLANE_RULES], frames, generatedContracts: await generatedContracts() }, null, 2) + "\n");
  }
  const golden = JSON.parse(readFileSync(goldenPath, "utf8")) as { rules: string[]; frames: Record<string, string>; generatedContracts: Record<string, string> };
  expect([...CONTROL_PLANE_RULES]).toEqual(golden.rules);
  expect(Object.keys(frames)).toEqual(Object.keys(golden.frames));
  for (const [name, text] of Object.entries(golden.frames)) expect({ name, text: frames[name] }).toEqual({ name, text });
  expect(await generatedContracts(Object.keys(golden.generatedContracts))).toEqual(golden.generatedContracts);
});

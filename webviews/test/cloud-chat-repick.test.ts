// Leo, 2026-10-31: he "picked zesty-indigo-lemur in the machine picker, but the chat stayed on
// sr2-tunnel-probe (the location menu's top row and the tab title still show sr2-tunnel-probe) and
// failed again". A Cloud chat whose first send has not run moves to the Cloud machine picked, and its
// first prompt is sent again there (`cloud.repickChat`); any other pick does what it did before.
import { expect, test } from "bun:test";
import { repickCloudChat, repickMachine } from "../src/agent-session/acpmux/cloudRepick";

const rows = [
  { id: "local", label: "This Mac", kind: "local" as const },
  { id: "sr2-tunnel-probe", label: "sr2-tunnel-probe", kind: "cloud" as const },
  { id: "devbox", label: "devbox", kind: "ssh" as const },
  {
    id: "cloud-machine:m_zesty",
    label: "zesty-indigo-lemur",
    kind: "cloud" as const,
    cloudMachine: { id: "m_zesty", name: "zesty-indigo-lemur", stage: "ready" },
  },
  { id: "teal-otter", label: "teal-otter", kind: "cloud" as const },
];

test("a pick of another Cloud machine moves the chat there; the account's row by id, acpmux's by name", () => {
  expect(repickMachine(rows, "cloud-machine:m_zesty", "sr2-tunnel-probe")).toEqual({ machine: "m_zesty" });
  expect(repickMachine(rows, "teal-otter", "sr2-tunnel-probe")).toEqual({ name: "teal-otter" });
});

test("the machine it is on, this Mac, an SSH machine or an unknown row is no move", () => {
  expect(repickMachine(rows, "sr2-tunnel-probe", "sr2-tunnel-probe")).toBeUndefined();
  expect(repickMachine(rows, "local", "sr2-tunnel-probe")).toBeUndefined();
  expect(repickMachine(rows, "devbox", "sr2-tunnel-probe")).toBeUndefined();
  expect(repickMachine(rows, "action:connect", "sr2-tunnel-probe")).toBeUndefined();
});

test("the app's answer: taken when it moved or ran the move, else the pick goes on as before", async () => {
  const asked: [string, Record<string, unknown>][] = [];
  const ok = async (method: string, params: Record<string, unknown>) => {
    asked.push([method, params]);
    return { machine: "zesty-indigo-lemur" };
  };
  expect(await repickCloudChat(ok, { machine: "m_zesty" })).toBe(true);
  expect(asked).toEqual([["cloud.repickChat", { machine: "m_zesty" }]]);
  const failing = (code: string) => async () => {
    throw { code, message: code };
  };
  // The move ran and failed: the app said why in its toast; no new empty chat on top.
  expect(await repickCloudChat(failing("cloud_start_failed"), { name: "teal-otter" })).toBe(true);
  // Not a chat a Cloud start opened (a relaunched app), an older app, no gesture: as before.
  for (const code of ["not_a_cloud_start", "unsupported", "transport.gesture_required", "cloud_disabled"])
    expect(await repickCloudChat(failing(code), { name: "teal-otter" })).toBe(false);
});

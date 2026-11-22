import { expect, test } from "bun:test";
import { leaders } from "./leads";

const row = (sessionId: string, extra: Record<string, unknown> = {}) => ({
  sessionId,
  name: sessionId,
  status: "idle",
  ...extra,
});
const reportsTo = (id: string) => ({ tags: { "lane.reportsTo": id } });
const names = (sessions: Parameters<typeof leaders>[0]) =>
  leaders(sessions).map((lead) => [lead.entry.name, lead.reports.map((r) => r.name)]);

test("a leader is a live chat live lanes report to, listed once, most reports first", () => {
  expect(
    names([
      row("coord"),
      row("owner"),
      row("lone"),
      row("a", reportsTo("owner")),
      row("b", { ...reportsTo("owner"), status: "running" }),
      row("c", reportsTo("coord")),
    ]),
  ).toEqual([
    ["owner", ["a", "b"]],
    ["coord", ["c"]],
  ]);
});

test("closed lanes and closed or archived leaders do not count", () => {
  expect(
    names([
      row("gone", { status: "closed" }),
      row("x", reportsTo("gone")),
      row("owner"),
      row("done", { ...reportsTo("owner"), status: "closed" }),
      row("shelved", { tags: { archived: "1" } }),
      row("y", reportsTo("shelved")),
    ]),
  ).toEqual([]);
});

test("a lane names its leader on its own machine: the same bare id on another peer is another chat", () => {
  expect(
    names([
      row("lead", { peer: "huge-blue", name: "hb-lead" }),
      row("lead", { name: "here" }),
      row("lane", { ...reportsTo("lead"), peer: "huge-blue" }),
    ]),
  ).toEqual([["hb-lead", ["lane"]]]);
});

test("a chat tagged as reporting to itself leads nothing", () => {
  expect(names([row("self", reportsTo("self"))])).toEqual([]);
});

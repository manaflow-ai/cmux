import { expect, test } from "bun:test";
import { leaderCards } from "./leaderCards";
import type { NewTabTranslate } from "./strings";

const nt: NewTabTranslate = (key, values) => (key === "leads.reports" ? `${values?.count} reporting` : key);

test("leader rows expose the correct machine and the number of direct reports needing input", () => {
  const cards = leaderCards(
    [
      { sessionId: "owner", name: "cloud-owner", peer: "huge-blue", status: "idle", indicator: "input" },
      { sessionId: "owner", name: "local-owner", status: "idle" },
      { sessionId: "lane-1", name: "review", peer: "huge-blue", status: "idle", indicator: "input", tags: { "lane.reportsTo": "owner" } },
      { sessionId: "lane-2", name: "test", peer: "huge-blue", status: "running", indicator: "working", tags: { "lane.reportsTo": "owner" } },
      { sessionId: "lane-3", name: "local", status: "idle", tags: { "lane.reportsTo": "owner" } },
    ],
    nt,
  );
  expect(cards).toHaveLength(2);
  expect(cards.find((card) => card.peer === "huge-blue")).toMatchObject({
    id: "owner",
    title: "cloud-owner",
    location: "huge-blue",
    needsInput: 2,
    state: "input",
    label: "2 reporting",
  });
  expect(cards.find((card) => !card.peer)).toMatchObject({
    id: "owner",
    title: "local-owner",
    label: "1 reporting",
  });
  expect(cards.find((card) => !card.peer)?.needsInput).toBeUndefined();
});

test("archived and closed lanes cannot inflate leader attention", () => {
  const cards = leaderCards(
    [
      { sessionId: "owner", name: "owner", status: "idle" },
      { sessionId: "live", status: "idle", indicator: "working", tags: { "lane.reportsTo": "owner" } },
      { sessionId: "gone", status: "closed", indicator: "input", tags: { "lane.reportsTo": "owner" } },
      { sessionId: "archived", status: "idle", indicator: "input", tags: { "lane.reportsTo": "owner", archived: "1" } },
    ],
    nt,
  );
  expect(cards).toHaveLength(1);
  expect(cards[0]?.needsInput).toBeUndefined();
  expect(cards[0]?.label).toBe("1 reporting");
});

import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Lineage } from "./Lineage";
import type { Subagent } from "./subagentFold";

const NOW = Date.now();
const agent = (id: string, parent: string | null, state = "running", startedAt = NOW - 10_000): Subagent => ({
  id,
  parent,
  name: `Branch ${id}`,
  state,
  startedAt,
  ...(state !== "running" && { endedAt: startedAt + 4_000 }),
});

const AGENTS = [
  agent("A", null, "running", NOW - 17_000),
  agent("B", null, "completed", NOW - 15_000),
  agent("C", null, "running", NOW - 12_000),
  agent("C1", "C", "completed"),
  agent("C2", "C", "failed"),
  agent("C3", "C", "running"),
];

const markup = (current?: string) =>
  renderToStaticMarkup(<Lineage agents={AGENTS} current={current} chat="Fetch audit" onOpen={() => undefined} />);
const names = (html: string) => [...html.matchAll(/acpmux-lineage__name">([^<]*)</g)].map((match) => match[1]);

test("the chat's lineage lists its running subagents, newest first, and folds the ended ones", () => {
  const html = markup();
  expect(html).toContain("Lineage · 2 running");
  expect(names(html)).toEqual(["Branch C", "Branch A"]);
  expect(html).toContain("Previous agents (1)");
  expect(html).toContain('aria-expanded="false"');
});

test("a subagent's lineage starts at its parent, then its own subagents", () => {
  const nested = markup("C");
  expect(nested).toContain("Lineage · 1 running");
  expect(names(nested)).toEqual(["Fetch audit", "Branch C3"]);
  expect(nested).toContain("Previous agents (2)");

  const leaf = markup("C1");
  expect(leaf).toContain(">Lineage<");
  expect(names(leaf)).toEqual(["Branch C"]);
  expect(leaf).not.toContain("Previous agents");
});

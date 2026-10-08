import { expect, test } from "bun:test";
import { AGENT_PANE_PAGE } from "./latency/actions";

test("agent pane latency actions wait for menus to appear", async () => {
  expect(AGENT_PANE_PAGE.path).toBe("/test/latency/agent-pane.html?mock");
  const noop = new Proxy((async () => undefined) as unknown as object, { get: () => noop });
  const predicates = await Promise.all(
    AGENT_PANE_PAGE.actions.map((action) => action.prepare(noop as never)),
  );
  expect(predicates).toEqual([
    'document.querySelector(".acpmux-model .acpmux-menu") !== null',
    'document.querySelector(".acpmux-slash-menu") !== null',
  ]);
});

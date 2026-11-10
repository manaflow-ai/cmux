import { expect, test } from "bun:test";
import { gridOrder } from "./ExtensionWidgets";

test("the widget row follows the person's layout, then the rest in their default order", () => {
  const clock = "app:manaflow-ai/clock#cmux.newtab.widget/1";
  const prs = "app:samples/github-prs#cmux.newtab.widget/1";
  expect(gridOrder(["warmGreeting", "timer", clock, prs], [])).toEqual(["warmGreeting", "timer", clock, prs]);
  expect(gridOrder(["warmGreeting", "timer", clock, prs], [prs, "timer", clock])).toEqual([
    prs,
    "timer",
    clock,
    "warmGreeting",
  ]);
  // A layout entry nothing draws (an uninstalled app, a widget turned off) holds no place.
  expect(gridOrder(["quote", clock], ["app:gone/app#cmux.newtab.widget/1", clock])).toEqual([clock, "quote"]);
});

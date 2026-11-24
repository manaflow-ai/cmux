// cmux-web-test-timeout: 300
// The visible-lists harness's typing step types the query from its first key: one counted step on
// a list with a filter field leaves the field starting with the query's first character, and a
// query's worth of steps leaves the whole query. Measured on a production build in Chromium
// (test/support/visibleLists.ts).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { startVisibleLists, type VisibleListsServer } from "./support/visibleLists";

await requireBrowserLane("visible-lists-harness-typing.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  let server: VisibleListsServer;
  beforeAll(async () => {
    server = await startVisibleLists();
  });
  afterAll(async () => {
    await server?.stop();
  });

  const typed = (open: Awaited<ReturnType<VisibleListsServer["open"]>>) =>
    open.page.evaluate(
      () =>
        (
          (
            window as unknown as { __visibleListControls: { filter(): HTMLInputElement } }
          ).__visibleListControls.filter() as HTMLInputElement | undefined
        )?.value ?? "",
    );

  test("the typing step starts at the query's first key", async () => {
    // One counted step, then one timed step: the first two keys of the query.
    const one = await server.open("combobox", 1000);
    await one.measure("type", 1);
    expect(await typed(one)).toBe("it");
    await one.close();
    // Nine counted steps type the whole query; nine timed steps take it back.
    const nine = await server.open("combobox", 1000);
    await nine.measure("type", 9);
    expect(await typed(nine)).toBe("");
    await nine.close();
  });
});

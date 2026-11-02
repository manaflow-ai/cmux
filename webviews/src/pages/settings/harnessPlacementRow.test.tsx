import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";
import { HARNESS_PLACEMENT_KEY as key } from "../../ui/harnessPlacement";

const restore = installDom();
afterAll(restore);
const { renderPage, settle, rowElement, changeValue } = await import("./testing");

test("ordinary Settings shows all four placements and an explicit top-symbols choice survives reload", async () => {
  const page = await renderPage({
    path: "/settings/agents",
    setup: (provider) => provider.setHost({ ...provider.host, harness_placement: "left" }),
  });
  try {
    await settle();
    const select = () => rowElement(page.container, key).querySelector<HTMLSelectElement>("select")!;
    expect(select().value).toBe("left");
    expect([...select().options].map((option) => option.value)).toEqual(["symbols", "left", "top", "compact"]);
    await changeValue(select(), "symbols");
    await page.store.refresh();
    await settle();
    expect(select().value).toBe("symbols");
    expect(page.store.getSnapshot().rows.get(key)?.customized).toBe(true);
    await page.store.reset(key);
    await settle();
    expect(select().value).toBe("left");
    expect(page.store.getSnapshot().rows.get(key)?.customized).toBe(false);
  } finally {
    page.unmount();
  }
});

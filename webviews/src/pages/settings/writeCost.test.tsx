// perf-10x (msg 1628): one write costs one read of the scope (the owner builds every row per read),
// and the read keeps every row it did not change, so only the written row's subscribers render.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, run } = await import("./testing");
const { settingsKeys } = await import("./queries");
type ScopeData = import("./queries").ScopeData;

test("a write reads the scope once and keeps every other row's object", async () => {
  const page = await renderPage({ path: "/settings/terminal" });
  try {
    const scope = () => page.store.queryClient.getQueryData<ScopeData>(settingsKeys.scope("user"))!;
    const before = scope();
    const reads = () => page.provider.log.filter((entry) => entry.op === "cmux.settings.list").length;
    const readsBefore = reads();
    await run(() => page.store.set("terminal.fontSize", 17));
    expect(reads() - readsBefore).toBe(1);
    const after = scope();
    expect(after.rows.get("terminal.fontSize")?.value).toBe(17);
    for (const [key, row] of before.rows) if (key !== "terminal.fontSize") expect(after.rows.get(key)).toBe(row);
    expect(after.domains).toBe(before.domains);
  } finally {
    page.unmount();
  }
});

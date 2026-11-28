import { afterAll, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { installDom } from "./testDom";
const restore = installDom();
afterAll(() => restore());
const { renderPage } = await import("./testing");
test("probe", async () => {
  for (const path of ["/settings/general", "/settings/cloud", "/settings/agents"]) {
    const page = await renderPage({ path });
    const html = page.container.innerHTML.replace(/(id|for|aria-[a-z]+)="[^"]*"/g, "");
    writeFileSync(`${process.env.PROBE_OUT}${path.replaceAll("/", "_")}.html`, html);
    page.unmount();
  }
}, 600000);

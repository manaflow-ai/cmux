import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, rowElement } = await import("./testing");

test("chat roots show locked managed rows and refusal reasons; removal writes only user roots", async () => {
  const page = await renderPage({
    path: "/settings/general",
    mock: {
      values: { "agents.chats.roots": ["/opt/user", "/opt/shared"] },
      chatFolders: [
        { path: "/opt/user", managed: false, reason: null },
        { path: "/opt/shared", managed: true, reason: null },
        {
          path: "/Users/test/Documents/chats",
          managed: true,
          reason: "This folder is protected by macOS privacy controls.",
        },
      ],
    },
  });
  const row = rowElement(page.container, "agents.chats.roots");
  expect(row.querySelectorAll("[data-locked]").length).toBe(2);
  expect(row.querySelector("[data-locked] button")).toBeNull();
  expect(row.textContent).toContain("This folder is protected by macOS privacy controls.");
  const add = row.querySelector<HTMLButtonElement>("[data-add-folder]");
  expect(add?.disabled).toBe(false);
  const remove = row.querySelector<HTMLButtonElement>('[data-folder="/opt/user"] button');
  await act(async () => remove?.click());
  await settle();
  const sets = page.provider.log.filter((entry) => entry.op === "cmux.settings.set");
  expect(sets.at(-1)?.params).toMatchObject({ key: "agents.chats.roots", value: ["/opt/shared"] });
  page.unmount();
});

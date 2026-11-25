// Settings > Cloud > Default Image (`cloud.defaultImage`): a menu of Auto and the account's Cloud
// environments (the Cloud Environments card's list), the current value selected. Picking an
// environment writes its id; Auto resets the key. New Cloud chats start from it (chatCloudEnvironment.ts).
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { SchemaRow } from "./schema";

const restore = installDom();
afterAll(() => restore());
const { renderCard, changeValue, ops } = await import("./testing");
const { DefaultImageEditor, defaultImageOptions, defaultImageStatus, DEFAULT_IMAGE_KEY } =
  await import("./editors/DefaultImageEditor");

const row = { key: DEFAULT_IMAGE_KEY, kind: "text", default: "auto" } as unknown as SchemaRow;
const WEB = "env_00000000000000000001";
const API = "env_00000000000000000002";

const options = (container: HTMLElement) =>
  [...container.querySelectorAll<HTMLOptionElement>("select option")].map((option) => [
    option.value,
    option.textContent,
  ]);

test("the menu lists Auto then each environment, with Auto selected by default", async () => {
  const page = await renderCard(<DefaultImageEditor row={row} value="auto" disabled={false} labelId="image" />);
  expect(page.provider.environmentRuns).toContainEqual({ action: "refresh" });
  expect(options(page.container)).toEqual([
    ["auto", "Auto"],
    [WEB, "web"],
    [API, "api"],
  ]);
  expect(page.container.querySelector<HTMLSelectElement>("select")!.value).toBe("auto");
  page.unmount();
});

test("the current environment is selected, and picking writes or resets the key", async () => {
  const page = await renderCard(<DefaultImageEditor row={row} value={API} disabled={false} labelId="image" />);
  const select = page.container.querySelector<HTMLSelectElement>("select")!;
  expect(select.value).toBe(API);
  await changeValue(select, WEB);
  expect(ops(page.provider, "cmux.settings.set")).toContainEqual({ key: DEFAULT_IMAGE_KEY, value: WEB });
  await changeValue(select, "auto");
  expect(ops(page.provider, "cmux.settings.reset")).toContainEqual({ key: DEFAULT_IMAGE_KEY });
  page.unmount();
});

test("a picked environment the list does not hold stays selected by its id", () => {
  const environments = [{ id: WEB, name: "web" }];
  expect(defaultImageOptions("env_gone", environments, "Auto")).toEqual({
    selected: "env_gone",
    options: [
      { value: "auto", label: "Auto" },
      { value: WEB, label: "web" },
      { value: "env_gone", label: "env_gone" },
    ],
  });
  expect(defaultImageOptions(undefined, environments, "Auto").selected).toBe("auto");
  expect(defaultImageOptions("", [], "Auto").options).toEqual([{ value: "auto", label: "Auto" }]);
});

// cmux#51731: the picked image's build status shows beside the menu (the host rebuilds a stale Default Image).
test("the picked environment's build status shows; Auto shows none", () => {
  const rows = [
    { id: WEB, status: "stale" },
    { id: API, status: "ready" },
  ];
  expect(defaultImageStatus(WEB, rows)).toBe("settingsPage.cloudEnvironments.status.stale");
  expect(defaultImageStatus(API, rows)).toBe("settingsPage.cloudEnvironments.status.ready");
  expect(defaultImageStatus("auto", rows)).toBeUndefined();
  expect(defaultImageStatus("env_00000000000000000009", rows)).toBeUndefined();
});

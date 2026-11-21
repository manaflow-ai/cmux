// l10n-allow-file: synthetic extension control labels and texts.
import { describe, expect, test } from "bun:test";
import { MockAppPanelsClient } from "../../../apps/scene/panelsMock";
import { ExtensionControls, extensionControlsFrom, runExtensionControl } from "./extensionControlsModel";

const BUTTON = {
  app: "local/footer",
  extension: "Footer",
  id: "plan",
  kind: "button",
  label: "Plan",
  symbol: "list.bullet",
  placement: "left",
  order: 0,
  insert: "Plan first: ",
};
const MENU = {
  app: "local/footer",
  extension: "Footer",
  id: "go",
  kind: "menu",
  label: "Go",
  placement: "right",
  order: -1,
  items: [
    { id: "window", label: "New window", action: "newWindow" },
    { id: "review", label: "Review", insert: "Review the diff." },
  ],
};

describe("extension footer controls (cmux.composer.control/1)", () => {
  test("the daemon's list is read as it is, and broken entries are dropped", () => {
    const controls = extensionControlsFrom({
      controls: [
        BUTTON,
        MENU,
        { app: "local/footer", id: "noop", kind: "button", label: "Nothing" },
        { app: "local/footer", id: "empty", kind: "menu", label: "Empty", items: [{ id: "x", label: "X" }] },
        { id: "anon", kind: "button", label: "No app", insert: "x" },
      ],
    });
    expect(controls.map((c) => c.id)).toEqual(["plan", "go"]);
    expect(controls[0]).toMatchObject({ kind: "button", placement: "left", insert: "Plan first: ", items: [] });
    expect(controls[1]!.items.map((i) => i.action ?? i.insert)).toEqual(["newWindow", "Review the diff."]);
    expect(extensionControlsFrom({ commands: [] })).toEqual([]);
    expect(extensionControlsFrom(null)).toEqual([]);
  });

  test("an insert stays in the page and an action goes to the daemon as the app's control", async () => {
    const client = new MockAppPanelsClient();
    const [button, menu] = extensionControlsFrom({ controls: [BUTTON, MENU] });
    expect(await runExtensionControl(client, button!)).toBe("Plan first: ");
    expect(await runExtensionControl(client, menu!, menu!.items[1])).toBe("Review the diff.");
    expect(client.controlRuns).toEqual([]);
    expect(await runExtensionControl(client, menu!, menu!.items[0])).toBeUndefined();
    expect(client.controlRuns).toEqual([{ app: "local/footer", control: "go", item: "window" }]);
  });

  test("the page lists the installed controls and none from an older host", async () => {
    const client = new MockAppPanelsClient();
    client.composerControls = [BUTTON];
    const owner = new ExtensionControls(client);
    owner.start();
    await owner.refresh();
    expect(owner.getSnapshot().map((c) => c.label)).toEqual(["Plan"]);
    owner.stop();

    const older = new ExtensionControls({
      call: async () => {
        throw new Error("unknown op");
      },
      subscribe: async () => () => undefined,
    } as never);
    older.start();
    await older.refresh();
    expect(older.getSnapshot()).toEqual([]);
  });
});

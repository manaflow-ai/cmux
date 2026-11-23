import { expect, test } from "bun:test";
import { AppWidgetsClient, readTiles, readWidgets, WIDGET_OPS, widgetLocaleContext } from "./widgetsClient";
import { MockWidgetsHost } from "./widgetsMock";

/** Lets the mock host's answers and queued scene events land (no timers, no polling). */
async function settled(rounds = 6) {
  for (let i = 0; i < rounds; i++) await new Promise<void>((resolve) => queueMicrotask(resolve));
}

const ops = (host: MockWidgetsHost) => host.calls.map((call) => call.op.replace("cmux.apps.panels.", ""));

test("nothing mounts while no widget is placed", async () => {
  const host = new MockWidgetsHost();
  const owner = new AppWidgetsClient(host);
  owner.start();
  await settled();
  expect(owner.getView().listed).toBe(true);
  expect(owner.getView().widgets.map((w) => w.app)).toEqual(["cmux/clock", "cmux/weather", "cmux/todo"]);
  expect(owner.getView().tiles).toEqual([]);
  expect(host.mountCalls).toBe(0);
  // No tile, no health watch either: only the list and the layout's change stream.
  expect(ops(host).every((op) => op === "widgets.list")).toBe(true);
  owner.stop();
});

test("each placed tile mounts as a widget with its place, size and instance", async () => {
  const host = new MockWidgetsHost([
    { instance: "w1", app: "cmux/clock", size: "small" },
    { instance: "w2", app: "cmux/todo", size: "medium" },
  ]);
  const owner = new AppWidgetsClient(host);
  owner.start();
  await settled();
  const mounts = host.calls.filter((call) => call.op === "cmux.apps.panels.mount").map((call) => call.params);
  expect(mounts).toEqual([
    {
      surface: "widget",
      app: "cmux/clock",
      context: { place: "newtab", size: "small", instance: "w1", ...widgetLocaleContext() },
    },
    {
      surface: "widget",
      app: "cmux/todo",
      context: { place: "newtab", size: "medium", instance: "w2", ...widgetLocaleContext() },
    },
  ]);
  owner.stop();
  expect(host.mounts.size).toBe(0);
});

test("edits call the daemon's op with a fresh idempotency key, and the page draws its answer", async () => {
  const host = new MockWidgetsHost([{ instance: "w1", app: "cmux/clock", size: "small" }]);
  const owner = new AppWidgetsClient(host);
  owner.start();
  await settled();
  await owner.edit({ op: "add", app: "cmux/weather", size: "medium" });
  await owner.edit({ op: "resize", instance: "w1", size: "large" });
  await owner.edit({ op: "move", instance: "w2", before: "w1" });
  await owner.edit({ op: "remove", instance: "w1" });
  const edits = host.calls.filter((call) => call.op === WIDGET_OPS.edit).map((call) => call.params);
  expect(edits.map((edit) => edit.edit)).toEqual([
    { op: "add", app: "cmux/weather", size: "medium" },
    { op: "resize", instance: "w1", size: "large" },
    { op: "move", instance: "w2", before: "w1" },
    { op: "remove", instance: "w1" },
  ]);
  expect(edits.every((edit) => edit.place === "newtab")).toBe(true);
  const keys = edits.map((edit) => String(edit.idempotency_key));
  expect(keys.every((key) => key.startsWith("widget-edit-"))).toBe(true);
  expect(new Set(keys).size).toBe(keys.length);
  await settled();
  expect(owner.getView().tiles).toEqual([{ instance: "w2", app: "cmux/weather", size: "medium" }]);
  // A resize is a new mount at the new size (the daemon remounts the widget).
  const sizes = host.calls
    .filter((call) => call.op === "cmux.apps.panels.mount")
    .map((call) => (call.params.context as { size: string }).size);
  expect(sizes).toContain("large");
  owner.stop();
});

test("a layout edited on another page is followed here", async () => {
  const host = new MockWidgetsHost();
  const owner = new AppWidgetsClient(host);
  owner.start();
  await settled();
  host.changeElsewhere([{ instance: "w9", app: "cmux/clock", size: "small" }]);
  await settled();
  expect(owner.getView().tiles.map((tile) => tile.instance)).toEqual(["w9"]);
  expect(host.mountCalls).toBe(1);
  owner.stop();
});

test("a stale tile keeps its last scene and is marked; another tile is untouched", async () => {
  const host = new MockWidgetsHost([
    { instance: "w1", app: "cmux/weather", size: "small" },
    { instance: "w2", app: "cmux/clock", size: "small" },
  ]);
  const owner = new AppWidgetsClient(host);
  owner.start();
  await settled(12);
  const weather = owner.tile("w1")!;
  const clock = owner.tile("w2")!;
  const root = weather.mount.store.getRoot();
  expect(root).toBeDefined();
  host.health(host.mountOf("w1")!, true);
  expect(weather.getHealth()).toEqual({
    stale: true,
    reason: "render: TypeError: weather is undefined",
    retryMs: 4000,
  });
  expect(weather.mount.store.getRoot()).toBe(root);
  expect(clock.getHealth().stale).toBe(false);
  host.health(host.mountOf("w1")!, false);
  expect(weather.getHealth().stale).toBe(false);
  owner.stop();
});

test("visibility goes to the daemon once per change, for the tile's own mount", async () => {
  const host = new MockWidgetsHost([{ instance: "w1", app: "cmux/clock", size: "small" }]);
  const owner = new AppWidgetsClient(host);
  owner.start();
  await settled();
  const tile = owner.tile("w1")!;
  const id = host.mountOf("w1")!;
  tile.setVisible(false);
  tile.setVisible(false);
  tile.setVisible(true);
  await settled();
  const sent = host.calls.filter((call) => call.op === WIDGET_OPS.visible).map((call) => call.params);
  // A new mount is shown already (the daemon's default): each change goes out once.
  expect(sent).toEqual([
    { mount_id: id, visible: false },
    { mount_id: id, visible: true },
  ]);
  owner.stop();
});

test("the meter reads this page's tiles by instance", async () => {
  const host = new MockWidgetsHost([{ instance: "w1", app: "cmux/clock", size: "small" }]);
  const owner = new AppWidgetsClient(host);
  owner.start();
  await settled();
  expect(await owner.meters()).toEqual([
    { instance: "w1", everySeconds: 60, ticks: 12, held: 1, visible: true, failures: 0 },
  ]);
  owner.stop();
});

test("an older host without widget ops shows nothing and edits nothing", async () => {
  const host = new MockWidgetsHost([{ instance: "w1", app: "cmux/clock", size: "small" }]);
  host.unsupported = true;
  const owner = new AppWidgetsClient(host);
  owner.start();
  await settled();
  expect(owner.getView().supported).toBe(false);
  await owner.edit({ op: "add", app: "cmux/clock" });
  expect(host.calls.some((call) => call.op === WIDGET_OPS.edit)).toBe(false);
  expect(host.mountCalls).toBe(0);
  owner.stop();
});

test("the listing reads only well-formed widgets and tiles", () => {
  expect(
    readWidgets({
      widgets: [
        { app: "a/x", title: "X", sizes: ["small", "huge"], defaultSize: "large" },
        { app: "a/y", sizes: [] },
        { app: "a/x", title: "dup", sizes: ["small"] },
      ],
    }),
  ).toEqual([{ app: "a/x", title: "X", sizes: ["small"], defaultSize: "small" }]);
  expect(
    readTiles(
      {
        newtab: [
          { instance: "w1", app: "a/x", size: "medium" },
          { instance: "w1", app: "a/x", size: "small" },
          { instance: "w2", app: "a/x", size: "giant" },
        ],
      },
      "newtab",
    ),
  ).toEqual([{ instance: "w1", app: "a/x", size: "medium" }]);
});

test("a resize ends the old mount and mounts the widget again at the new size", async () => {
  const host = new MockWidgetsHost([{ instance: "w1", app: "cmux/clock", size: "small" }]);
  const owner = new AppWidgetsClient(host);
  owner.start();
  await settled();
  const first = [...host.mounts.keys()];
  await owner.edit({ op: "resize", instance: "w1", size: "large" });
  await settled();
  expect(host.calls.some((call) => call.op === "cmux.apps.panels.unmount" && call.params.mount_id === first[0])).toBe(
    true,
  );
  expect([...host.mounts.values()].map((mount) => mount.context.size)).toEqual(["large"]);
  owner.stop();
});

test("a refused edit reads the layout again, so a removed tile comes back", async () => {
  const host = new MockWidgetsHost([
    { instance: "w1", app: "cmux/clock", size: "small" },
    { instance: "w2", app: "cmux/todo", size: "medium" },
  ]);
  const owner = new AppWidgetsClient(host);
  owner.start();
  await settled();
  host.refuseEdits = true;
  const sent = owner.edit({ op: "remove", instance: "w1" });
  expect(owner.getView().tiles.map((t) => t.instance)).toEqual(["w2"]);
  await sent;
  await settled();
  expect(owner.getView().tiles.map((t) => t.instance)).toEqual(["w1", "w2"]);
  owner.stop();
});

test("a list answered while an edit is pending never brings back what the edit removed", async () => {
  const host = new MockWidgetsHost([
    { instance: "w1", app: "cmux/clock", size: "small" },
    { instance: "w2", app: "cmux/todo", size: "medium" },
  ]);
  const owner = new AppWidgetsClient(host);
  owner.start();
  await settled();
  let release = () => {};
  host.holdEdits = new Promise<void>((resolve) => {
    release = resolve;
  });
  const sent = owner.edit({ op: "remove", instance: "w1" });
  const mountsBefore = host.mountCalls;
  // Another page's change makes this page list while the daemon still holds the remove.
  await owner.refresh();
  await settled();
  expect(owner.getView().tiles.map((t) => t.instance)).toEqual(["w2"]);
  expect(host.mountCalls).toBe(mountsBefore);
  host.holdEdits = undefined;
  release();
  await sent;
  await settled();
  expect(owner.getView().tiles.map((t) => t.instance)).toEqual(["w2"]);
  expect(host.mountCalls).toBe(mountsBefore);
  owner.stop();
});

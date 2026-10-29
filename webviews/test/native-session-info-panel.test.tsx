// Session Info drawn by the App (inspector/native): the header toggle's pressed state follows the panel's
// open state, the App's own actions (Esc, a drag of its edge, a fold) change the page's Inspector state,
// a click on a row runs the action the page named, and the sections go in the person's order.
import { beforeEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { PanelToggle } from "../src/agent-session/acpmux/header/PanelToggle";
import {
  inspectorState,
  resetInspectorState,
  setInspectorOpen,
} from "../src/agent-session/acpmux/inspector/inspectorState";
import {
  runNativeSessionInfoAction,
  setNativeSessionInfoActions,
  setNativeSessionInfoHost,
  nativeSessionInfoDrawn,
} from "../src/agent-session/acpmux/inspector/native/host";
import {
  NATIVE_ACTION_ID_MAX,
  NativeInfoActions,
  type NativeInfoSection,
} from "../src/agent-session/acpmux/inspector/native/model";
import { orderSections, panelAction } from "../src/agent-session/acpmux/inspector/native/NativeSessionInfo";

beforeEach(() => {
  resetInspectorState();
  setNativeSessionInfoActions(undefined);
});

test("the toggle reads as pressed exactly while the panel shows", () => {
  const toggle = (shown: boolean) =>
    renderToStaticMarkup(<PanelToggle label="Session Info" shown={shown} onToggle={() => undefined} />);
  expect(toggle(true)).toContain('aria-pressed="true"');
  expect(toggle(false)).toContain('aria-pressed="false"');
});

test("the host's word decides whether the App draws it", () => {
  setNativeSessionInfoHost(true);
  expect(nativeSessionInfoDrawn()).toBe(true);
  setNativeSessionInfoHost("yes");
  expect(nativeSessionInfoDrawn()).toBe(false);
});

test("Esc in the App's panel closes it, so the toggle goes off", () => {
  setInspectorOpen(true);
  expect(panelAction("close")).toBe(true);
  expect(inspectorState().open).toBe(false);
});

test("a drag of the panel's edge keeps the width, within the Inspector's bounds", () => {
  expect(panelAction("width:400")).toBe(true);
  expect(inspectorState().width).toBe(400);
  panelAction("width:9000");
  expect(inspectorState().width).toBe(560);
  panelAction("width:10");
  expect(inspectorState().width).toBe(260);
});

test("a section's title row folds it; unknown sections and actions do nothing", () => {
  expect(panelAction("fold:context:1")).toBe(true);
  expect(inspectorState().sections.context).toBe(true);
  panelAction("fold:context:0");
  expect(inspectorState().sections.context).toBe(false);
  expect(panelAction("fold:nothing:1")).toBe(false);
  expect(panelAction("drop tables")).toBe(false);
});

test("a click runs the row's action, else the panel's own", () => {
  const actions = new NativeInfoActions();
  let opened = 0;
  actions.add("subagents.open:a1", () => opened++);
  setNativeSessionInfoActions(actions, panelAction);
  setInspectorOpen(true);
  runNativeSessionInfoAction("subagents.open:a1");
  return Promise.resolve().then(() => {
    expect(opened).toBe(1);
    runNativeSessionInfoAction("close");
    expect(inspectorState().open).toBe(false);
    runNativeSessionInfoAction(42);
  });
});

test("sections go block by block, in the person's order within each block", () => {
  const section = (id: NativeInfoSection["id"], group: NativeInfoSection["group"]): NativeInfoSection => ({
    id,
    group,
    title: id,
    open: true,
    foldable: true,
    rows: [],
  });
  const ordered = orderSections(
    [
      section("tasks", "running"),
      undefined,
      section("changes", "made"),
      section("subagents", "running"),
      section("environment", "about"),
    ],
    (group) =>
      group === "running"
        ? ["tasks", "subagents"]
        : group === "made"
          ? ["changes", "sources", "outputs"]
          : ["environment"],
  );
  expect(ordered.map((entry) => entry.id)).toEqual(["environment", "changes", "tasks", "subagents"]);
});

test("a row whose id is a long signed URL still runs from the App's click", async () => {
  const actions = new NativeInfoActions();
  let opened = 0;
  const long = `sources.open:https://example.com/${"a".repeat(2000)}?sig=1`;
  const id = actions.add(long, () => opened++);
  expect(id.length).toBeLessThanOrEqual(NATIVE_ACTION_ID_MAX);
  expect(actions.add(long, () => opened++)).toBe(id);
  expect(actions.add(`${long}2`, () => undefined)).not.toBe(id);
  setNativeSessionInfoActions(actions, panelAction);
  runNativeSessionInfoAction(id);
  await Promise.resolve();
  expect(opened).toBe(1);
});

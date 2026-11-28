import { afterEach, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { experimentSwitchOn, setExperimentSwitches, useExperimentSwitch } from "./switches";

afterEach(() => setExperimentSwitches({}));

test("every switch is off until the App turns it on", () => {
  expect(experimentSwitchOn("glassToolbarGroups")).toBe(false);
  setExperimentSwitches({ glassToolbarGroups: true, other: false });
  expect(experimentSwitchOn("glassToolbarGroups")).toBe(true);
  expect(experimentSwitchOn("other")).toBe(false);
});

test("each push is the whole object: a switch it leaves out is off", () => {
  setExperimentSwitches({ glassToolbarGroups: true });
  setExperimentSwitches({ somethingElse: true });
  expect(experimentSwitchOn("glassToolbarGroups")).toBe(false);
  expect(experimentSwitchOn("somethingElse")).toBe(true);
});

test("only a true value turns a switch on, and a value that is no object turns them all off", () => {
  setExperimentSwitches({ a: "true", b: 1, c: null });
  expect(["a", "b", "c"].some(experimentSwitchOn)).toBe(false);
  setExperimentSwitches({ glassToolbarGroups: true });
  for (const value of [null, undefined, true, "on", [true]]) {
    setExperimentSwitches(value);
    expect(experimentSwitchOn("glassToolbarGroups")).toBe(false);
    setExperimentSwitches({ glassToolbarGroups: true });
  }
});

test("a server render reads a switch (renderToStaticMarkup throws on a store with no server snapshot)", () => {
  function Probe() {
    return createElement("i", null, useExperimentSwitch("glassToolbarGroups") ? "on" : "off");
  }
  expect(renderToStaticMarkup(createElement(Probe))).toBe("<i>off</i>");
  setExperimentSwitches({ glassToolbarGroups: true });
  expect(renderToStaticMarkup(createElement(Probe))).toBe("<i>on</i>");
});

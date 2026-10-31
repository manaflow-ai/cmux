// A pane's prompts name the place they came from only with preview features on
// (surfaces/promptSurface.ts, cmuxterm-hq#2580).
import { expect, test } from "bun:test";
import { deviceName, promptSurfaceMeta, setPromptSurfaces } from "../src/agent-session/acpmux/surfaces/promptSurface";

test("prompts carry no surface while preview features are off", () => {
  setPromptSurfaces(false);
  expect(promptSurfaceMeta()).toEqual({});
});

test("with preview features on, every prompt from one pane names the same surface", () => {
  setPromptSurfaces(true);
  const first = promptSurfaceMeta();
  expect("surface" in first && first.surface.kind).toBe("app");
  expect(promptSurfaceMeta()).toEqual(first);
  setPromptSurfaces(false);
  expect(promptSurfaceMeta()).toEqual({});
});

test("the device name is what the other places typing see", () => {
  expect(deviceName("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)")).toBe("iPhone");
  expect(deviceName("Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X)")).toBe("iPad");
  expect(deviceName("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")).toBe("Mac");
  expect(deviceName("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", 5)).toBe("iPad");
  expect(deviceName("Mozilla/5.0 (X11; Linux x86_64)")).toBe("Web");
});

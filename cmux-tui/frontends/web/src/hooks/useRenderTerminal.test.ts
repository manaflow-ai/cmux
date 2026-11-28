import type { CmuxClient } from "cmux/raw";
import { describe, expect, it } from "vitest";
import type { RenderModel } from "../lib/renderModel";
import { renderTerminalFrame, renderTerminalViewReducer } from "./useRenderTerminal";

describe("render frame during transport replacement", () => {
  const oldClient = {} as CmuxClient;
  const newClient = {} as CmuxClient;
  const oldFrame = { surface: 1n, rows: [] } as unknown as RenderModel;
  const newFrame = { surface: 1n, rows: [] } as unknown as RenderModel;
  const history = { active: false, loading: false, total: 0, epoch: undefined, rows: [] };
  const shown = { client: oldClient, surface: 1n, model: oldFrame, focused: true, history };

  it("keeps the same surface visible through cleanup and bind until the replacement frame arrives", () => {
    // React renders the new client once before running the old effect cleanup.
    expect(renderTerminalFrame(shown, 1n).model).toBe(oldFrame);
    const detached = renderTerminalViewReducer(shown, {
      type: "reset",
      client: oldClient,
      surface: 1n,
    });
    expect(renderTerminalFrame(detached, 1n).model).toBe(oldFrame);
    const rebound = renderTerminalViewReducer(detached, {
      type: "bind",
      client: newClient,
      surface: 1n,
    });
    expect(renderTerminalFrame(rebound, 1n).model).toBe(oldFrame);
    expect(rebound.focused).toBe(false);
    const replaced = renderTerminalViewReducer(rebound, {
      type: "frame",
      client: newClient,
      surface: 1n,
      model: newFrame,
      history,
    });
    expect(renderTerminalFrame(replaced, 1n).model).toBe(newFrame);
    expect(
      renderTerminalViewReducer(replaced, {
        type: "frame",
        client: oldClient,
        surface: 1n,
        model: oldFrame,
        history,
      }),
    ).toBe(replaced);
  });

  it("never shows the old frame for a different surface", () => {
    expect(renderTerminalFrame(shown, 2n).model).toBeNull();
    const switched = renderTerminalViewReducer(shown, {
      type: "bind",
      client: newClient,
      surface: 2n,
    });
    expect(renderTerminalFrame(switched, 2n).model).toBeNull();
    expect(renderTerminalFrame(switched, 1n).model).toBeNull();
  });
});

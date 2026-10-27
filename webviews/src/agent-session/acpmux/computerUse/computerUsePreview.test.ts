import { describe, expect, test } from "bun:test";
import { transcriptColumn, transcriptRowWidth } from "../model";
import {
  closeComputerUsePreview,
  COMPUTER_USE_PREVIEW_RESERVE,
  computerUsePreviewTitle,
  currentComputerUsePreview,
  readComputerUsePreview,
  setComputerUsePreview,
} from "./computerUsePreview";

const frame = "data:image/jpeg;base64,AA==";
const icon = "data:image/png;base64,AA==";
const column = { min: 720, max: 800, share: 0.625, prose: Infinity };

describe("computerUsePreview", () => {
  test("reads a running card and a done card with its icon", () => {
    expect(readComputerUsePreview({ session: "cua_1", app: "Calculator", done: false, frame })).toEqual({
      session: "cua_1",
      app: "Calculator",
      done: false,
      frame,
    });
    expect(readComputerUsePreview({ session: "cua_1", app: "Calculator", done: true, frame, icon })).toEqual({
      session: "cua_1",
      app: "Calculator",
      done: true,
      frame,
      icon,
    });
  });

  test("takes only image data URLs", () => {
    expect(
      readComputerUsePreview({ session: "cua_1", app: "Calculator", done: false, frame: "https://x.test/a.png" }),
    ).toBe(null);
    expect(
      readComputerUsePreview({ session: "cua_1", app: "Calculator", done: false, frame, icon: "javascript:alert(1)" }),
    ).toEqual({ session: "cua_1", app: "Calculator", done: false, frame });
  });

  test("a null push or a malformed card hides it", () => {
    setComputerUsePreview({ session: "cua_1", app: "Calculator", done: false, frame });
    expect(currentComputerUsePreview()?.session).toBe("cua_1");
    setComputerUsePreview(null);
    expect(currentComputerUsePreview()).toBe(null);
    setComputerUsePreview({ session: "", frame });
    expect(currentComputerUsePreview()).toBe(null);
  });

  test("a close hides that session's card at once, and a newer session still shows", () => {
    setComputerUsePreview({ session: "cua_2", app: "Calculator", done: false, frame });
    closeComputerUsePreview("cua_2");
    expect(currentComputerUsePreview()).toBe(null);
    setComputerUsePreview({ session: "cua_2", app: "Calculator", done: true, frame });
    expect(currentComputerUsePreview()).toBe(null);
    setComputerUsePreview({ session: "cua_3", app: "Notes", done: false, frame });
    expect(currentComputerUsePreview()?.session).toBe("cua_3");
    setComputerUsePreview(null);
  });

  test("the title is the app's name, or none when the host knows none", () => {
    const card = { session: "cua_1", done: false, frame };
    expect(computerUsePreviewTitle({ ...card, app: "Calculator" })).toBe("Calculator");
    expect(computerUsePreviewTitle({ ...card, app: "" })).toBeUndefined();
    expect(computerUsePreviewTitle({ ...card, app: "   " })).toBeUndefined();
    // A push without a name reads as "": the label then names no app.
    expect(readComputerUsePreview({ session: "cua_1", done: false, frame })?.app).toBe("");
  });
});

describe("the column keeps the card's room", () => {
  test("a pane whose gutter is too narrow moves the column's end in, and keeps its start", () => {
    const plain = transcriptColumn(900, column);
    expect(plain).toEqual({ inset: 90, insetEnd: 90, width: 720 });
    const beside = transcriptColumn(900, column, COMPUTER_USE_PREVIEW_RESERVE);
    expect(beside).toEqual({ inset: 90, insetEnd: 204, width: 606 });
    expect(transcriptRowWidth(900, column, COMPUTER_USE_PREVIEW_RESERVE)).toBe(606);
  });

  test("a wide pane's gutter already holds the card: nothing moves", () => {
    expect(transcriptColumn(1600, column, COMPUTER_USE_PREVIEW_RESERVE)).toEqual({
      inset: 400,
      insetEnd: 400,
      width: 800,
    });
  });
});

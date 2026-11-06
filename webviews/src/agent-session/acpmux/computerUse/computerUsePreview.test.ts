import { describe, expect, test } from "bun:test";
import { transcriptColumn, transcriptRowWidth } from "../model";
import {
  closeComputerUsePreview,
  COMPUTER_USE_PREVIEW_RESERVE,
  computerUsePreviewTitle,
  currentComputerUsePreview,
  PERSON_POINTER_IDLE_MS,
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

  test("a running card takes the agent's last click; a done or malformed one has none", () => {
    const pointer = { x: 0.5, y: 0.25, click: 3 };
    expect(readComputerUsePreview({ session: "cua_1", app: "", done: false, frame, pointer })?.pointer).toEqual(
      pointer,
    );
    expect(readComputerUsePreview({ session: "cua_1", app: "", done: true, frame, pointer })?.pointer).toBeUndefined();
    expect(
      readComputerUsePreview({
        session: "cua_1",
        app: "",
        done: false,
        frame,
        pointer: { ...pointer, windowWidth: 230 },
      })?.pointer?.windowWidth,
    ).toBe(230);
    expect(
      readComputerUsePreview({
        session: "cua_1",
        app: "",
        done: false,
        frame,
        pointer: { ...pointer, windowWidth: -1 },
      })?.pointer,
    ).toEqual(pointer);
    for (const bad of [{ x: 1.5, y: 0, click: 1 }, { x: 0, y: "0", click: 1 }, { x: 0, y: 0 }, null, "0,0"]) {
      expect(
        readComputerUsePreview({ session: "cua_1", app: "", done: false, frame, pointer: bad })?.pointer,
      ).toBeUndefined();
    }
  });

  test("a new click at the same frame is a change", () => {
    setComputerUsePreview({ session: "cua_1", app: "", done: false, frame, pointer: { x: 0.5, y: 0.5, click: 1 } });
    const first = currentComputerUsePreview();
    setComputerUsePreview({ session: "cua_1", app: "", done: false, frame, pointer: { x: 0.5, y: 0.5, click: 2 } });
    expect(currentComputerUsePreview()).not.toBe(first);
    expect(currentComputerUsePreview()?.pointer?.click).toBe(2);
    setComputerUsePreview(null);
  });

  test("a running card takes both telepointers; a done or malformed one has none", () => {
    const telepointers = {
      agent: { x: 0.4, y: 0.6, visible: true, ageMs: 250 },
      person: { x: 1, y: 0.5, visible: false, ageMs: 2250, idle: true },
    };
    const read = readComputerUsePreview({ session: "cua_1", app: "", done: false, frame, telepointers });
    expect(read?.telepointers).toEqual({
      agent: { x: 0.4, y: 0.6, visible: true, ageMs: 250, idle: false },
      person: { x: 1, y: 0.5, visible: false, ageMs: 2250, idle: true },
    });
    expect(
      readComputerUsePreview({ session: "cua_1", app: "", done: true, frame, telepointers })?.telepointers,
    ).toBeUndefined();
    // An age past the idle time dims it even without the host's flag; a bad age is dropped.
    expect(
      readComputerUsePreview({
        session: "cua_1",
        app: "",
        done: false,
        frame,
        telepointers: { person: { x: 0.1, y: 0.1, visible: true, ageMs: PERSON_POINTER_IDLE_MS } },
      })?.telepointers?.person?.idle,
    ).toBe(true);
    expect(
      readComputerUsePreview({
        session: "cua_1",
        app: "",
        done: false,
        frame,
        telepointers: { person: { x: 0.1, y: 0.1, visible: true, ageMs: -5 } },
      })?.telepointers,
    ).toEqual({ person: { x: 0.1, y: 0.1, visible: true, idle: false } });
    for (const bad of [{ x: 1.5, y: 0, visible: true }, { x: 0, y: 0 }, { x: 0, y: 0, visible: "yes" }, null, 3]) {
      expect(
        readComputerUsePreview({ session: "cua_1", app: "", done: false, frame, telepointers: { person: bad } })
          ?.telepointers,
      ).toBeUndefined();
    }
  });

  test("the person's pointer moving at the same frame is a change; a re-aged one is not", () => {
    const person = { x: 0.5, y: 0.5, visible: true, ageMs: 0 };
    setComputerUsePreview({ session: "cua_1", app: "", done: false, frame, telepointers: { person } });
    const first = currentComputerUsePreview();
    setComputerUsePreview({
      session: "cua_1",
      app: "",
      done: false,
      frame,
      telepointers: { person: { ...person, ageMs: 40 } },
    });
    expect(currentComputerUsePreview()).toBe(first);
    setComputerUsePreview({
      session: "cua_1",
      app: "",
      done: false,
      frame,
      telepointers: { person: { ...person, x: 0.6 } },
    });
    expect(currentComputerUsePreview()).not.toBe(first);
    expect(currentComputerUsePreview()?.telepointers?.person?.x).toBe(0.6);
    const moved = currentComputerUsePreview();
    setComputerUsePreview({
      session: "cua_1",
      app: "",
      done: false,
      frame,
      telepointers: { person: { ...person, x: 0.6, visible: false } },
    });
    expect(currentComputerUsePreview()).not.toBe(moved);
    setComputerUsePreview(null);
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
    expect(plain).toEqual({ inset: 88, insetEnd: 88, width: 724 });
    const beside = transcriptColumn(900, column, COMPUTER_USE_PREVIEW_RESERVE);
    expect(beside).toEqual({ inset: 88, insetEnd: 204, width: 608 });
    expect(transcriptRowWidth(900, column, COMPUTER_USE_PREVIEW_RESERVE)).toBe(608);
  });

  test("a wide pane's gutter already holds the card: nothing moves", () => {
    expect(transcriptColumn(1600, column, COMPUTER_USE_PREVIEW_RESERVE)).toEqual({
      inset: 400,
      insetEnd: 400,
      width: 800,
    });
  });
});

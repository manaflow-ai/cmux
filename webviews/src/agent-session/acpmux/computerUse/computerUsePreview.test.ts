import { describe, expect, test } from "bun:test";
import { currentComputerUsePreview, readComputerUsePreview, setComputerUsePreview } from "./computerUsePreview";

const frame = "data:image/jpeg;base64,AA==";
const icon = "data:image/png;base64,AA==";

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
});

import { describe, expect, test } from "bun:test";
import { parseChiefFace, parseChiefPlace } from "./ChiefPlace";

describe("the Chief's header face", () => {
  test("keeps a picture data URL and the profile's text", () => {
    expect(parseChiefFace({ conversation: "c1", picture: "data:image/png;base64,AA==", text: "🦊" })).toEqual({
      conversation: "c1",
      picture: "data:image/png;base64,AA==",
      text: "🦊",
    });
  });

  test("drops a picture that is not an image data URL", () => {
    expect(parseChiefFace({ conversation: "c1", picture: "https://example.com/a.png" })).toEqual({
      conversation: "c1",
    });
  });

  test("null or a value without a conversation is nothing", () => {
    expect(parseChiefFace(null)).toBeUndefined();
    expect(parseChiefFace({ picture: "data:image/png;base64,AA==" })).toBeUndefined();
  });
});

describe("the location chip", () => {
  test("reads the host's chip", () => {
    const chip = {
      tone: "away",
      text: "Chief is on studio-mini",
      glyph: "host",
      label: "Chief location: studio-mini",
      help: "Moves",
    } as const;
    expect(parseChiefPlace({ conversation: "c1", chip })).toEqual({ conversation: "c1", ...chip });
  });

  test("an unknown tone or glyph falls back to here and This Mac's", () => {
    expect(parseChiefPlace({ conversation: "c1", chip: { tone: "odd", text: "This Mac", glyph: "odd" } })).toEqual({
      conversation: "c1",
      tone: "here",
      text: "This Mac",
      glyph: "thisMac",
      label: "This Mac",
      help: "",
    });
  });

  test("null (no chip on this conversation) or a chip without words is nothing", () => {
    expect(parseChiefPlace(null)).toBeUndefined();
    expect(parseChiefPlace({ conversation: "c1", chip: { tone: "here" } })).toBeUndefined();
  });
});

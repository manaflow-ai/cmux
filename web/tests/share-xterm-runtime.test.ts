import { describe, expect, test } from "bun:test";

import {
  decodeXtermThemeMetadata,
  installXtermUserInputForwarder,
  type XtermInputEventSource,
} from "../app/[locale]/share/[code]/xterm-compatibility";

type Listener<T> = (value: T) => void;

function event<T>() {
  const listeners = new Set<Listener<T>>();
  return {
    fire(value: T) {
      for (const listener of listeners) listener(value);
    },
    subscribe(listener: Listener<T>) {
      listeners.add(listener);
      return {
        dispose() {
          listeners.delete(listener);
        },
      };
    },
  };
}

function inputSource() {
  const data = event<string>();
  const userInput = event<void>();
  const source: XtermInputEventSource = {
    onData: data.subscribe,
    _core: {
      coreService: {
        onUserInput: userInput.subscribe,
      },
    },
  };
  return { data, source, userInput };
}

describe("xterm terminal response ownership", () => {
  test("forwards only xterm events explicitly marked as user input", () => {
    const fixture = inputSource();
    const forwarded: string[] = [];
    const subscription = installXtermUserInputForwarder(
      fixture.source,
      (value) => forwarded.push(value),
    );

    expect(subscription).not.toBeNull();
    fixture.data.fire("\u001b[?1;2c");
    fixture.data.fire("\u001b[3;4R");
    fixture.data.fire("\u001b]10;rgb:aa/bb/cc\u001b\\");
    fixture.userInput.fire();
    fixture.data.fire("λ");
    fixture.userInput.fire();
    fixture.data.fire("\u001b[200~paste\u001b[201~");

    expect(forwarded).toEqual([
      "λ",
      "\u001b[200~paste\u001b[201~",
    ]);

    subscription?.dispose();
    fixture.userInput.fire();
    fixture.data.fire("after dispose");
    expect(forwarded).toHaveLength(2);
  });

  test("fails closed when the pinned xterm user-input hook is unavailable", () => {
    const data = event<string>();
    const forwarded: string[] = [];
    const subscription = installXtermUserInputForwarder(
      { onData: data.subscribe },
      (value) => forwarded.push(value),
    );

    data.fire("must not reach the host");
    expect(subscription).toBeNull();
    expect(forwarded).toEqual([]);
  });
});

describe("xterm host configuration theme", () => {
  test("maps a complete 256-color host theme to xterm options", () => {
    const palette = Array.from(
      { length: 256 },
      (_, index) => `#${index.toString(16).padStart(6, "0")}`,
    );
    const wire = {
      background: "#010203",
      foreground: "#a0b0c0",
      boldColor: "bright",
      cursor: "#102030",
      cursorText: "#abcdef",
      selectionBackground: "#304050",
      selectionForeground: "#f0e0d0",
      palette,
    };
    const encoded = Buffer.from(JSON.stringify(wire), "utf8")
      .toString("base64url");

    expect(decodeXtermThemeMetadata(`cmux-theme-v1;${encoded}`)).toEqual({
      background: wire.background,
      foreground: wire.foreground,
      cursor: wire.cursor,
      cursorAccent: wire.cursorText,
      selectionBackground: wire.selectionBackground,
      selectionForeground: wire.selectionForeground,
      black: palette[0],
      red: palette[1],
      green: palette[2],
      yellow: palette[3],
      blue: palette[4],
      magenta: palette[5],
      cyan: palette[6],
      white: palette[7],
      brightBlack: palette[8],
      brightRed: palette[9],
      brightGreen: palette[10],
      brightYellow: palette[11],
      brightBlue: palette[12],
      brightMagenta: palette[13],
      brightCyan: palette[14],
      brightWhite: palette[15],
      extendedAnsi: palette.slice(16),
    });
  });

  test("rejects malformed, oversized, and incomplete theme metadata", () => {
    const shortPalette = {
      background: "#000000",
      foreground: "#ffffff",
      cursor: "#ffffff",
      selectionBackground: "#222222",
      selectionForeground: "#eeeeee",
      palette: ["#000000"],
    };
    const encoded = Buffer.from(JSON.stringify(shortPalette), "utf8")
      .toString("base64url");

    expect(decodeXtermThemeMetadata(`cmux-theme-v1;${encoded}`)).toBeNull();
    expect(decodeXtermThemeMetadata("cmux-theme-v1;%%%")).toBeNull();
    expect(
      decodeXtermThemeMetadata(`cmux-theme-v1;${"a".repeat(22_000)}`),
    ).toBeNull();
    expect(decodeXtermThemeMetadata("other-version;e30")).toBeNull();
  });
});

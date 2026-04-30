import { expect, test } from "bun:test";
import { classifyTerminalData } from "./terminalKeyMap";

test("maps common terminal escape sequences to named keys", () => {
  expect(classifyTerminalData("\u001b[H")).toEqual({ kind: "key", key: "home" });
  expect(classifyTerminalData("\u001b[F")).toEqual({ kind: "key", key: "end" });
  expect(classifyTerminalData("\u001bOH")).toEqual({ kind: "key", key: "home" });
  expect(classifyTerminalData("\u001bOF")).toEqual({ kind: "key", key: "end" });
  expect(classifyTerminalData("\u001b[3~")).toEqual({ kind: "key", key: "delete" });
  expect(classifyTerminalData("\u001b[5~")).toEqual({ kind: "key", key: "pageup" });
  expect(classifyTerminalData("\u001b[6~")).toEqual({ kind: "key", key: "pagedown" });
  expect(classifyTerminalData("\u001b[Z")).toEqual({ kind: "key", key: "shift+tab" });
});

test("maps modified CSI arrow and navigation sequences", () => {
  expect(classifyTerminalData("\u001b[1;5D")).toEqual({ kind: "key", key: "ctrl+left" });
  expect(classifyTerminalData("\u001b[1;2A")).toEqual({ kind: "key", key: "shift+up" });
  expect(classifyTerminalData("\u001b[1;3C")).toEqual({ kind: "key", key: "alt+right" });
  expect(classifyTerminalData("\u001b[1;6F")).toEqual({ kind: "key", key: "shift+ctrl+end" });
  expect(classifyTerminalData("\u001b[3;5~")).toEqual({ kind: "key", key: "ctrl+delete" });
});

test("maps alt printable input to modified named keys", () => {
  expect(classifyTerminalData("\u001bb")).toEqual({ kind: "key", key: "alt+b" });
  expect(classifyTerminalData("\u001bB")).toEqual({ kind: "key", key: "alt+B" });
});

test("never classifies unsupported escape-prefixed input as text", () => {
  expect(classifyTerminalData("\u001b[999~")).toEqual({ kind: "ignore" });
  expect(classifyTerminalData("\u001b[?2004h")).toEqual({ kind: "ignore" });
  expect(classifyTerminalData("\u001b[2~")).toEqual({ kind: "ignore" });
  expect(classifyTerminalData("\u001b[5;2~")).toEqual({ kind: "ignore" });
  expect(classifyTerminalData("\u001b[6;5~")).toEqual({ kind: "ignore" });
});

test("keeps printable input as text", () => {
  expect(classifyTerminalData("ls -la")).toEqual({ kind: "text", text: "ls -la" });
});

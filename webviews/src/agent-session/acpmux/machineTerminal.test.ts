// A chat an added ssh machine runs: its Terminal is a shell on that machine (`chat.machineTerminal`,
// `acpmux machine shell`), never one on this Mac (Leo, 2026-11-06: "the terminal I open on the top
// right button works thru that machine").
import { afterEach, describe, expect, test } from "bun:test";
import { setNativeHost } from "./native";
import { chatShellMachine, openMachineTerminal } from "./processTerminal";

afterEach(() => setNativeHost(undefined));

describe("a chat's machine terminal", () => {
  test("only a peer that is not a Cloud machine gets a shell there", () => {
    expect(chatShellMachine("box", { box: "ssh" })).toBe("box");
    expect(chatShellMachine("box", undefined)).toBe("box");
    expect(chatShellMachine("cloud-1", { "cloud-1": "cloud" })).toBeUndefined();
    expect(chatShellMachine(undefined, { box: "ssh" })).toBeUndefined();
    expect(chatShellMachine("cloud-2", undefined, "cloud")).toBeUndefined();
  });

  test("asks the host for the machine's shell in the chat's folder there", async () => {
    const posted: [string, Record<string, unknown>][] = [];
    setNativeHost(async (method, params) => {
      posted.push([method, params]);
      return { opened: true };
    });
    expect(await openMachineTerminal("box", "/home/leo/repo")).toBe(true);
    expect(await openMachineTerminal("box")).toBe(true);
    expect(posted).toEqual([
      ["chat.machineTerminal", { machine: "box", cwd: "/home/leo/repo" }],
      ["chat.machineTerminal", { machine: "box" }],
    ]);
  });

  test("a host that opens none or refuses says so, so the page keeps this Mac's shell", async () => {
    setNativeHost(async () => ({ opened: false }));
    expect(await openMachineTerminal("box")).toBe(false);
    setNativeHost(async () => {
      throw new Error("unsupported");
    });
    expect(await openMachineTerminal("box")).toBe(false);
  });
});

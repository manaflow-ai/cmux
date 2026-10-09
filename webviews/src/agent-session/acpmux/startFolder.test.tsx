import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { StartFolderAsk, confirmFolder, pickFolder } from "./startFolder";

// cx-nn3e (Lawrence 2026-10-09): the chip said `~`, the line under it said the chat starts in a
// private folder, the start failed with a Retry card and an Add Folder sheet floated at the pane's
// corner, all at once. A picked folder now asks the host first (`workspace.useFolder`): a folder
// that needs the user's answer is asked about once, above the composer, before any chat starts.

type Call = [string, Record<string, unknown> | undefined];

function host(answer: (params: Record<string, unknown> | undefined) => unknown) {
  const calls: Call[] = [];
  const callNative = async (method: string, params?: Record<string, unknown>) => {
    calls.push([method, params]);
    const reply = answer(params);
    if (reply instanceof Error) throw reply;
    return reply;
  };
  return { calls, callNative };
}

test("a project folder is used at once, as the host spells it", async () => {
  const { calls, callNative } = host(() => ({ status: "ok", cwd: "/Users/me/project" }));
  const used: string[] = [];
  const ask = await pickFolder(callNative, "/Users/me/project/", (cwd) => used.push(cwd));
  expect(ask).toBeUndefined();
  expect(used).toEqual(["/Users/me/project"]);
  expect(calls).toEqual([["workspace.useFolder", { cwd: "/Users/me/project/" }]]);
});

test("the home folder is asked about and nothing starts there yet", async () => {
  const { callNative } = host(() => ({ status: "confirm", reason: "home", cwd: "/Users/me" }));
  const used: string[] = [];
  const ask = await pickFolder(callNative, "/Users/me", (cwd) => used.push(cwd));
  expect(ask).toEqual({ cwd: "/Users/me", reason: "home" });
  expect(used).toEqual([]);
});

test("the disk's root is refused with no way to use it", async () => {
  const { callNative } = host(() => ({ status: "refused", reason: "root", cwd: "/" }));
  const used: string[] = [];
  expect(await pickFolder(callNative, "/", (cwd) => used.push(cwd))).toEqual({ cwd: "/", reason: "root" });
  expect(used).toEqual([]);
});

test("a host without the question uses the folder as before", async () => {
  const { callNative } = host(() => Object.assign(new Error("unsupported"), { code: "unsupported" }));
  const used: string[] = [];
  expect(await pickFolder(callNative, "/Users/me/project", (cwd) => used.push(cwd))).toBeUndefined();
  expect(used).toEqual(["/Users/me/project"]);
});

// Use Home Folder is the answer and the start in one click: no Retry, no second question.
test("the answer confirms with the host, then uses the folder at once", async () => {
  const { calls, callNative } = host((params) =>
    params?.confirm ? { status: "ok", cwd: "/Users/me" } : { status: "confirm", reason: "home", cwd: "/Users/me" },
  );
  const used: string[] = [];
  await confirmFolder(callNative, { cwd: "/Users/me", reason: "home" }, (cwd) => used.push(cwd));
  expect(calls).toEqual([["workspace.useFolder", { cwd: "/Users/me", confirm: true }]]);
  expect(used).toEqual(["/Users/me"]);
});

test("a refused answer uses nothing and says why", async () => {
  const { callNative } = host(() => Object.assign(new Error("gesture"), { code: "transport.gesture_required" }));
  const used: string[] = [];
  await expect(confirmFolder(callNative, { cwd: "/Users/me", reason: "home" }, (cwd) => used.push(cwd))).rejects.toBeDefined();
  expect(used).toEqual([]);
});

test("the home question warns about the whole home folder and offers the private folder", () => {
  const html = renderToStaticMarkup(
    <StartFolderAsk ask={{ cwd: "/Users/me", reason: "home" }} onUse={() => undefined} onCancel={() => undefined} />,
  );
  expect(html).toContain("Start this chat in your home folder?");
  expect(html).toContain("macOS may ask for access to Photos, Documents and other folders.");
  expect(html).toContain(">Use Home Folder</button>");
  expect(html).toContain(">Use Private Folder</button>");
});

test("with a workspace folder the other button keeps it", () => {
  const html = renderToStaticMarkup(
    <StartFolderAsk
      ask={{ cwd: "/Users/me", reason: "home" }}
      current="/Users/me/project"
      onUse={() => undefined}
      onCancel={() => undefined}
    />,
  );
  expect(html).toContain(">Keep project</button>");
  expect(html).not.toContain("Use Private Folder");
});

test("the root's line has no button that would use it", () => {
  const html = renderToStaticMarkup(
    <StartFolderAsk ask={{ cwd: "/", reason: "root" }} onUse={() => undefined} onCancel={() => undefined} />,
  );
  expect(html).toContain("Chats can’t start in /.");
  expect(html).not.toContain("Use Home Folder");
  expect(html).toContain(">Use Private Folder</button>");
});

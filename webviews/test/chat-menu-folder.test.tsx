// The chat menu's Open in Editor (folderActions.ts): for a project folder on this Mac the ··· menu
// starts with Open in Zed (the header's quick action no button shows by default) and holds the
// folder's actions in one Folder row; a chat with no folder here, or in its private agent-home
// folder, gets neither. Choosing Open in Zed asks the app to run `agentPane.openCwdInEditor` for the
// chat's session.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
// Base UI's menus read these window globals.
const windowKeys = [
  "HTMLElement",
  "Element",
  "Node",
  "ShadowRoot",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const keys = ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT", ...windowKeys] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let doc: Document;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const source = window as unknown as Record<string, unknown>;
  for (const key of windowKeys)
    scope[key] =
      typeof source[key] === "function" && !/^[A-Z]/.test(key) ? (source[key] as Function).bind(window) : source[key];
  doc = window.document;
});

afterAll(async () => {
  await act(async () => root?.unmount());
  await new Promise((resolve) => setTimeout(resolve, 0));
  await teardownDom(saved, { scope });
});

const labels = () =>
  [...doc.querySelectorAll(".acpmux-chat-menu-popover .acpmux-chat-menu-item")].map(
    (row) => row.querySelector(".acpmux-chat-menu-label")?.textContent,
  );

test("the ··· menu leads with Open in Zed and folds the folder's rows into Folder, only for a project on this Mac", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { folderRow } = await import("../src/agent-session/acpmux/header/folderRow");
  const { instructionsRow, projectFilesRow } = await import("../src/agent-session/acpmux/header/instructionsRow");
  const { FolderHostContext, FOLDER_ACTIONS, folderActions, setEditors } =
    await import("../src/agent-session/acpmux/folderActions");
  type Host = import("../src/agent-session/acpmux/folderActions").FolderHost;
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  const { translate } = await import("../src/agent-session/acpmux/i18n");
  setEditors({ default: { id: "zed", name: "Zed" }, others: [{ id: "cursor", name: "Cursor" }] });
  const asked: unknown[][] = [];
  const hostFor = (folder: string): Host => ({
    folder,
    session: "s1",
    run: (id, session, app) => void asked.push([id, session, app]),
    openFile: () => undefined,
    copy: () => undefined,
  });
  const menuFor = async (folder: string | undefined) => {
    const host = folder ? hostFor(folder) : undefined;
    const chat = { cwd: folder ?? "/Users/me/src/app", family: "claude" };
    const project = [instructionsRow(chat, () => undefined), projectFilesRow(chat, () => undefined)];
    act(() => root?.unmount());
    root = createRoot(doc.getElementById("root")!);
    act(() =>
      root!.render(
        <FolderHostContext.Provider value={host}>
          <ChatHeaderTools
            onTerminal={() => {}}
            onBrowser={() => {}}
            summary={null}
            menu={() => {
              const row = folderRow(host ? folderActions(host, undefined, translate) : undefined, project);
              return row ? [row] : [];
            }}
          />
        </FolderHostContext.Provider>,
      ),
    );
    await act(async () => void openPicker("Chat actions"));
    return labels();
  };

  expect(await menuFor("/Users/me/src/app")).toEqual(["Open in Zed", "Folder"]);
  await act(async () => (doc.querySelector(".acpmux-chat-menu-popover .acpmux-chat-menu-item") as HTMLElement).click());
  expect(asked).toEqual([[FOLDER_ACTIONS.openInEditor, "s1", undefined]]);

  // No folder on this Mac (a peer's, an SSH host's or a Cloud chat): no Open in Editor.
  expect(await menuFor(undefined)).toEqual(["Folder"]);
  // A private agent-home folder is not a project: no Open in Editor at the top.
  expect(await menuFor("/Users/me/Library/Application Support/cmux/agent-home/6b16a112")).toEqual(["Folder"]);
  setEditors(undefined);
});

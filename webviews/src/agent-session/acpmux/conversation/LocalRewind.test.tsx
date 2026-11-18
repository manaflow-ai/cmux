// Back to before this turn in a chat on this machine (LocalRewind.tsx): the prompt draws the Rewind
// only where acpmux took a checkpoint; the ask runs the dry run when it opens, offers the files with
// their count or disables them with the reason, and Confirm sends the conversation and files flags.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { translate } from "../i18n";
import { TranscriptReadOnly } from "./readOnly";
import { TurnActionsContext, type TurnActions } from "./turnActions";
import { UserBubble } from "./UserBubble";
import { LocalRewindButton, LocalRewindNotice, LocalRewindPanel } from "./LocalRewind";
import { parseDryRun, type RewindChoice, type RewindDryRun } from "./localRewindModel";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "MouseEvent",
    "KeyboardEvent",
    "FocusEvent",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    if (!saved.has(key)) saved.set(key, scope[key]);
  const win = dom.window;
  // The ask's popover is Base UI's: it places itself on animation frames.
  Object.assign(scope, {
    window: win,
    document: win.document,
    navigator: win.navigator,
    Node: win.Node,
    HTMLElement: win.HTMLElement,
    Element: win.Element,
    MouseEvent: win.MouseEvent,
    KeyboardEvent: win.KeyboardEvent,
    FocusEvent: win.FocusEvent,
    getComputedStyle: win.getComputedStyle.bind(win),
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(Date.now()), 0),
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    localStorage: win.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(node: React.ReactNode): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

/// Lets the dry run answer and the popover place itself (its frames are timeouts here).
const settle = () =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

const row = (): AcpmuxRow => ({
  id: "user-4",
  version: 1,
  kind: "user",
  at: Date.now() - 10_000,
  text: "Now cover it",
});

/// A local rewind whose dry run answers `dry` and whose applies the test settles by hand.
function manual(dry: unknown, ready = ["user-4"]) {
  const dryRuns: string[] = [];
  const applies: { rowId: string; choice: RewindChoice; resolve(): void; reject(error: unknown): void }[] = [];
  const localRewind: NonNullable<TurnActions["localRewind"]> = {
    ready: new Set(ready),
    dryRun: async (rowId) => {
      dryRuns.push(rowId);
      return parseDryRun(dry);
    },
    apply: (rowId, choice) =>
      new Promise((resolve, reject) => applies.push({ rowId, choice, resolve: () => resolve(), reject })),
  };
  return { localRewind, dryRuns, applies };
}

const FILES = {
  conversation: "fork",
  files: { checkpointId: "cp", total: 3, paths: ["a", "b", "c"], baseChanged: false, complete: true },
};

const rewindButton = (container: HTMLElement) => container.querySelector<HTMLButtonElement>(".cv-turn-rewind");
const ask = () => document.querySelector<HTMLFormElement>(".cv-rewind-ask");
const checks = () => [...document.querySelectorAll<HTMLInputElement>(".cv-rewind-ask input[type=checkbox]")];
const confirmButton = () => document.querySelector<HTMLButtonElement>(".cv-rewind-ask button[type=submit]");

test("no local rewind, a prompt without a checkpoint, or a read-only transcript draws no button", async () => {
  expect(rewindButton(await render(<UserBubble row={row()} text="Now cover it" />))).toBeNull();
  const off = manual(FILES, ["user-1"]);
  expect(
    rewindButton(
      await render(
        <TurnActionsContext.Provider value={{ localRewind: off.localRewind }}>
          <UserBubble row={row()} text="Now cover it" />
        </TurnActionsContext.Provider>,
      ),
    ),
  ).toBeNull();
  const on = manual(FILES);
  expect(
    rewindButton(
      await render(
        <TranscriptReadOnly.Provider value={true}>
          <TurnActionsContext.Provider value={{ localRewind: on.localRewind }}>
            <UserBubble row={row()} text="Now cover it" />
          </TurnActionsContext.Provider>
        </TranscriptReadOnly.Provider>,
      ),
    ),
  ).toBeNull();
});

test("the prompt's Rewind opens the ask, which dry-runs and offers the files with their count", async () => {
  const { localRewind, dryRuns, applies } = manual(FILES);
  const container = await render(
    <TurnActionsContext.Provider value={{ localRewind }}>
      <UserBubble row={row()} text="Now cover it" />
    </TurnActionsContext.Provider>,
  );
  const button = rewindButton(container)!;
  expect(button.getAttribute("aria-label")).toBe(translate("turn.rewind"));
  await act(async () => button.click());
  await settle();
  expect(dryRuns).toEqual(["user-4"]);
  expect(ask()).not.toBeNull();
  const [conversation, files] = checks();
  expect(conversation!.checked).toBe(true);
  expect(files!.checked).toBe(false);
  expect(files!.disabled).toBe(false);
  expect(files!.closest("label")!.textContent).toContain(
    translate("rewind.alsoFilesCount", { count: translate("rewind.fileCount", { n: 3 }) }),
  );
  await act(async () => files!.click());
  await act(async () => confirmButton()!.click());
  expect(applies.map(({ rowId, choice }) => [rowId, choice])).toEqual([
    ["user-4", { conversation: true, files: true }],
  ]);
  expect(ask()!.dataset.phase).toBe("running");
  await act(async () => applies[0]!.resolve());
  expect(ask()).toBeNull();
});

test("the default Confirm sends the conversation alone", async () => {
  const { localRewind, applies } = manual(FILES);
  await render(
    <TurnActionsContext.Provider value={{ localRewind }}>
      <LocalRewindButton rowId="user-4" look="checks" />
    </TurnActionsContext.Provider>,
  );
  await act(async () => document.querySelector<HTMLButtonElement>(".cv-turn-rewind")!.click());
  await settle();
  await act(async () => confirmButton()!.click());
  expect(applies[0]!.choice).toEqual({ conversation: true, files: false });
});

test("files that can't be reset are disabled with the reason", async () => {
  const { localRewind } = manual({
    conversation: "fork",
    files: null,
    filesBlocked: { reason: "shared", message: "", sharedWith: [{ sessionId: "s2", title: "Fix the pager" }] },
  });
  await render(
    <TurnActionsContext.Provider value={{ localRewind }}>
      <LocalRewindButton rowId="user-4" look="checks" />
    </TurnActionsContext.Provider>,
  );
  await act(async () => document.querySelector<HTMLButtonElement>(".cv-turn-rewind")!.click());
  await settle();
  const files = checks()[1]!;
  expect(files.disabled).toBe(true);
  const why = document.querySelector<HTMLElement>("[data-blocked-reason]")!;
  expect(why.dataset.blockedReason).toBe("shared");
  expect(why.textContent).toBe(translate("rewind.blocked.sharedWith", { title: "Fix the pager" }));
  expect(files.getAttribute("aria-describedby")).toBe(why.id);
});

test("a refused rewind says why and lets Confirm try again", async () => {
  const { localRewind, applies } = manual(FILES);
  await render(
    <TurnActionsContext.Provider value={{ localRewind }}>
      <LocalRewindButton rowId="user-4" look="checks" />
    </TurnActionsContext.Provider>,
  );
  await act(async () => document.querySelector<HTMLButtonElement>(".cv-turn-rewind")!.click());
  await settle();
  await act(async () => confirmButton()!.click());
  await act(async () => applies[0]!.reject(Object.assign(new Error("x"), { reason: "fork.unsupported" })));
  expect(ask()!.dataset.phase).toBe("failed");
  expect(document.querySelector(".cv-rewind-ask__error")!.textContent).toBe(
    translate("rewind.failedReason", { reason: translate("rewind.blocked.forkUnsupported") }),
  );
  expect(confirmButton()!.disabled).toBe(false);
  await act(async () => confirmButton()!.click());
  expect(applies.length).toBe(2);
});

test("the inline look asks under the prompt instead of in a popover", async () => {
  const { localRewind, dryRuns } = manual(FILES);
  const container = await render(
    <TurnActionsContext.Provider value={{ localRewind }}>
      <LocalRewindButton rowId="user-4" look="inline" />
      <UserBubble row={{ ...row(), id: "user-9" }} text="other" />
    </TurnActionsContext.Provider>,
  );
  expect(container.querySelector(".cv-rewind-inline")).toBeNull();
  // The inline slot is UserBubble's: render the prompt the button belongs to.
  await act(async () =>
    root!.render(
      <TurnActionsContext.Provider value={{ localRewind }}>
        <LocalRewindButton rowId="user-4" look="inline" />
        <UserBubble row={row()} text="Now cover it" />
      </TurnActionsContext.Provider>,
    ),
  );
  await act(async () => container.querySelector<HTMLButtonElement>("[data-rewind-local]")!.click());
  await settle();
  expect(dryRuns).toEqual(["user-4"]);
  expect(container.querySelector(".cv-rewind-inline .cv-rewind-ask")).not.toBeNull();
  // Cancel closes it.
  await act(async () =>
    container.querySelector<HTMLButtonElement>(".cv-rewind-inline button[aria-keyshortcuts=Escape]")!.click(),
  );
  expect(container.querySelector(".cv-rewind-inline")).toBeNull();
});

test("the segmented look disables Files and Both when the files can't be reset", async () => {
  const dry: RewindDryRun = parseDryRun({
    conversation: "fork",
    files: null,
    filesBlocked: { reason: "not_git", message: "" },
  });
  await render(
    <LocalRewindPanel
      look="segmented"
      phase="ready"
      dry={dry}
      choice={{ conversation: true, files: false }}
      onChoice={() => {}}
      onConfirm={() => {}}
      onCancel={() => {}}
    />,
  );
  const segments = [...document.querySelectorAll<HTMLButtonElement>(".cv-rewind-ask__segments button")];
  expect(segments.map((segment) => segment.textContent)).toEqual([
    translate("rewind.conversation"),
    translate("rewind.files"),
    translate("rewind.both"),
  ]);
  expect(segments.map((segment) => segment.disabled)).toEqual([false, true, true]);
  expect(document.querySelector("[data-blocked-reason]")!.textContent).toBe(translate("rewind.blocked.notGit"));
});

test("the notice after a rewind says what went back and runs Undo", async () => {
  let undone = 0;
  const container = await render(
    <LocalRewindNotice
      undo={{ original: "chat-1", rewound: "fork-2", conversation: true, files: 0 }}
      undoing={false}
      onUndo={() => void undone++}
      onDismiss={() => {}}
    />,
  );
  expect(container.textContent).toContain(translate("rewind.done"));
  const undo = [...container.querySelectorAll("button")].find(
    (button) => button.textContent === translate("rewind.undo"),
  )!;
  await act(async () => undo.click());
  expect(undone).toBe(1);
  await act(async () =>
    root!.render(
      <LocalRewindNotice
        undo={{ original: "chat-1", conversation: false, files: 2 }}
        undoing={true}
        onUndo={() => {}}
        onDismiss={() => {}}
      />,
    ),
  );
  expect(container.textContent).toContain(
    translate("rewind.doneFiles", { count: translate("rewind.fileCount", { n: 2 }) }),
  );
  expect(container.textContent).toContain(translate("rewind.undoing"));
});

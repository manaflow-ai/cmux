// A file attachment's download link comes from the host (`AttachmentService.url`). When it cannot be
// had, the row says so on the spot, and the button asks again; a click that did nothing read as a
// broken button.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("a download whose link cannot be had says so, and asking again clears it", async () => {
  const { createRoot } = await import("react-dom/client");
  const { AttachmentContext, MessageAttachments } = await import("../src/pages/home-channels/AttachmentViews");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/home-channels/generated/strings.json")).default;
  const strings = createStrings(table, ["en"]);
  const failing = { value: true };
  const asked: string[] = [];
  const service = {
    url: async (_conversation: string, hash: string) => {
      asked.push(hash);
      if (failing.value) throw new Error("the daemon does not answer");
      return "http://localhost/#file";
    },
  } as unknown as import("../src/pages/home-channels/attachmentService").AttachmentService;
  const part = { type: "attachment" as const, hash: "h1", name: "report.pdf", mimeType: "application/pdf", byteCount: 2048 };
  root = createRoot(host);
  act(() =>
    root!.render(
      <AttachmentContext.Provider value={service}>
        <MessageAttachments conversation="c" parts={[part]} strings={strings} />
      </AttachmentContext.Provider>,
    ),
  );
  const meta = () => host.querySelector(".hc-att-file .hc-att-meta");
  const button = () => host.querySelector<HTMLButtonElement>(".hc-att-download")!;
  expect(meta()?.textContent).toContain("2");

  await act(async () => button().click());
  expect(asked).toEqual(["h1"]);
  expect(meta()?.getAttribute("role")).toBe("alert");
  expect(meta()?.textContent).toBe(strings.t("attachment.downloadFailed"));

  failing.value = false;
  await act(async () => button().click());
  expect(asked).toEqual(["h1", "h1"]);
  expect(meta()?.getAttribute("role")).toBeNull();
  expect(meta()?.textContent).not.toBe(strings.t("attachment.downloadFailed"));
});

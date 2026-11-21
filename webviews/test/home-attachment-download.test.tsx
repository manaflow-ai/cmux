// A file attachment's download link comes from the host (`AttachmentService.url`). When it cannot be
// had, the row says so on the spot, and the button asks again; a click that did nothing read as a
// broken button.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

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

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
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
  const part = {
    type: "attachment" as const,
    hash: "h1",
    name: "report.pdf",
    mimeType: "application/pdf",
    byteCount: 2048,
  };
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

// The download button appears on its card's hover or focus through the shared reveal (ui/motion
// .ui-reveal: in over micro, out over quick, still with motion off), not a fade of its own.
test("a file's download button is its card's shared hover reveal", async () => {
  const { readFileSync } = await import("node:fs");
  const { join } = await import("node:path");
  const button = host.querySelector<HTMLButtonElement>(".hc-att-download")!;
  expect(button.classList.contains("ui-reveal")).toBe(true);
  expect(button.closest(".hc-att-file")!.classList.contains("ui-reveal-host")).toBe(true);
  // Home's own sheet no longer hides it or times its fade, so the primitive's timing is the one.
  const ledger = readFileSync(join(import.meta.dir, "../src/pages/home-channels/ledger.css"), "utf8");
  const own = ledger.match(/\.hc-att-download\s*\{[^}]*\}/)![0];
  expect(own).not.toMatch(/opacity|transition/);
});

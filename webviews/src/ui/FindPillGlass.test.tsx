// The find pill's glass (hq RFD "Native or our own web view, per surface", build item 5; the find-pill-glass
// experiment): off by default the pill draws its own tint and blur and asks the App for no glass; with
// `experiments.findPillGlass` (arm host) it marks data-host-glass="chip", so the App draws its tooltip glass
// under it where it can (glass/hostGlass.ts).
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "../pages/settings/testDom";

const restore = installDom();
afterAll(() => restore());
const { createRoot } = await import("react-dom/client");
const { FindPill } = await import("./FindPill");

async function pillGlass(hostGlass?: boolean): Promise<{ level: string | null; cover: boolean }> {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  const none = () => undefined;
  await act(async () =>
    root.render(
      <FindPill
        query="needle"
        onQueryChange={none}
        status="1 of 3"
        noMatches={false}
        canStep
        onNext={none}
        onPrevious={none}
        onClose={none}
        labels={{ placeholder: "Find", previous: "Previous", next: "Next", close: "Close" }}
        icon={() => null}
        hostGlass={hostGlass}
      />,
    ),
  );
  const pill = host.querySelector(".find-pill");
  const result = {
    level: pill?.getAttribute("data-host-glass") ?? null,
    cover: pill?.hasAttribute("data-host-glass-cover") ?? false,
  };
  await act(async () => root.unmount());
  host.remove();
  return result;
}

async function withArm<T>(arm: string, run: () => Promise<T>): Promise<T> {
  const savedArms = globalThis.cmuxExperiments;
  globalThis.cmuxExperiments = { "find-pill-glass": arm };
  try {
    return await run();
  } finally {
    globalThis.cmuxExperiments = savedArms;
  }
}

test("the find pill draws its own glass by default (experiments.findPillGlass off)", async () => {
  expect(await pillGlass()).toEqual({ level: null, cover: false });
});

test("experiments.findPillGlass (arm host) puts the find pill on the App's tooltip glass", async () => {
  expect(await withArm("host", () => pillGlass())).toEqual({ level: "chip", cover: false });
});

test("a caller's hostGlass wins over the arm either way", async () => {
  expect(await withArm("host", () => pillGlass(false))).toEqual({ level: null, cover: false });
  expect(await pillGlass(true)).toEqual({ level: "chip", cover: false });
});

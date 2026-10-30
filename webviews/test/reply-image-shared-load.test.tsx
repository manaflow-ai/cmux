// l10n-allow-file: test fixture image sources, not shipped UI.
// Two tiles of one image (the transcript's and the Gallery's) ask the host once. The one that did not
// ask still shows the image when the first load ends, and asks itself if that load failed.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { useDom } from "./support/unknownWrite";

const dom = useDom();
const data = "data:image/png;base64,aW1hZ2U=";

afterEach(async () => {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  setChipHost(undefined);
  resetLinkStore();
});

async function setup(reply: (call: number) => unknown) {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { seedLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { ReplyImage } = await import("../src/agent-session/acpmux/chips/ReplyImage");
  seedLinkStore({ policy: { remoteImages: "always" } });
  const releases: (() => void)[] = [];
  let calls = 0;
  setChipHost(
    () =>
      new Promise((resolve) => {
        const call = calls++;
        releases.push(() => resolve(reply(call)));
      }),
  );
  return { ReplyImage, releases, calls: () => calls };
}

test("a second tile of an image still loading shows it when the first load ends", async () => {
  const src = "https://example.com/shared-ok.png";
  const { ReplyImage, releases, calls } = await setup(() => ({ src: data }));
  await dom.render(
    <>
      <ReplyImage src={src} alt="a" fallback={null} />
      <ReplyImage src={src} alt="b" fallback={null} />
    </>,
  );
  await act(async () => void (await Promise.resolve()));
  expect(calls()).toBe(1);
  expect(dom.host().querySelectorAll("img").length).toBe(0);
  await act(async () => releases[0]!());
  expect([...dom.host().querySelectorAll("img")].map((img) => img.getAttribute("src"))).toEqual([data, data]);
  expect(calls()).toBe(1);
});

test("when the first load fails the other tile asks the host itself", async () => {
  const src = "https://example.com/shared-retry.png";
  const { ReplyImage, releases, calls } = await setup((call) => (call === 0 ? undefined : { src: data }));
  await dom.render(
    <>
      <ReplyImage src={src} alt="a" fallback={null} />
      <ReplyImage src={src} alt="b" fallback={null} />
    </>,
  );
  await act(async () => void (await Promise.resolve()));
  expect(calls()).toBe(1);
  await act(async () => releases[0]!());
  await act(async () => void (await Promise.resolve()));
  expect(calls()).toBe(2);
  await act(async () => releases[1]!());
  expect(dom.host().querySelectorAll("img").length).toBe(1);
});

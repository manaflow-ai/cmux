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
  await act(async () => {
    await Promise.resolve();
  });
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
  await act(async () => {
    await Promise.resolve();
  });
  expect(calls()).toBe(1);
  await act(async () => releases[0]!());
  await act(async () => {
    await Promise.resolve();
  });
  expect(calls()).toBe(2);
  await act(async () => releases[1]!());
  expect(dom.host().querySelectorAll("img").length).toBe(1);
});

test("every tile waiting on a failed load hears the retry that follows", async () => {
  const src = "https://example.com/shared-three.png";
  const { ReplyImage, releases, calls } = await setup((call) => (call === 0 ? undefined : { src: data }));
  await dom.render(
    <>
      <ReplyImage src={src} alt="a" fallback={null} />
      <ReplyImage src={src} alt="b" fallback={null} />
      <ReplyImage src={src} alt="c" fallback={null} />
    </>,
  );
  await act(async () => {
    await Promise.resolve();
  });
  expect(calls()).toBe(1);
  await act(async () => releases[0]!());
  await act(async () => {
    await Promise.resolve();
  });
  expect(calls()).toBe(2);
  await act(async () => releases[1]!());
  // The tile whose own load failed stays failed; both that waited draw the image the retry loaded.
  expect(dom.host().querySelectorAll("img").length).toBe(2);
  expect(calls()).toBe(2);
});

test("two files with identical bytes keep their own entries in the image viewer", async () => {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { seedLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { ReplyImage } = await import("../src/agent-session/acpmux/chips/ReplyImage");
  const { viewerImages } = await import("../src/agent-session/acpmux/summary/chatGallery");
  const { activity, tool } = await import("../src/gallery/fixtures/acpmux");
  const a = "/project/a.png";
  const b = "/project/b.png";
  seedLinkStore({
    paths: { [a]: { place: "root", folder: false }, [b]: { place: "root", folder: false } },
    policy: { remoteImages: "always" },
  });
  setChipHost(async () => ({ src: data }));
  await dom.render(
    <>
      <ReplyImage src={a} alt="" fallback={null} />
      <ReplyImage src={b} alt="" fallback={null} />
    </>,
  );
  await act(async () => {
    await Promise.resolve();
  });
  expect(dom.host().querySelectorAll("img").length).toBe(2);
  const rows = [activity([tool("Files", "read", "completed", { locations: [{ path: a }, { path: b }] })], 1)];
  const opened = viewerImages(rows, data, "", b);
  expect(opened.images.map((image) => image.path)).toEqual([a, b]);
  expect(opened.index).toBe(1);
  expect(viewerImages(rows, data, "", a).index).toBe(0);
});

test("a load that ends before the second tile subscribes still reaches it", async () => {
  const src = "https://example.com/shared-fast.png";
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { seedLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { ReplyImage } = await import("../src/agent-session/acpmux/chips/ReplyImage");
  seedLinkStore({ policy: { remoteImages: "always" } });
  let calls = 0;
  // The host answers at once, so the first load ends in microtasks, before effects subscribe.
  setChipHost(async () => (calls++ === 0 ? undefined : { src: data }));
  await dom.render(
    <>
      <ReplyImage src={src} alt="a" fallback={null} />
      <ReplyImage src={src} alt="b" fallback={null} />
    </>,
  );
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(calls).toBe(2);
  expect(dom.host().querySelectorAll("img").length).toBe(1);
});

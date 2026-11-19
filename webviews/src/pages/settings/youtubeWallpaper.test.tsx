// YouTube wallpapers (Leo: "yeah add youtube backgrounds too"): Moving wallpapers' Add YouTube
// Video… reads a pasted link, Start, End and Quality into the one canonical `youtube:` id of the
// video-wallpapers contract and writes it through the tile's own choose, so All Workspaces, This
// Workspace, and Light and Dark take it as they take any other background.
import { act } from "react";
import { afterAll, describe, expect, test } from "bun:test";
import { installDom } from "./testDom";
import { validate } from "./validate";
import { rowsByKey } from "./schema";
import { formatClock, linkSeconds, parseClock, parseYouTubeId, parseYouTubeLink, youtubeId } from "./youtubeWallpaper";
import { youtubeDraft } from "./components/YouTubeAdd";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const VIDEO = "dQw4w9WgXcQ";

describe("the youtube: id", () => {
  test("drops defaults and orders start, end, quality", () => {
    expect(youtubeId({ video: VIDEO, start: 0, end: null, quality: 1080 })).toBe(`youtube:${VIDEO}`);
    expect(youtubeId({ video: VIDEO, start: 90, end: 120, quality: 720 })).toBe(
      `youtube:${VIDEO}?start=90&end=120&quality=720`,
    );
    expect(youtubeId({ video: VIDEO, start: 0, end: 30, quality: 1080 })).toBe(`youtube:${VIDEO}?end=30`);
  });

  test("reads back what it writes, and refuses what the contract refuses", () => {
    expect(parseYouTubeId(`youtube:${VIDEO}?quality=2160&start=5`)).toEqual({
      video: VIDEO,
      start: 5,
      end: null,
      quality: 2160,
    });
    for (const bad of [
      `youtube:${VIDEO.slice(1)}`,
      `youtube:${VIDEO}?start=30&end=30`,
      `youtube:${VIDEO}?end=86401`,
      `youtube:${VIDEO}?quality=1000`,
      `youtube:${VIDEO}?start=1&start=2`,
      `youtube:${VIDEO}?loop=1`,
      `youtube:${VIDEO}|youtube:${VIDEO}`,
      `file:/${VIDEO}`,
    ])
      expect(parseYouTubeId(bad)).toBeNull();
  });
});

describe("a pasted link", () => {
  test("names its video from every YouTube link form", () => {
    for (const link of [
      `https://www.youtube.com/watch?v=${VIDEO}`,
      `https://youtube.com/watch?feature=share&v=${VIDEO}`,
      `https://m.youtube.com/watch?v=${VIDEO}`,
      `https://music.youtube.com/watch?v=${VIDEO}&list=RD`,
      `https://youtu.be/${VIDEO}`,
      `https://www.youtube.com/shorts/${VIDEO}`,
      `https://www.youtube.com/embed/${VIDEO}`,
      `https://www.youtube.com/live/${VIDEO}?si=abc`,
      `https://www.youtube-nocookie.com/embed/${VIDEO}`,
      `youtu.be/${VIDEO}`,
      `  ${VIDEO}  `,
      `youtube:${VIDEO}`,
    ])
      expect(parseYouTubeLink(link)?.video).toBe(VIDEO);
    for (const link of ["https://vimeo.com/123", `https://example.com/watch?v=${VIDEO}`, "not a link", ""])
      expect(parseYouTubeLink(link)).toBeNull();
  });

  test("takes its t= or start= as the start", () => {
    expect(parseYouTubeLink(`https://youtu.be/${VIDEO}?t=90`)?.start).toBe(90);
    expect(parseYouTubeLink(`https://www.youtube.com/watch?v=${VIDEO}&t=1m30s`)?.start).toBe(90);
    expect(parseYouTubeLink(`https://www.youtube.com/embed/${VIDEO}?start=42`)?.start).toBe(42);
    expect(parseYouTubeLink(`https://www.youtube.com/watch?v=${VIDEO}#t=1h2m3s`)?.start).toBe(3723);
    expect(linkSeconds("90s")).toBe(90);
    expect(linkSeconds("soon")).toBeNull();
  });

  test("times are typed as m:ss", () => {
    expect(parseClock("")).toBeUndefined();
    expect(parseClock("1:30")).toBe(90);
    expect(parseClock("1:02:03")).toBe(3723);
    expect(parseClock("45")).toBe(45);
    expect(parseClock("1:75")).toBeNull();
    expect(parseClock("abc")).toBeNull();
    expect(formatClock(90)).toBe("1:30");
    expect(formatClock(3723)).toBe("1:02:03");
  });

  test("the form's draft is the canonical id, or why it is not one yet", () => {
    expect(youtubeDraft("", "", "", 1080)).toEqual({ id: null, video: null, problem: null });
    expect(youtubeDraft("https://vimeo.com/1", "", "", 1080).problem).toBe(
      "settingsWindow.backdropPicker.youtubeNotVideo",
    );
    expect(youtubeDraft(`https://youtu.be/${VIDEO}?t=10`, "", "0:40", 720).id).toBe(
      `youtube:${VIDEO}?start=10&end=40&quality=720`,
    );
    // A typed Start wins over the link's own time.
    expect(youtubeDraft(`https://youtu.be/${VIDEO}?t=10`, "0:00", "", 1080).id).toBe(`youtube:${VIDEO}`);
    expect(youtubeDraft(`https://youtu.be/${VIDEO}`, "1:00", "0:30", 1080)).toMatchObject({
      id: null,
      video: VIDEO,
      problem: "settingsWindow.backdropPicker.youtubeBadRange",
    });
    expect(youtubeDraft(`https://youtu.be/${VIDEO}`, "1:xx", "", 1080).problem).toBe(
      "settingsWindow.backdropPicker.youtubeBadClock",
    );
  });

  test("the page accepts a youtube: id wherever it accepts a file: video", () => {
    for (const key of ["appearance.background", "appearance.backgroundLight", "appearance.backgroundDark"]) {
      const row = rowsByKey.get(key);
      if (!row) continue;
      expect(validate(row, `youtube:${VIDEO}?start=5&end=20`)).toBeNull();
      expect(validate(row, `youtube:${VIDEO}?quality=999`)).not.toBeNull();
    }
  });
});

const runs = (page: Awaited<ReturnType<typeof renderPage>>, op: string) =>
  page.provider.log.filter((entry) => entry.op === op).map((entry) => entry.params);

async function typeInto(field: HTMLInputElement, text: string) {
  await act(async () => {
    Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!.call(field, text);
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
}

/** Turns YouTube wallpapers on in the host lists (they ship off). */
async function offerYouTube(page: Awaited<ReturnType<typeof renderPage>>) {
  await act(async () => page.provider.setHost({ ...page.provider.host, youtube_wallpapers: true }));
  await settle();
}

async function openAdd(picker: HTMLElement) {
  const tile = picker.querySelector<HTMLButtonElement>("[data-youtube-add]")!;
  // The tile sits in Moving wallpapers, after the moving wallpapers the host lists.
  expect(tile.closest('[data-collection="video"]')).not.toBeNull();
  expect(tile.textContent).toContain("Add YouTube Video…");
  await act(async () => tile.click());
  await settle();
  const form = picker.querySelector<HTMLElement>('[data-card="youtube-add"]')!;
  // Under the group's tiles: opening it moves none of them.
  expect(form.closest('[data-collection="video"]')).not.toBeNull();
  return form;
}

test("Add YouTube Video… previews the link's thumbnail and writes the canonical id as a tile click does", async () => {
  const page = await renderPage({
    path: "/settings/personalization",
    mock: { values: { "appearance.background": "starryNight" } },
  });
  await offerYouTube(page);
  const picker = page.container.querySelector<HTMLElement>('[data-card="backdrop"]')!;
  const form = await openAdd(picker);
  const submit = form.querySelector<HTMLButtonElement>('button[type="submit"]')!;
  expect(submit.disabled).toBe(true);
  // Before a link: an empty 16:9 box, so reading one changes no height.
  expect(form.querySelector(".youtube-add-preview .backdrop-none")).not.toBeNull();

  await typeInto(form.querySelector<HTMLInputElement>('input[type="url"]')!, "https://vimeo.com/1");
  expect(form.querySelector("output")!.textContent).toBe("Paste a link to a YouTube video.");
  expect(submit.disabled).toBe(true);

  await typeInto(
    form.querySelector<HTMLInputElement>('input[type="url"]')!,
    `https://www.youtube.com/watch?v=${VIDEO}&t=1m30s`,
  );
  // The thumbnail comes through the host's backdrop/ route, as every tile's does.
  expect(form.querySelector<HTMLImageElement>(".youtube-add-preview img")!.getAttribute("src")).toBe(
    `backdrop/${encodeURIComponent(encodeURIComponent(`youtube:${VIDEO}`))}`,
  );
  // The link's time stands in Start until one is typed.
  const start = form.querySelector<HTMLInputElement>('[data-youtube-field="start"]')!;
  expect(start.placeholder).toBe("1:30");
  await typeInto(form.querySelector<HTMLInputElement>('[data-youtube-field="end"]')!, "2:00");
  expect(form.querySelector("output")!.textContent).toBe("");
  await act(async () => submit.click());
  await settle();

  expect(runs(page, "cmux.settings.set").at(-1)).toMatchObject({
    key: "appearance.background",
    value: `youtube:${VIDEO}?start=90&end=120`,
  });
  // Used, the form closes and the video is a chosen tile in Moving wallpapers, with Remove.
  expect(picker.querySelector('[data-card="youtube-add"]')).toBeNull();
  const moving = picker.querySelector<HTMLElement>('[data-collection="video"]')!;
  const tile = moving.querySelector<HTMLButtonElement>('.backdrop-tile[aria-label="YouTube Video"]')!;
  expect(tile.getAttribute("aria-pressed")).toBe("true");
  expect(tile.querySelector(".backdrop-badge")).not.toBeNull();
  expect(moving.querySelector<HTMLButtonElement>('[aria-label="Remove YouTube Video"]')!.disabled).toBe(true);
  // Opacity and Material stay in the card for a video.
  expect(picker.querySelector('[data-row-key="appearance.backgroundOpacity"]')).not.toBeNull();
  expect(picker.querySelector('[data-row-key="appearance.backgroundBlur"]')).not.toBeNull();
  page.unmount();
});

test("a YouTube video the host lists shows its thumbnail and title, and one not in use can be removed", async () => {
  const id = `youtube:${VIDEO}?quality=720`;
  const page = await renderPage({
    path: "/settings/personalization",
    mock: { values: { "appearance.background": "starryNight" } },
  });
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      backdrops: [
        ...(page.provider.host.backdrops ?? []),
        {
          id,
          title: "Lofi Rain",
          attribution: "YouTube · Lofi Rain",
          collection: "video",
          collection_title: "Moving wallpapers",
          video: true,
          youtube: { video: VIDEO, start: 0, end: null, quality: 720 },
        },
      ],
    }),
  );
  await settle();
  const picker = page.container.querySelector<HTMLElement>('[data-card="backdrop"]')!;
  const moving = picker.querySelector<HTMLElement>('[data-collection="video"]')!;
  const tile = moving.querySelector<HTMLButtonElement>('[aria-label="Lofi Rain"]')!;
  expect(tile.querySelector("img")!.getAttribute("src")).toBe(`backdrop/${encodeURIComponent(encodeURIComponent(id))}`);
  // One Moving wallpapers group: the listed moving wallpapers, then the Add tile.
  expect(picker.querySelectorAll('[data-collection="video"]').length).toBe(1);
  const remove = moving.querySelector<HTMLButtonElement>('[aria-label="Remove Lofi Rain"]')!;
  expect(remove.disabled).toBe(false);
  await act(async () => remove.click());
  await settle();
  expect(runs(page, "cmux.settings.backdrop.image.remove").at(-1)).toMatchObject({ id });
  expect(moving.querySelector('[aria-label="Lofi Rain"]')).toBeNull();
  page.unmount();
});

test("on This Workspace, Add YouTube Video… chooses that workspace's own background", async () => {
  const page = await renderPage({
    path: "/settings/personalization?focus=personalization.background&workspace=ws-1",
    mock: {
      values: { "appearance.background": "starryNight" },
      workspaceBackgrounds: [{ workspace: "ws-1", title: "Research", value: null }],
    },
  });
  await offerYouTube(page);
  const picker = page.container.querySelector<HTMLElement>('[data-card="backdrop"]')!;
  await act(async () => picker.querySelector<HTMLInputElement>('[aria-label="This Workspace (Research)"]')!.click());
  await settle();
  const form = await openAdd(picker);
  await typeInto(form.querySelector<HTMLInputElement>('input[type="url"]')!, `https://youtu.be/${VIDEO}`);
  await act(async () => form.querySelector<HTMLButtonElement>('button[type="submit"]')!.click());
  await settle();
  expect(runs(page, "cmux.settings.backdrop.workspace.set").at(-1)).toMatchObject({
    workspace: "ws-1",
    value: `youtube:${VIDEO}`,
  });
  expect(runs(page, "cmux.settings.set").length).toBe(0);
  page.unmount();
});

test("YouTube wallpapers ship off: no Add tile unless the host turns them on, but a video in use keeps its tile", async () => {
  const page = await renderPage({
    path: "/settings/personalization",
    mock: { values: { "appearance.background": `youtube:${VIDEO}` } },
  });
  await settle();
  const picker = () => page.container.querySelector<HTMLElement>('[data-card="backdrop"]')!;
  const tile = () =>
    picker().querySelector<HTMLButtonElement>('[data-collection="video"] [aria-label="YouTube Video"]');
  // Absent: off.
  expect(page.provider.host.youtube_wallpapers).toBeUndefined();
  expect(picker().querySelector("[data-youtube-add]")).toBeNull();
  expect(tile()!.getAttribute("aria-pressed")).toBe("true");
  // False: off.
  await act(async () => page.provider.setHost({ ...page.provider.host, youtube_wallpapers: false }));
  await settle();
  expect(picker().querySelector("[data-youtube-add]")).toBeNull();
  expect(tile()!.getAttribute("aria-pressed")).toBe("true");
  // True: offered.
  await offerYouTube(page);
  expect(picker().querySelector("[data-youtube-add]")).not.toBeNull();
  page.unmount();
});

test("off, with no moving wallpaper and no YouTube video in use, the picker draws no Moving wallpapers group of its own", async () => {
  const page = await renderPage({
    path: "/settings/personalization",
    mock: { values: { "appearance.background": "starryNight" } },
  });
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      backdrops: (page.provider.host.backdrops ?? []).filter((choice) => choice.collection !== "video"),
    }),
  );
  await settle();
  const picker = page.container.querySelector<HTMLElement>('[data-card="backdrop"]')!;
  expect(picker.querySelector('[data-collection="video"]')).toBeNull();
  page.unmount();
});

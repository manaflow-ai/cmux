import { expect, test } from "bun:test";
import { activity, assistant, summary, tool, user } from "../src/gallery/fixtures/acpmux";
import { renderTool } from "../src/gallery/fixtures/renders";
import { chatGallery, galleryItems, viewerImages } from "../src/agent-session/acpmux/summary/chatGallery";

const png = "data:image/png;base64,aW1hZ2U=";
const screenshot = (status = "completed") => tool("Screenshot", "read", status, { images: [png] });

test("a tool screenshot with a prose final is a gallery output", () => {
  const rows = [user("Take a screenshot", 3), activity([screenshot()], 2), assistant("Done.", 1), summary(1)];
  expect(chatGallery(rows)).toEqual([{ kind: "tool", key: png, source: png }]);
});

test("tool and assistant copies of the same image have one gallery entry in transcript order", () => {
  const reply = assistant(`![Screenshot](${png})`, 1);
  const call = activity([screenshot(), screenshot()], 2);
  expect(chatGallery([call, reply])).toHaveLength(1);
  expect(chatGallery([reply, call])).toEqual([{ kind: "image", key: png, src: png, alt: "Screenshot" }]);
});

test("unfinished calls are excluded until completion, including early envelope images", () => {
  for (const status of ["pending", "in_progress"]) {
    const pending = activity(
      [
        tool("Screenshot", "read", status, {
          images: [png],
          output: JSON.stringify({ content: [{ type: "image", data: "aW1hZ2U=", mimeType: "image/png" }] }),
        }),
      ],
      2,
    );
    expect(chatGallery([pending])).toEqual([]);
    const completed = { ...pending, items: [screenshot()] };
    expect(chatGallery([completed])).toHaveLength(1);
  }
});

test("discovers an MCP envelope, local image, PDF, video and audio without reading files", () => {
  const paths = ["/project/chart.png", "/project/report.pdf", "/project/demo.mp4", "/project/voice.wav"];
  const call = tool("Outputs", "read", "completed", {
    output: JSON.stringify({ content: [{ type: "image", data: "aW1hZ2U=", mimeType: "image/png" }] }),
    locations: paths.map((path) => ({ path })),
  });
  expect(chatGallery([activity([call], 1)]).map((item) => item.kind === "tool" && item.source)).toEqual([
    png,
    ...paths,
  ]);
});

test("completed tool media survives a live turn and partial history; renders still wait for its summary", () => {
  const call = activity([screenshot(), renderTool({ html: "<p>Chart</p>", title: "Chart" })], 2);
  const prompt = user("Chart", 3);
  expect(chatGallery([call]).map((item) => item.kind)).toEqual(["tool"]);
  expect(chatGallery([prompt, call]).map((item) => item.kind)).toEqual(["tool"]);
  expect(chatGallery([prompt, call, summary(1)]).map((item) => item.kind)).toEqual(["tool", "render"]);
  expect(chatGallery([prompt, summary(3), call]).map((item) => item.kind)).toEqual(["tool"]);
});

test("gallery discovery stays within the supplied session rows", () => {
  const parent = [user("Delegate a screenshot", 3), assistant("Delegated.", 1), summary(1)];
  const child = [user("Screenshot", 3), activity([screenshot()], 2), summary(1)];
  expect(chatGallery(parent)).toEqual([]);
  expect(chatGallery(child)).toHaveLength(1);
});

test("cached activity discovery does not reparse unchanged tool output", () => {
  let reads = 0;
  const call = screenshot();
  Object.defineProperty(call.tool!, "output", {
    get: () => {
      reads += 1;
      return "";
    },
  });
  const row = activity([call], 1);
  chatGallery([row]);
  const first = reads;
  expect(first).toBeGreaterThan(0);
  chatGallery([row, assistant("Streaming next reply", 0)]);
  expect(reads).toBe(first);
});

test("filters preserve tool media and render ordering", () => {
  const rows = [user("Outputs", 3), activity([screenshot(), renderTool({ html: "<p>Render</p>" })], 2), summary(1)];
  const items = chatGallery(rows);
  expect(galleryItems(items, "all")).toBe(items);
  expect(galleryItems(items, "tool").map((item) => item.kind)).toEqual(["tool"]);
  expect(galleryItems(items, "image")).toEqual([]);
  expect(galleryItems(items, "render").map((item) => item.kind)).toEqual(["render"]);
});

test("the image viewer steps through reply and tool data images, skipping files it cannot draw", () => {
  const other = "data:image/png;base64,b3RoZXI=";
  const rows = [
    user("Outputs", 3),
    activity(
      [
        tool("Shot", "read", "completed", { images: [png] }),
        tool("Files", "read", "completed", {
          locations: [{ path: "/project/chart.png" }, { path: "/project/demo.mp4" }],
        }),
      ],
      2,
    ),
    assistant(`![Other](${other})`, 1),
    summary(1),
  ];
  const opened = viewerImages(rows, png, "");
  expect(opened.images.map((image) => image.src)).toEqual([png, other]);
  expect(opened.index).toBe(0);
  expect(viewerImages(rows, other, "Other").index).toBe(1);
  // A file not loaded yet joins only when it is the one opened; its path is kept for Show in Finder.
  const file = viewerImages(rows, "data:image/png;base64,ZmlsZQ==", "", "/project/chart.png");
  expect(file.images.map((image) => image.path)).toEqual([undefined, "/project/chart.png", undefined]);
  expect(file.images[file.index]!.src).toBe("data:image/png;base64,ZmlsZQ==");
  // An image the chat does not hold opens alone.
  expect(viewerImages(rows, "data:image/png;base64,eA==", "x")).toEqual({
    images: [{ src: "data:image/png;base64,eA==", alt: "x", path: undefined }],
    index: 0,
  });
});

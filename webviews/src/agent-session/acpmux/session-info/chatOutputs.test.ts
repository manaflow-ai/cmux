import { expect, test } from "bun:test";
import type { TurnFile } from "../diff";
import type { AcpmuxRow } from "../model";
import { chatOutputs } from "./chatOutputs";

const reply = (text: string, id = "r1"): AcpmuxRow => ({ id, version: 1, at: 0, kind: "assistant", text });
const file = (path: string, created: boolean): TurnFile => ({
  path,
  displayPath: path,
  edits: [],
  additions: 3,
  deletions: 0,
  created,
});

test("a document a reply links to is an output, wherever it lives; a code file or a page it links is not", () => {
  const rows = [
    reply("Made [the PDF](/tmp/hello-pdf/hello-world.pdf) and [deck](./out/deck.pptx)."),
    reply("See [fetch.ts](src/net/fetch.ts), [docs](https://example.com/a.pdf) and [notes](notes.md).", "r2"),
    reply("```\n[skip.pdf](/tmp/skip.pdf)\n```", "r3"),
  ];
  expect(chatOutputs(rows, "/Users/me/repo", []).map((output) => [output.path, output.displayPath])).toEqual([
    ["/tmp/hello-pdf/hello-world.pdf", "/tmp/hello-pdf/hello-world.pdf"],
    ["/Users/me/repo/out/deck.pptx", "out/deck.pptx"],
  ]);
});

test("a document path in inline code is pointed to as a link is; a command naming one is not", () => {
  const rows = [
    reply("I created the PDF at `/tmp/hello-pdf/hello-world.pdf`.\n\n- To open it, run `open /tmp/other.pdf`."),
  ];
  expect(chatOutputs(rows, "/Users/me/repo", []).map((output) => output.path)).toEqual([
    "/tmp/hello-pdf/hello-world.pdf",
  ]);
  // A bare name is the chat's folder's.
  expect(chatOutputs([reply("I created `test-file.pdf` in the root.")], "/Users/me/repo", [])).toEqual([
    { path: "/Users/me/repo/test-file.pdf", displayPath: "test-file.pdf" },
  ]);
});

test("a deliverable the file tools created is an output; an edit or a created code file is not", () => {
  const created = [
    file("/Users/me/repo/src/app.ts", true),
    file("/Users/me/repo/README.md", false),
    file("/Users/me/repo/report.csv", true),
    file("/Users/me/Desktop/chart.png", true),
  ];
  expect(chatOutputs([], "/Users/me/repo", created).map((output) => output.displayPath)).toEqual([
    "report.csv",
    "~/Desktop/chart.png",
  ]);
});

test("a file both linked and created is listed once", () => {
  const rows = [reply("Done: [report.pdf](/Users/me/repo/report.pdf)")];
  expect(chatOutputs(rows, "/Users/me/repo", [file("/Users/me/repo/report.pdf", true)])).toHaveLength(1);
});

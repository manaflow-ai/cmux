// Latency harness page: the real markdown editor page (src/pages/markdown/main.tsx) on an in-page
// host (mock-host.ts): two linked files, saves, link resolution, and the app key dispatcher's
// Cmd-S as the `save` page command (as the dev bridge does).
import { HostError, installMockHost } from "./mock-host";

function doc(title: string, other: string): string {
  const sections = Array.from(
    { length: 24 },
    (_, index) =>
      `## Section ${index + 1}\n\nParagraph ${index + 1} of ${title} with **bold**, *emphasis* and \`code\`. ` +
      `It keeps going for a while so the document has real layout work in it.\n\n` +
      (index % 4 === 0
        ? "```ts\nexport function f" + index + "(x: number) {\n  return x * " + index + ";\n}\n```\n"
        : "") +
      `- item one\n- item two\n- item three\n`,
  );
  return `# ${title}\n\nSee [the other file](${other}) for more.\n\n${sections.join("\n")}`;
}

const files = new Map<string, { text: string; hash: string }>([
  ["/docs/a.md", { text: doc("File A", "b.md"), hash: "a1" }],
  ["/docs/b.md", { text: doc("File B", "a.md"), hash: "b1" }],
]);
let saves = 0;

const config = (path: string) => {
  const file = files.get(path);
  if (!file) throw new HostError("cmux.markdown.not_found", path);
  return { path, text: file.text, hash: file.hash };
};

const host = installMockHost(
  {
    "cmux.markdown.config": () => config("/docs/a.md"),
    "cmux.markdown.open": (params: { path: string }) => config(params.path),
    "cmux.markdown.save": (params: { path: string; text: string; baseHash: string | null }) => {
      const file = files.get(params.path);
      if (file && file.hash !== params.baseHash)
        throw new HostError("cmux.markdown.conflict", "changed", { hash: file.hash, text: file.text });
      const hash = `h${++saves}`;
      files.set(params.path, { text: params.text, hash });
      return { hash };
    },
    "cmux.markdown.resolveLinks": (params: { from: string; paths: string[] }) => ({
      links: Object.fromEntries(
        params.paths.map((path) => {
          const target = `/docs/${path.replace(/^\.\//, "")}`;
          return [path, { exists: files.has(target), path: target, kind: "markdown" }];
        }),
      ),
    }),
    "cmux.markdown.listFiles": () => ({ entries: ["a.md", "b.md"] }),
    "cmux.markdown.openLink": () => null,
  },
  ["cmux.markdown.changes", "cmux.markdown.look", "cmux.page.command"],
);

// The app's key dispatcher: Cmd-S is the `save` page command, never a page key handler.
addEventListener(
  "keydown",
  (event: KeyboardEvent) => {
    if (event.metaKey && event.key.toLowerCase() === "s") {
      event.preventDefault();
      host.emit("cmux.page.command", { command: "save" });
    }
  },
  true,
);

await import("../../src/pages/markdown/main");

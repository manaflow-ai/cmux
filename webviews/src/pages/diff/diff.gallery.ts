// l10n-allow-file: gallery fixtures (sample code), not shipped UI.
// The diff viewer page (cmux-page://cmux.diff/) on fixed patches: the real page entry (main.tsx)
// over an in-page cmuxPage host that serves the patch (src/gallery/frame/pages.ts).
import { diffPageEntry } from "../../gallery/format";

const before = `export function request(url: string) {
  return fetch(url).then((response) => response.json());
}

export function getJSON(url: string) {
  return request(url);
}
`;

const after = `import { withRetry } from "./retry";

export function request(url: string, attempts = 3) {
  return withRetry(() => fetch(url).then((response) => response.json()), attempts);
}

export function getJSON(url: string) {
  return request(url);
}
`;

const retry = `export async function withRetry<T>(task: () => Promise<T>, attempts = 3): Promise<T> {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await task();
    } catch (error) {
      if (attempt >= attempts) throw error;
    }
  }
}
`;

const many = Array.from({ length: 30 }, (_, index) => ({
  path: `src/area${String(index % 6).padStart(2, "0")}/module${index}.ts`,
  before: `export const value${index} = ${index};\nexport const keep${index} = true;\n`,
  after: `export const value${index} = ${index * 2};\nexport const keep${index} = true;\nexport const added${index} = "new";\n`,
}));

export default diffPageEntry({
  id: "pages.diff",
  title: "Diff viewer",
  area: "Pages",
  height: 640,
  widths: { narrow: 560, normal: 1000, wide: 1400 },
  covers: ["page:cmux.diff", "App.tsx", "DiffToolbar.tsx", "BranchBasePicker.tsx"],
  variants: {
    "small-split": {
      note: "Two files, split layout: one changed, one added.",
      files: [
        { path: "src/net/client.ts", before, after },
        { path: "src/net/retry.ts", after: retry },
      ],
    },
    unified: {
      note: "The same change, unified layout.",
      layout: "unified",
      files: [
        { path: "src/net/client.ts", before, after },
        { path: "src/net/retry.ts", after: retry },
      ],
    },
    deleted: {
      note: "A deleted file.",
      files: [{ path: "src/net/legacy.ts", before }],
    },
    "many-files": {
      note: "Thirty files in six folders (the file tree).",
      files: many,
    },
  },
});

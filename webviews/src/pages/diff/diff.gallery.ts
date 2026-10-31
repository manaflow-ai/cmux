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

// Small edits inside lines: the word-level marks (word-alt joins words split by a space).
const config = `export const config = {
  retries: 3,
  timeoutMs: 5000,
  baseURL: "https://api.example.com/v1",
  headers: { Accept: "application/json" },
};

export function describe(config: Config): string {
  return \`\${config.baseURL} (\${config.retries} retries)\`;
}
`;
const configAfter = `export const config = {
  retries: 5,
  timeoutMs: 15000,
  baseURL: "https://api.example.com/v2",
  headers: { Accept: "application/json", "User-Agent": "cmux" },
};

export function describeConfig(config: Config, verbose = false): string {
  return \`\${config.baseURL} (\${config.retries} retries\${verbose ? \`, \${config.timeoutMs} ms\` : ""})\`;
}
`;

// A bigger review: 120 files in eight packages, edits of every size, so the files panel scrolls,
// the change bars vary and the stats line up in tabular figures.
const review = Array.from({ length: 120 }, (_, index) => {
  const lines = 4 + (index % 9) * 3;
  const body = (changed: boolean) =>
    Array.from({ length: lines }, (_, k) =>
      changed && k % (2 + (index % 4)) === 0
        ? `export const item${index}_${k} = compute(${k}, { cache: true });`
        : `export const item${index}_${k} = compute(${k});`,
    ).join("\n") + "\n";
  return {
    path: `packages/pkg${String(index % 8).padStart(2, "0")}/src/feature${String(index).padStart(3, "0")}.ts`,
    before: index % 17 === 5 ? undefined : body(false),
    after: index % 23 === 7 ? undefined : body(true),
  };
});

export default diffPageEntry({
  id: "pages.diff",
  title: "Diff viewer",
  area: "Pages",
  height: 640,
  widths: { narrow: 560, normal: 1000, wide: 1400 },
  covers: [
    "page:cmux.diff",
    "App.tsx",
    "diff-viewer/freshness.ts",
    "DiffToolbar.tsx",
    "BranchBasePicker.tsx",
    "diff-viewer/FileHeader.tsx",
    "diff-viewer/FilesSidebar.tsx",
    "diff-viewer/Loading.tsx",
    "diff-viewer/Toolbar.tsx",
    "diff-viewer/WorkerRenderOptionsSync.tsx",
  ],
  variants: {
    "cloud-offline": {
      note: "The loaded Cloud diff stays visible with its machine's offline reason.",
      title: "Build VM changes",
      fingerprintError: {
        code: "cmux.diff.machine_offline",
        message: "Build VM is offline. Reconnect to see its diff.",
      },
      files: [{ path: "src/net/client.ts", before, after }],
      play: async (ctx) => {
        await ctx.waitFor(
          () => ctx.document.querySelector(".file-header") && ctx.document.querySelector(".diff-files-changed"),
          { capMs: 10_000 },
        );
      },
    },
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
    "word-diff": {
      note: "Edits inside lines, unified: the changed words are marked (on by default).",
      layout: "unified",
      files: [{ path: "src/net/config.ts", before: config, after: configAfter }],
    },
    "word-diff-split": {
      note: "The same edits side by side.",
      files: [{ path: "src/net/config.ts", before: config, after: configAfter }],
    },
    "big-review": {
      note: "120 files in eight packages: the files panel, its accent selection, change bars per file.",
      height: 760,
      layout: "unified",
      files: review,
    },
    "collapsed-files": {
      note: "Three files, the first collapsed from its header: the bar stays, its chevron turns.",
      layout: "unified",
      files: [
        { path: "src/net/client.ts", before, after },
        { path: "src/net/config.ts", before: config, after: configAfter },
        { path: "src/net/retry.ts", after: retry },
      ],
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".file-header"), { capMs: 10_000 });
        await ctx.click({ selector: ".file-header" });
        await ctx.waitFor(() => ctx.document.querySelector('.file-header[data-collapsed="true"]'));
      },
    },
  },
});

import { expect, test } from "bun:test";
import { textLinks } from "../src/agent-session/acpmux/chips/paths";

for (const [suffix, location] of [
  [":42", { line: 42 }],
  [":42:7", { line: 42, column: 7 }],
  ["#L42", { line: 42 }],
  ["#L42C7", { line: 42, column: 7 }],
  ["#L42-L50", { line: 42, endLine: 50 }],
  [":42-50", { line: 42, endLine: 50 }],
] as const) {
  test(`prose preserves ${suffix}`, () => {
    const [link] = textLinks(`See src/app.ts${suffix}.`);
    expect(link?.path).toBe("src/app.ts");
    expect(link?.location).toEqual(location);
    expect(link?.value).toBe(`src/app.ts${suffix}`);
  });
}

import {
  codeReplyPath,
  linkReplyPath,
  codePath,
  linkPath,
  isDeniedPath,
} from "../src/agent-session/acpmux/chips/paths";
import { renderToStaticMarkup } from "react-dom/server";
import { renderInline } from "../src/agent-session/acpmux/conversation/Markdown";

const forms = [":42", ":42:7", "#L42", "#L42C7", "#L42-L50", ":42-50"];
for (const suffix of forms) {
  for (const path of ["src/app.ts", "./app.ts", "/repo/src/app.ts", "~/repo/app.ts", "app.ts"]) {
    test(`code and markdown links keep ${path}${suffix}`, () => {
      const expected = linkReplyPath(`file:///repo/src/app.ts${suffix}`)?.location;
      expect(expected?.line).toBe(42);
      expect(codeReplyPath(`${path}${suffix}`)?.location).toEqual(expected);
      expect(linkReplyPath(`${path}${suffix}`)?.location).toEqual(expected);
      expect(codePath(`${path}${suffix}`)).toBe(path);
      expect(linkPath(`${path}${suffix}`)).toBe(path);
    });
  }
  test(`chips show the written line ${suffix} in prose, code and markdown links`, () => {
    for (const source of [
      `src/app.ts${suffix}`,
      `\`src/app.ts${suffix}\``,
      `[source](src/app.ts${suffix})`,
      `file:///repo/src/app.ts${suffix}`,
    ]) {
      const html = renderToStaticMarkup(<>{renderInline(source)}</>);
      expect(html).toContain("cv-chip is-path");
      expect(html).toContain(suffix);
      expect(html).toContain(source.startsWith("file:") ? 'data-path="/repo/src/app.ts"' : 'data-path="src/app.ts"');
    }
  });
}

for (const value of [
  "foo:bar",
  "12:30",
  "http://localhost:3000/app.ts:42",
  "https://example.com:42",
  "https://example.com/app.ts#L42",
]) {
  test(`non-file reference has no line: ${value}`, () => {
    expect(codeReplyPath(value)?.location).toBeUndefined();
    expect(linkReplyPath(value)?.location).toBeUndefined();
    expect(textLinks(value).some((link) => link.location)).toBe(false);
  });
}

for (const suffix of [":0", ":-1", ":1.5", ":10000001", ":42:0", "#L0", "#L42-L2", ":42-10000001", ":42:7oops"]) {
  test(`invalid location is never sent: ${suffix}`, () => {
    expect(codeReplyPath(`src/app.ts${suffix}`)?.location).toBeUndefined();
    expect(linkReplyPath(`src/app.ts${suffix}`)?.location).toBeUndefined();
  });
}

test("folders ignore positions, encoded file URLs work, denied files remain denied", () => {
  expect(linkReplyPath("src/:42")).toEqual({ path: "src/" });
  expect(linkReplyPath("file:///repo/a%20b.ts#L42C7")).toMatchObject({
    path: "/repo/a b.ts",
    location: { line: 42, column: 7 },
  });
  expect(linkReplyPath("file://evil/repo/app.ts#L42")).toBeUndefined();
  expect(isDeniedPath(linkPath("/repo/private.pem:42")!)).toBe(true);
  expect(isDeniedPath(linkPath("/repo/.env#L42")!)).toBe(true);
});

test("ordinary prose and code keep their existing non-path treatment", () => {
  expect(textLinks("At 12:30 visit example.com; foo:bar and/or /usr stay text.")).toEqual([]);
  for (const source of ["cat /tmp/app.ts", "./src/*.ts", "--file=./src/app.ts"])
    expect(codePath(source)).toBeUndefined();
  for (const source of ["/tmp/app.ts", "~/repo/src/", "./app.ts", "../src/app.ts"])
    expect(codePath(source)).toBe(source);
  expect(linkPath("file:///repo/app.ts#section")).toBe("/repo/app.ts");
});

import { menuPartAt } from "../src/agent-session/acpmux/conversation/menuParts";
test("the context menu keeps the same position as the path chip", () => {
  const element = {
    parentElement: null,
    getAttribute: (name: string) => ({ "data-path": "src/app.ts", "data-line": "42:7" })[name] ?? null,
  } as unknown as Element;
  expect(menuPartAt(element)).toEqual({ path: "src/app.ts", line: "42:7" });
});

test("Windows drive paths never become relative prose chips", () => {
  for (const path of [String.raw`C:\repo\app.ts:42`, String.raw`C:\repo\src/app.ts:42`, "C:/repo/app.ts:42"]) {
    expect(textLinks(`See ${path}.`)).toEqual([]);
    expect(codeReplyPath(path)).toBeUndefined();
    expect(linkReplyPath(path)).toBeUndefined();
  }
});

test("fractional line continuations never become truncated prose locations", () => {
  for (const suffix of [":1.5", ":42:7.5", ":42-50.5", "#L42.5", "#L42C7.5", "#L42-L50.5"]) {
    expect(textLinks(`See src/app.ts${suffix}.`)).toEqual([]);
  }
});

test("sentence punctuation still bounds a prose line suffix", () => {
  for (const punctuation of [".", ",", ")", ":", ": "]) {
    expect(textLinks(`See src/app.ts:42${punctuation}`)).toEqual([
      {
        kind: "path",
        start: 4,
        end: 17,
        value: "src/app.ts:42",
        path: "src/app.ts",
        location: { line: 42 },
        suffix: ":42",
      },
    ]);
  }
});

test("only supported line fragments supply a markdown link location", () => {
  for (const path of ["src/app.ts", "./app.ts", "/repo/app.ts", "file:///repo/app.ts"]) {
    const pathname = path.replace(/^file:\/\//, "");
    for (const fragment of [
      "section:42",
      "section:42:7",
      "section:42-50",
      "section#L42",
      "L42oops",
      "L42#section",
      "L42?section",
    ]) {
      expect(linkReplyPath(`${path}#${fragment}`)).toEqual({ path: pathname });
      expect(linkReplyPath(`${path}:7#${fragment}`)).toEqual({ path: pathname, location: { line: 7 }, suffix: ":7" });
    }
  }
});

test("one click on a formatted path link label opens only its href", async () => {
  const { JSDOM } = await import("jsdom");
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const dom = new JSDOM("<!doctype html><div id=root></div>");
  const scope = globalThis as Record<string, unknown>;
  const globals = { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true };
  const saved = Object.keys(globals).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, globals);
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const opens: Record<string, unknown>[] = [];
  setChipHost(async (method, params) => {
    if (method === "link.openPath") opens.push(params);
    return undefined;
  });
  try {
    for (const [label, selector, href, expected] of [
      ["app.ts:42", ".cv-chip__label", "src/app.ts:42", { path: "src/app.ts", line: "42" }],
      ["/repo/app.ts", ".cv-chip__label", "src/app.ts", { path: "src/app.ts" }],
      ["**src/app.ts:42**", "strong", "src/app.ts:42", { path: "src/app.ts", line: "42" }],
      ["*src/app.ts:42*", "em", "src/app.ts:42", { path: "src/app.ts", line: "42" }],
      ["~~src/app.ts:42~~", "del", "src/app.ts:42", { path: "src/app.ts", line: "42" }],
      ["`/repo/app.ts`", "code", "src/app.ts:42", { path: "src/app.ts", line: "42" }],
    ] as const) {
      opens.length = 0;
      await act(async () => root.render(<>{renderInline(`[${label}](${href})`)}</>));
      const target = Array.from(container.querySelectorAll<HTMLElement>(selector)).at(-1)!;
      expect(target).not.toBeNull();
      await act(async () => target.click());
      expect(opens).toEqual([expected]);
      expect(container.querySelectorAll("button")).toHaveLength(1);
    }
  } finally {
    await act(async () => root.unmount());
    setChipHost(undefined);
    resetLinkStore();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
    dom.window.close();
  }
});

for (const value of ["console.log", "user.name", "JSON.parse", "os.path", "1.5", "package.json"]) {
  test(`dotted code stays code: ${value}`, () => {
    // At most a bare candidate, which the host must find before it is a chip.
    const candidate = codeReplyPath(value);
    expect(candidate === undefined || candidate.bare === true).toBe(true);
    const html = renderToStaticMarkup(<>{renderInline(`\`${value}\``)}</>);
    expect(html).toContain('<code class="cv-code">');
    expect(html).not.toContain("cv-chip");
  });
}

for (const value of [
  "src/app.ts",
  "app.ts:42",
  "./x.ts",
  "foo.test.ts:42",
  "app.test.ts:42",
  "index.d.ts:3",
  "app.5a:42",
]) {
  test(`file references remain chips: ${value}`, async () => {
    const { resetLinkStore, seedLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
    const path = value.split(":")[0]!;
    expect(codeReplyPath(value)).toBeDefined();
    resetLinkStore();
    // A name with no folder is a chip only once the host has found it; a path with one at once.
    if (!path.includes("/")) {
      expect(renderToStaticMarkup(<>{renderInline(`\`${value}\``)}</>)).not.toContain("cv-chip is-path");
      seedLinkStore({ paths: { [path]: { place: "root", folder: false } } });
    }
    try {
      for (const source of [value, `\`${value}\``, `[x](${value})`]) {
        expect(renderToStaticMarkup(<>{renderInline(source)}</>)).toContain("cv-chip is-path");
      }
    } finally {
      resetLinkStore();
    }
    expect(linkReplyPath(value)?.path).toBe(path);
    expect(textLinks(value)).toHaveLength(1);
  });
}

for (const value of ["4.5:1", "example.com:8080", "localhost.local:3000", "example.org:443"]) {
  test(`versions and host ports stay text: ${value}`, () => {
    expect(textLinks(`WCAG ${value} contrast`)).toEqual([]);
    expect(codeReplyPath(value)).toBeUndefined();
    expect(linkReplyPath(value)).toBeUndefined();
    expect(renderToStaticMarkup(<>{renderInline(`[dev](${value})`)}</>)).not.toContain("cv-chip");
  });
}

test("a host-like extension inside a folder is still a file location", () => {
  expect(codeReplyPath("src/example.com:42")).toMatchObject({ path: "src/example.com", location: { line: 42 } });
  expect(textLinks("src/example.com:42")).toHaveLength(1);
});

test("a bare file name in code is a chip only when the host finds the file", async () => {
  const { JSDOM } = await import("jsdom");
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const dom = new JSDOM("<!doctype html><div id=root></div>");
  const scope = globalThis as Record<string, unknown>;
  const globals = { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true };
  const saved = Object.keys(globals).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, globals);
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const asked: string[] = [];
  const opens: Record<string, unknown>[] = [];
  resetLinkStore();
  setChipHost(async (method, params) => {
    if (method === "link.openPath") opens.push(params);
    if (method !== "link.inspect") return undefined;
    const paths = (params as { paths: string[] }).paths;
    asked.push(...paths);
    const places: Record<string, unknown> = {};
    for (const path of paths) places[path] = { place: path === "next-sync.py" ? "root" : "missing", folder: false };
    return { paths: places, sites: {}, policy: { outsideRoots: "confirm", remoteImages: "click" } };
  });
  try {
    await act(async () => root.render(<>{renderInline("`next-sync.py` calls `console.log` at `1.5` speed")}</>));
    await act(async () => {});
    await act(async () => {});
    expect(asked.sort()).toEqual(["console.log", "next-sync.py"]);
    const chips = container.querySelectorAll<HTMLButtonElement>("button.cv-chip.is-path");
    expect(chips).toHaveLength(1);
    expect(chips[0]!.dataset.path).toBe("next-sync.py");
    const code = Array.from(container.querySelectorAll("code.cv-code")).map((node) => node.textContent);
    expect(code).toEqual(["console.log", "1.5"]);
    expect(container.querySelector(".cv-chip-plain")).toBeNull();
    await act(async () => chips[0]!.click());
    expect(opens).toEqual([{ path: "next-sync.py" }]);
  } finally {
    await act(async () => root.unmount());
    setChipHost(undefined);
    resetLinkStore();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
    dom.window.close();
  }
});

async function withChipDom(
  host: (method: string, params: unknown) => Promise<unknown>,
  body: (
    root: import("react-dom/client").Root,
    container: HTMLElement,
    act: typeof import("react").act,
  ) => Promise<void>,
) {
  const { JSDOM } = await import("jsdom");
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const dom = new JSDOM("<!doctype html><div id=root></div>");
  const scope = globalThis as Record<string, unknown>;
  const globals = { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true };
  const saved = Object.keys(globals).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, globals);
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  resetLinkStore();
  setChipHost(host as never);
  try {
    await body(root, container, act);
  } finally {
    await act(async () => root.unmount());
    setChipHost(undefined);
    resetLinkStore();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
    dom.window.close();
  }
}

const POLICY = { outsideRoots: "confirm", remoteImages: "click" };

test("a code span path the host reports missing keeps its code styling", async () => {
  await withChipDom(
    async (method, params) => {
      if (method !== "link.inspect") return undefined;
      const places: Record<string, unknown> = {};
      for (const path of (params as { paths: string[] }).paths) places[path] = { place: "missing", folder: false };
      return { paths: places, sites: {}, policy: POLICY };
    },
    async (root, container, act) => {
      await act(async () => root.render(<>{renderInline("see `src/gone.ts:4` and `/repo/gone.ts`")}</>));
      await act(async () => {});
      await act(async () => {});
      const code = Array.from(container.querySelectorAll("code.cv-code")).map((node) => node.textContent);
      expect(code).toEqual(["src/gone.ts:4", "/repo/gone.ts"]);
      expect(container.querySelector(".cv-chip-plain")).toBeNull();
      expect(container.querySelector("button")).toBeNull();
    },
  );
});

test("bare names are asked in their own call, so other chips never wait for the search", async () => {
  const calls: string[][] = [];
  let finishNames: (() => void) | undefined;
  await withChipDom(
    async (method, params) => {
      if (method !== "link.inspect") return undefined;
      const paths = (params as { paths: string[] }).paths;
      calls.push(paths);
      const places: Record<string, unknown> = {};
      for (const path of paths) places[path] = { place: "root", folder: false };
      const answer = { paths: places, sites: {}, policy: POLICY };
      // The name search is slow: hold its answer until the test lets it go.
      if (paths.some((path) => !path.includes("/")))
        return new Promise((resolve) => (finishNames = () => resolve(answer)));
      return answer;
    },
    async (root, container, act) => {
      // A bare code span, a name with a line and a link to a name all wait on the search alone.
      await act(async () =>
        root.render(<>{renderInline("`src/app.ts:3` and `next-sync.py` and `other.py:3` and [x](link.py)")}</>),
      );
      await act(async () => {});
      await act(async () => {});
      expect(calls).toContainEqual(["src/app.ts"]);
      expect(calls.find((call) => call.includes("next-sync.py"))?.sort()).toEqual([
        "link.py",
        "next-sync.py",
        "other.py",
      ]);
      // The folder path is a chip while the name search is still out; the bare name is code.
      expect(
        Array.from(container.querySelectorAll("button.cv-chip")).map((node) => (node as HTMLElement).dataset.path),
      ).toEqual(["src/app.ts"]);
      await act(async () => finishNames?.());
      await act(async () => {});
      expect(container.querySelectorAll("button.cv-chip")).toHaveLength(4);
    },
  );
});

for (const link of [
  "/repo/Makefile:10",
  "/repo/Makefile#L10",
  "./Makefile:3",
  "src/Makefile:3",
  "docs/README:5",
  ".github/workflows/ci.yml:5",
  "~/notes.md:3",
  "src/Makefile#L42",
  "/x.ts:42",
  "~/x.ts:42",
]) {
  test(`explicit link targets keep their line: ${link}`, () => {
    const target = linkReplyPath(link);
    expect(target?.location?.line).toBeGreaterThan(0);
    expect(link.startsWith(target!.path)).toBe(true);
  });
}

test("dot folders are paths in code and prose; secret dot folders stay denied", () => {
  expect(codeReplyPath(".github/workflows/ci.yml")?.path).toBe(".github/workflows/ci.yml");
  expect(textLinks("see .github/workflows/ci.yml:5 now")[0]?.path).toBe(".github/workflows/ci.yml");
  expect(isDeniedPath(".ssh/id_rsa")).toBe(true);
  expect(isDeniedPath(".aws/credentials")).toBe(true);
});

test("a reset drops answers to calls made before it, and new calls still go out", async () => {
  const { resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const calls: string[][] = [];
  const held: Array<(value: unknown) => void> = [];
  await withChipDom(
    async (method, params) => {
      if (method !== "link.inspect") return undefined;
      const paths = (params as { paths: string[] }).paths;
      calls.push(paths);
      const places: Record<string, unknown> = {};
      for (const path of paths) places[path] = { place: "root", folder: false };
      const answer = { paths: places, sites: {}, policy: POLICY };
      // The first call for the name is held past the reset.
      if (paths.includes("old.py") && held.length === 0)
        return new Promise((resolve) => held.push(() => resolve(answer)));
      return answer;
    },
    async (root, container, act) => {
      await act(async () => root.render(<>{renderInline("`old.py`")}</>));
      await act(async () => {});
      expect(calls).toContainEqual(["old.py"]);
      await act(async () => root.render(<></>));
      resetLinkStore();
      await act(async () => root.render(<>{renderInline("`old.py` and `src/new.ts`")}</>));
      await act(async () => {});
      await act(async () => {});
      // The name was asked again after the reset, though the first call is still out.
      expect(calls.filter((call) => call.includes("old.py"))).toHaveLength(2);
      expect(container.querySelectorAll("button.cv-chip")).toHaveLength(2);
      // The stale answer arriving now changes nothing.
      await act(async () => held[0]?.(undefined));
      await act(async () => {});
      expect(container.querySelectorAll("button.cv-chip")).toHaveLength(2);
    },
  );
});

test("a name the host places outside the folders follows the outside policy like any path", async () => {
  await withChipDom(
    async (method, params) => {
      if (method !== "link.inspect") return undefined;
      const places: Record<string, unknown> = {};
      for (const path of (params as { paths: string[] }).paths) places[path] = { place: "outside", folder: false };
      return { paths: places, sites: {}, policy: POLICY };
    },
    async (root, container, act) => {
      await act(async () => root.render(<>{renderInline("[notes](notes.md)")}</>));
      await act(async () => {});
      await act(async () => {});
      expect(container.querySelector("button.cv-chip.is-path.is-outside")).not.toBeNull();
    },
  );
});

test("prices and shell variables never start a prose path", () => {
  expect(textLinks("Prices: $5/$10/$20.")).toEqual([]);
  expect(textLinks("Run $HOME/notes.md or $PROJECT/src/ first.")).toEqual([]);
  expect(textLinks("Edit docs/ and src/app.ts.").map((link) => link.path)).toEqual(["docs/", "src/app.ts"]);
});

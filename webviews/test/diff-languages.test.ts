import { describe, expect, test } from "bun:test";
import { EXTENSION_TO_FILE_FORMAT, getSharedHighlighter, resolveLanguage } from "@pierre/diffs";
import { bundledLanguages } from "shiki";
import { createLanguageDetector, extensionCandidates, shebangLanguage } from "../src/diff-languages/detect";
import { installDiffLanguageHostAPI } from "../src/diff-languages/host";
import { parseDiffLanguagePack, textMateGrammarProblem } from "../src/diff-languages/pack";
import { createDiffLanguageRegistry } from "../src/diff-languages/registry";
import { shikiThemeFromGhostty } from "../src/pierre-options";
import { contrastBetween, syntaxPaletteColor, withMinimumContrast } from "../src/syntax-colors";

const isBundled = (language: string) => Object.prototype.hasOwnProperty.call(bundledLanguages, language);

const fooGrammar = {
  name: "foo",
  scopeName: "source.foo",
  patterns: [
    { match: "\\b(let|fn)\\b", name: "keyword.control.foo" },
    { begin: '"', end: '"', name: "string.quoted.double.foo" },
  ],
};

function fooPack(extra: Array<{ path: string; text: string }> = []) {
  return {
    files: [
      {
        path: "foo.language.json",
        text: JSON.stringify({ id: "foo", extensions: [".foo", "foo.cfg"], filenames: ["Foofile"], aliases: ["fu"] }),
      },
      { path: "foo.tmLanguage.json", text: JSON.stringify(fooGrammar) },
      ...extra,
    ],
  };
}

describe("detection table", () => {
  const registry = createDiffLanguageRegistry();
  const cases: Array<[string, string, string?]> = [
    ["src/App.tsx", "tsx"],
    ["src/main.ts", "typescript"],
    ["lib/index.mjs", "javascript"],
    ["Sources/App.swift", "swift"],
    ["crates/x/src/lib.rs", "rust"],
    ["cmd/main.go", "go"],
    ["tools/x.py", "python"],
    ["types/x.pyi", "python"],
    ["Gemfile", "ruby"],
    ["ios/Podfile", "ruby"],
    ["Dockerfile", "docker"],
    ["docker/Dockerfile.prod", "docker"],
    ["web/app.dockerfile", "dockerfile"],
    ["Containerfile", "docker"],
    ["Makefile", "make"],
    ["GNUmakefile", "make"],
    ["rules.mk", "makefile"],
    ["justfile", "just"],
    ["CMakeLists.txt", "cmake"],
    [".zshrc", "shellscript"],
    ["home/.bashrc", "shellscript"],
    [".envrc", "shellscript"],
    ["scripts/build.sh", "zsh"],
    [".env", "dotenv"],
    [".env.production", "dotenv"],
    [".gitconfig", "ini"],
    [".editorconfig", "ini"],
    ["tsconfig.json", "jsonc"],
    ["tsconfig.build.json", "jsonc"],
    ["package.json", "json"],
    ["Cargo.lock", "toml"],
    ["Cargo.toml", "toml"],
    ["BUILD.bazel", "python"],
    ["tools/defs.bzl", "python"],
    [".github/CODEOWNERS", "codeowners"],
    ["Info.plist", "xml"],
    ["App.entitlements", "xml"],
    ["Localizable.xcstrings", "json"],
    ["Main.storyboard", "xml"],
    ["src/foo.m", "objective-c"],
    ["src/foo.h", "objective-cpp"],
    ["shaders/x.metal", "cpp"],
    ["README.MD", "markdown"],
    ["docs/guide.mdx", "mdx"],
    ["app/x.component.ts", "angular-ts"],
    ["infra/main.tf", "tf"],
    ["deploy/app.service", "systemd"],
    ["data.ndjson", "jsonl"],
    ["notes.txt", "text"],
    ["LICENSE", "text"],
    ["image.png", "text"],
    ["bin/tool", "python", "#!/usr/bin/env python3"],
    ["bin/run", "typescript", "#!/usr/bin/env -S deno run --allow-net"],
    ["bin/x", "shellscript", "#!/bin/bash -e"],
    ["bin/y", "javascript", "#!/usr/local/bin/node"],
    ["bin/z", "text", "#!/usr/bin/unknown-thing"],
    // An extension beats the shebang.
    ["bin/tool.rb", "ruby", "#!/usr/bin/env python3"],
  ];
  for (const [path, language, firstLine] of cases) {
    test(`${path}${firstLine ? ` (${firstLine})` : ""} -> ${language}`, () => {
      expect(registry.detect({ path, firstLine })).toBe(language);
    });
  }

  test("every built-in answer is a loadable Shiki language", () => {
    for (const [path, , firstLine] of cases) {
      const language = registry.detect({ path, firstLine });
      expect(language === "text" || isBundled(language)).toBe(true);
    }
  });

  test("an unknown parsed language never reaches Shiki", () => {
    expect(registry.detect({ path: "x.unknownext", parsedLanguage: "klingon" })).toBe("text");
  });
});

describe("detector helpers", () => {
  test("extension candidates go longest first", () => {
    expect(extensionCandidates("a.spec.ts")).toEqual(["spec.ts", "ts"]);
    expect(extensionCandidates(".zshrc")).toEqual(["zshrc"]);
    expect(extensionCandidates("Makefile")).toEqual([]);
  });

  test("shebang strips versions and env flags", () => {
    expect(shebangLanguage("#!/usr/bin/python3.12")).toBe("python");
    expect(shebangLanguage("#!/usr/bin/env -S bun run")).toBe("typescript");
    expect(shebangLanguage("#!/usr/bin/env FOO=1 ruby")).toBe("ruby");
    expect(shebangLanguage("// not a shebang")).toBeUndefined();
  });
});

describe("override map", () => {
  test("extension and filename overrides win over the built-in table", () => {
    const detect = createLanguageDetector({
      isLoadable: isBundled,
      extensionMap: {},
      overrides: {
        extensions: { h: "c", ".tpl": "html", "spec.ts": "javascript" },
        filenames: { BUILD: "starlark-ish" },
      },
    });
    expect(detect({ path: "x/foo.h" })).toBe("c");
    expect(detect({ path: "x/page.tpl" })).toBe("html");
    expect(detect({ path: "x/a.spec.ts" })).toBe("javascript");
    // An override naming a language that cannot load falls through to the built-in answer.
    expect(detect({ path: "BUILD" })).toBe("python");
  });

  test("an override accepts aliases and `text` turns highlighting off", () => {
    const registry = createDiffLanguageRegistry();
    registry.install({
      files: [
        { path: "overrides.json", text: '{"extensions":{"inc":"sh","md":"plaintext"},"filenames":{"TODO":"md"}}' },
      ],
    });
    expect(registry.detect({ path: "lib/x.inc" })).toBe("sh");
    expect(registry.detect({ path: "README.md" })).toBe("text");
    expect(registry.detect({ path: "TODO" })).toBe("md");
  });

  test("an override applies to a parsed language too", () => {
    const registry = createDiffLanguageRegistry();
    registry.install({ files: [{ path: "overrides.json", text: '{"extensions":{"ts":"javascript"}}' }] });
    expect(registry.detect({ path: "a.ts", parsedLanguage: "typescript" })).toBe("javascript");
  });

  test("a malformed overrides file is skipped with a warning", () => {
    const registry = createDiffLanguageRegistry();
    const report = registry.install({ files: [{ path: "overrides.json", text: "{nope" }] });
    expect(report.warnings.join("\n")).toContain("overrides.json: invalid JSON");
    expect(registry.detect({ path: "a.ts" })).toBe("typescript");
  });
});

describe("custom grammars", () => {
  test("a user grammar is detected by extension, compound extension, file name and alias", () => {
    const registry = createDiffLanguageRegistry();
    const report = registry.install(fooPack([{ path: "overrides.json", text: '{"extensions":{"bar":"fu"}}' }]));
    expect(report).toEqual({ languages: ["foo"], warnings: [] });
    const id = registry.detect({ path: "src/main.foo" });
    expect(id).toMatch(/^cmux-user-foo-[0-9a-f]{8}$/);
    expect(registry.isUserLanguage(id)).toBe(true);
    expect(registry.detect({ path: "app/x.foo.cfg" })).toBe(id);
    expect(registry.detect({ path: "Foofile" })).toBe(id);
    expect(registry.detect({ path: "x.bar" })).toBe(id);
  });

  test("the registered loader yields a grammar Shiki tokenizes", async () => {
    const registry = createDiffLanguageRegistry();
    registry.install(fooPack());
    const id = registry.detect({ path: "a.foo" });
    const resolved = await resolveLanguage(id as never);
    expect(resolved.name).toBe(id);
    const highlighter = await getSharedHighlighter({
      themes: ["pierre-dark"],
      langs: [id as never],
      preferredHighlighter: "shiki-js",
    });
    const tokens = highlighter.codeToTokensBase('let x = "hi"', {
      lang: id,
      theme: "pierre-dark",
      includeExplanation: true,
    })[0];
    const scopes = tokens.flatMap(
      (token) => token.explanation?.flatMap((part) => part.scopes.map((s) => s.scopeName)) ?? [],
    );
    expect(scopes).toContain("keyword.control.foo");
    expect(scopes).toContain("string.quoted.double.foo");
  });

  test("a user grammar named like a bundled language replaces it", () => {
    const registry = createDiffLanguageRegistry();
    registry.install({
      files: [
        {
          path: "swift.language.json",
          text: JSON.stringify({ id: "swift", grammar: { ...fooGrammar, scopeName: "source.swift" } }),
        },
      ],
    });
    expect(registry.detect({ path: "App.swift" })).toMatch(/^cmux-user-swift-/);
  });

  test("an edited grammar gets a new id and asks for a reload; an unchanged one does neither", () => {
    const registry = createDiffLanguageRegistry();
    registry.install(fooPack());
    const first = registry.detect({ path: "a.foo" });
    expect(registry.install(fooPack()).reloadRequired).toBeUndefined();
    expect(registry.detect({ path: "a.foo" })).toBe(first);
    const edited = fooPack();
    edited.files[1].text = JSON.stringify({ ...fooGrammar, patterns: [{ match: "x", name: "keyword.foo" }] });
    expect(registry.install(edited).reloadRequired).toBe(true);
    expect(registry.detect({ path: "a.foo" })).not.toBe(first);
    // A new language or an override change applies live.
    const added = registry.install({
      files: [...edited.files, { path: "overrides.json", text: '{"extensions":{"h":"c"}}' }],
    });
    expect(added.reloadRequired).toBeUndefined();
  });

  test("embedded languages are loaded with the grammar; unknown ones warn", async () => {
    const registry = createDiffLanguageRegistry();
    const report = registry.install({
      files: [
        {
          path: "tmpl.language.json",
          text: JSON.stringify({
            id: "tmpl",
            extensions: ["tmpl"],
            embeddedLanguages: ["javascript", "nope-lang"],
            grammar: { scopeName: "text.tmpl", patterns: [{ include: "source.js" }] },
          }),
        },
      ],
    });
    expect(report.warnings).toEqual(['tmpl: embedded language "nope-lang" is unknown; ignored']);
    const resolved = await resolveLanguage(registry.detect({ path: "x.tmpl" }) as never);
    const scopes = resolved.data.map((registration) => registration.scopeName);
    expect(scopes).toContain("source.js");
    expect(scopes.at(-1)).toBe("text.tmpl");
  });

  test("an invalid grammar is skipped with a warning and the others still apply", () => {
    const warned: string[] = [];
    const quiet = createDiffLanguageRegistry({ ...stubDependencies(), warn: (message) => warned.push(message) });
    const report = quiet.install(
      fooPack([
        { path: "broken.language.json", text: '{"id": "broken"' },
        { path: "nogrammar.language.json", text: '{"id": "nogrammar"}' },
        { path: "bad.language.json", text: '{"id": "bad", "grammar": "bad.tmLanguage.json"}' },
        { path: "bad.tmLanguage.json", text: '{"scopeName": "source.bad", "patterns": [{"begin": "x"}]}' },
        { path: "noscope.language.json", text: '{"id": "noscope", "grammar": {"patterns": []}}' },
        { path: "text.language.json", text: '{"id": "text", "grammar": {"scopeName": "x", "patterns": []}}' },
      ]),
    );
    expect(report.languages).toEqual(["foo"]);
    expect(report.warnings).toHaveLength(5);
    expect(warned).toHaveLength(5);
    expect(report.warnings.some((w) => w.startsWith("broken.language.json: invalid JSON"))).toBe(true);
    expect(report.warnings).toContain(
      "nogrammar.language.json: grammar file nogrammar.tmLanguage.json is missing; skipped",
    );
    expect(report.warnings).toContain(
      "bad.language.json: the grammar has a `begin` pattern without `end` or `while`; skipped",
    );
    expect(report.warnings).toContain("noscope.language.json: the grammar has no `scopeName`; skipped");
    expect(quiet.detect({ path: "a.foo" })).toMatch(/^cmux-user-foo-/);
    expect(quiet.detect({ path: "a.ts" })).toBe("typescript");
  });

  test("a grammar whose loader fails leaves detection and other files working", async () => {
    const loaders = new Map<string, () => Promise<unknown>>();
    const registry = createDiffLanguageRegistry({
      ...stubDependencies(),
      register: (id, loader) => loaders.set(id, loader),
      resolveEmbedded: () => Promise.reject(new Error("embedded grammar failed")),
    });
    registry.install({
      files: [
        {
          path: "x.language.json",
          text: JSON.stringify({
            id: "xlang",
            extensions: ["xl"],
            embeddedLanguages: ["javascript"],
            grammar: fooGrammar,
          }),
        },
      ],
    });
    const id = registry.detect({ path: "a.xl" });
    await expect(loaders.get(id)!()).rejects.toThrow("embedded grammar failed");
    expect(registry.detect({ path: "a.ts" })).toBe("typescript");
  });

  test("a pack without files or with junk entries is tolerated", () => {
    expect(parseDiffLanguagePack(undefined)).toEqual({ languages: [], overrides: {}, warnings: [] });
    expect(parseDiffLanguagePack({ files: "nope" }).warnings).toHaveLength(1);
    expect(parseDiffLanguagePack({ files: [{ path: 1 }] }).warnings).toHaveLength(1);
  });

  test("grammar validation names the problem", () => {
    expect(textMateGrammarProblem([])).toBe("is not a JSON object");
    expect(textMateGrammarProblem({ scopeName: "a" })).toBe("has neither `patterns` nor `injections`");
    expect(textMateGrammarProblem({ scopeName: "a", patterns: [{ match: 1 }] })).toBe(
      "has a pattern whose `match` is not a string",
    );
    expect(textMateGrammarProblem({ scopeName: "a", patterns: [], repository: { r: 3 } })).toBe(
      'has a repository entry "r" that is not an object',
    );
    expect(textMateGrammarProblem(fooGrammar)).toBeNull();
  });

  test("installing notifies subscribers and the host API reports", () => {
    const registry = createDiffLanguageRegistry();
    let calls = 0;
    const unsubscribe = registry.subscribe(() => calls++);
    registry.install(fooPack());
    unsubscribe();
    registry.install(fooPack());
    expect(calls).toBe(1);

    const target = {} as Window;
    const api = installDiffLanguageHostAPI(undefined, target);
    expect(target.cmuxDiffViewerLanguages).toBe(api);
    expect(api.report()).toEqual({ languages: [], warnings: [] });
  });
});

describe("syntax colors follow the terminal palette", () => {
  const theme = (palette: Record<string, string>, type = "dark", background = "#1e1e1e", foreground = "#ffffff") =>
    shikiThemeFromGhostty({ name: "t", type, background, foreground, palette }, { backgroundOpacity: 1 });
  const colorFor = (built: ReturnType<typeof theme>, scope: string) =>
    built.tokenColors.find((rule) => (rule as { scope?: string[] }).scope?.includes(scope))?.settings.foreground;

  test("keywords, strings, functions, types and comments get distinct palette colors", () => {
    const built = theme({
      "2": "#32d74b",
      "3": "#ffd60a",
      "4": "#5ac8fa",
      "5": "#bf5af2",
      "6": "#64d2ff",
      "8": "#8e8e93",
    });
    const colors = ["keyword", "string", "entity.name.function", "entity.name.type", "comment"].map((scope) =>
      colorFor(built, scope),
    );
    expect(colors).toEqual(["#bf5af2", "#32d74b", "#5ac8fa", "#64d2ff", "#8e8e93"]);
    expect(new Set(colors).size).toBe(5);
  });

  test("contrast helpers", () => {
    expect(withMinimumContrast("#32d74b", "#000000", "#ffffff", 3)).toBe("#32d74b");
    expect(withMinimumContrast("rgb(1, 2, 3)", "#000000", "#ffffff", 3)).toBe("rgb(1, 2, 3)");
    expect(syntaxPaletteColor({}, [12, 4], "dark", "#000000", "#ffffff")).toBe("#0a84ff");
    expect(contrastBetween("#ffffff", "#000000")).toBe(21);
    expect(contrastBetween("red", "#000000")).toBeNull();
  });
});

function stubDependencies() {
  return {
    isBundled,
    extensionMap: EXTENSION_TO_FILE_FORMAT as Record<string, string>,
    register: () => {},
    isRegistered: () => false,
    resolveEmbedded: async () => [],
    warn: () => {},
  };
}

// One file-kind classifier for every surface that counts changed lines (Leo 2026-10-20): the pull
// request card's "+1,234 −177" breakdown and the diff viewer's grouped file list ("delineated
// diff") must agree on what a file is, so both read it from here and nowhere else.
//
// The kinds are the ones Leo named: Code, Tests, Mocks, Docs, Evals, Generated. A path falls in
// exactly one, by the first rule that matches, so a mock under `Tests/` counts as a mock and a
// generated file under `docs/` counts as generated. The host can also declare a path generated
// (gitattributes `linguist-generated`, the diff sidecar's `generatedPaths`); a declaration always
// wins over the path's own shape.

/** A changed file's kind. */
export type FileKind = "code" | "tests" | "mocks" | "docs" | "evals" | "generated";

/** The kinds in the order every surface lists them: what a person reads first comes first. */
export const FILE_KINDS: readonly FileKind[] = ["code", "tests", "mocks", "docs", "evals", "generated"];

/** A changed file: its path and the lines it added and removed. */
export type ChangedFile = {
  readonly path: string;
  readonly additions?: number;
  readonly deletions?: number;
};

/** What one kind adds up to across the change. */
export type KindTotal = {
  readonly kind: FileKind;
  readonly files: number;
  readonly additions: number;
  readonly deletions: number;
};

/** Lockfiles no one writes by hand; a change in one is noise next to the code beside it. */
const LOCKFILES = new Set([
  "bun.lock",
  "bun.lockb",
  "cargo.lock",
  "composer.lock",
  "flake.lock",
  "gemfile.lock",
  "go.sum",
  "package-lock.json",
  "package.resolved",
  "pnpm-lock.yaml",
  "poetry.lock",
  "uv.lock",
  "yarn.lock",
]);

/** Whole-name documents: a file named only this, whatever its extension. */
const DOC_NAMES = new Set([
  "authors",
  "changelog",
  "changes",
  "code_of_conduct",
  "contributing",
  "license",
  "licence",
  "notice",
  "readme",
  "security",
]);

/** Prose: documentation whatever folder it sits in. */
const PROSE_EXTENSIONS = new Set(["md", "mdx", "markdown", "rst", "adoc"]);
/** Prose, plus the extensions that are documentation only outside a test or fixture folder. */
const DOC_EXTENSIONS = new Set([...PROSE_EXTENSIONS, "txt"]);

/**
 * A folder that makes everything under it generated. Not `vendor`: this repo keeps 203
 * hand-written Swift files under `Vendor/appkit-native/`, and calling them generated would
 * collapse them behind "Load diff" in the viewer and book their lines as Generated on the card.
 * A vendored tree that really is unread is declared in `.gitattributes` instead.
 */
const GENERATED_FOLDERS = new Set(["__generated__", "__snapshots__", "generated", "node_modules"]);

/** A folder that makes everything under it a mock or a fixture. */
const MOCK_FOLDERS = new Set([
  "__fixtures__",
  "__mocks__",
  "fake",
  "fakes",
  "fixture",
  "fixtures",
  "mock",
  "mocks",
  "stub",
  "stubs",
  "testdata",
]);

/**
 * A folder that makes everything under it a test. Not `spec`: a `spec/` folder holds a protocol's
 * source of truth as often as it holds tests (`cmux-tui/spec/api-compat.json`,
 * `crates/acpmux/spec/acpmux-protocol.json`), and a spec file that is a test says so in its name.
 */
const TEST_FOLDERS = new Set(["__tests__", "bench", "benches", "benchmarks", "test", "tests"]);

/** A folder that makes everything under it an eval. */
const EVAL_FOLDERS = new Set(["eval", "evals", "evaluation", "evaluations"]);

/** A folder that makes everything under it documentation. */
const DOC_FOLDERS = new Set(["doc", "docs"]);

const GENERATED_SUFFIXES = [
  ".pb.go",
  ".pb.cc",
  ".pb.h",
  ".pbxproj",
  "_pb2.py",
  "_pb2_grpc.py",
  ".g.dart",
  ".g.cs",
  ".freezed.dart",
  ".min.js",
  ".min.css",
  ".js.map",
  ".css.map",
  ".snap",
  // Translation catalogs: Xcode and `scripts/localize-changes` write them, and 21 locales of one
  // string would otherwise swamp the code beside it.
  ".xcstrings",
  ".strings",
  ".stringsdict",
];

// A name matches a kind two ways: around a delimiter (`foo.test.ts`, `test_foo.py`, `foo-mock.ts`)
// and at a camel-case boundary (`AgentPaneTests.swift`, `MockHomeSource.swift`). Neither matches a
// word that merely contains the letters, so `latest.ts` and `evaluate.ts` stay code.

// `gen` and `generated` only at the end: `gen-strings.mjs` writes generated files, it is not one.
/** `name.generated.ts`, `name.gen.rs`, `name-generated.json`, `SettingsGenerated.swift`. */
const GENERATED_DELIMITED = /(?:^|[.\-_])(?:gen|generated)$/i;
const GENERATED_CAMEL = /[a-z0-9]Generated$/;
/** A document titled for its subject: `GENERATED.md`, not `api.generated.md`. */
const GENERATED_TITLE = /^(?:gen|generated)$/i;

/** `name.test.ts`, `name.spec.tsx`, `name_test.go`, `test_name.py`, `name.bench.ts`. */
const TEST_DELIMITED = /(?:^|[.\-_])(?:test|tests|spec|specs|bench|benchmark|benchmarks)(?:$|[.\-_])/i;
/** `AgentPaneTests.swift`, `ParserTest.java`, `routerSpec.ts`. */
const TEST_CAMEL = /[a-z0-9](?:Tests?|Specs?)$/;

/** `name.fixture.ts`, `fake_clock.rs`, `stub-server.py`, `testdata.json`. */
const MOCK_DELIMITED = /(?:^|[.\-_])(?:mock|mocks|fixture|fixtures|stub|stubs|fake|fakes|testdata)(?:$|[.\-_])/i;
/** `MockHomeSource.swift`, `mockFixture.ts`, `FakeClock.swift`. */
const MOCK_CAMEL = /^(?:Mock|Fixture|Stub|Fake)[A-Z0-9]|[a-z0-9](?:Mocks?|Fixtures?|Stubs?|Fakes?)$/;

/** `answers.eval.ts`, `tone-eval.json`, `ToneEvals.ts`. */
const EVAL_DELIMITED = /(?:^|[.\-_])(?:eval|evals)(?:$|[.\-_])/i;
const EVAL_CAMEL = /[a-z0-9]Evals?$/;

function segments(path: string): string[] {
  return path.split("/").filter((part) => part.length > 0 && part !== ".");
}

/** The file name without its last extension, and the lowercased extension (no dot). */
function split(name: string): { stem: string; extension: string } {
  const dot = name.lastIndexOf(".");
  if (dot <= 0) return { stem: name, extension: "" };
  return { stem: name.slice(0, dot), extension: name.slice(dot + 1).toLowerCase() };
}

/**
 * A changed file's kind from its path alone. `declaredGenerated` is what the host says is
 * generated (gitattributes, the diff sidecar's list); it wins over every path rule.
 */
export function fileKind(path: string, declaredGenerated?: ReadonlySet<string>): FileKind {
  if (declaredGenerated?.has(path)) return "generated";
  const parts = segments(path);
  const name = parts[parts.length - 1] ?? "";
  const lower = name.toLowerCase();
  const folders = parts.slice(0, -1).map((part) => part.toLowerCase());
  const { stem, extension } = split(name);
  const has = (folder: ReadonlySet<string>) => folders.some((part) => folder.has(part));

  const prose = PROSE_EXTENSIONS.has(extension);

  if (LOCKFILES.has(lower)) return "generated";
  if (GENERATED_SUFFIXES.some((suffix) => lower.endsWith(suffix))) return "generated";
  // A document titled for its subject is still a document: the four hand-written
  // `Resources/**/GENERATED.md` in this repo explain which script writes that directory, and a
  // person reads them. `api.generated.md` keeps its delimited suffix and stays generated, as does
  // any prose in a generated tree.
  if (!(prose && GENERATED_TITLE.test(stem)) && (GENERATED_DELIMITED.test(stem) || GENERATED_CAMEL.test(stem)))
    return "generated";
  if (has(GENERATED_FOLDERS)) return "generated";

  // Prose is documentation wherever it sits: `plans/mermaid-EVAL.md` is a plan, not an eval.
  if (prose) return "docs";

  // The file's own name is the more specific signal, so it is read before its folders. Among
  // names, "test" wins: `agent-fixtures.test.ts` and `test_browser_eval.py` are tests.
  if (TEST_DELIMITED.test(stem) || TEST_CAMEL.test(stem)) return "tests";
  if (EVAL_DELIMITED.test(stem) || EVAL_CAMEL.test(stem)) return "evals";
  if (MOCK_DELIMITED.test(stem) || MOCK_CAMEL.test(stem)) return "mocks";

  // Among folders the narrower one wins: everything under `Tests/Fixtures/` is a fixture.
  if (has(EVAL_FOLDERS)) return "evals";
  if (has(MOCK_FOLDERS)) return "mocks";
  if (has(TEST_FOLDERS)) return "tests";

  if (DOC_EXTENSIONS.has(extension)) return "docs";
  // The whole name, never the stem: `LICENSE` and `CHANGELOG` are documents, but `changelog.ts`,
  // `security.ts` and `changes.css` are the code that serves them. A document with an extension
  // is already caught above, because its extension is prose or `.txt`.
  if (DOC_NAMES.has(lower)) return "docs";
  if (has(DOC_FOLDERS)) return "docs";

  return "code";
}

/**
 * `items` in ``FILE_KINDS`` order, each read by `pathOf`: the "delineated diff" every changes list
 * shares. The sort is stable, so items of one kind keep the order they came in, and a list of one
 * kind comes back as the same array, so a view re-renders nothing.
 */
export function orderByKind<T>(
  items: readonly T[],
  pathOf: (item: T) => string,
  declaredGenerated?: ReadonlySet<string>,
): readonly T[] {
  if (items.length < 2) return items;
  const ranked = items.map((item, index) => ({
    item,
    index,
    rank: FILE_KINDS.indexOf(fileKind(pathOf(item), declaredGenerated)),
  }));
  if (ranked.every((entry) => entry.rank === ranked[0]!.rank)) return items;
  ranked.sort((left, right) => left.rank - right.rank || left.index - right.index);
  return ranked.map((entry) => entry.item);
}

/**
 * The change's lines by kind, in ``FILE_KINDS`` order, leaving out a kind nothing touched.
 * `declaredGenerated` is the host's generated list, as in ``fileKind``.
 */
export function kindTotals(files: readonly ChangedFile[], declaredGenerated?: ReadonlySet<string>): KindTotal[] {
  const totals = new Map<FileKind, { files: number; additions: number; deletions: number }>();
  for (const file of files) {
    const kind = fileKind(file.path, declaredGenerated);
    const total = totals.get(kind) ?? { files: 0, additions: 0, deletions: 0 };
    total.files += 1;
    total.additions += file.additions ?? 0;
    total.deletions += file.deletions ?? 0;
    totals.set(kind, total);
  }
  return FILE_KINDS.filter((kind) => totals.has(kind)).map((kind) => ({ kind, ...totals.get(kind)! }));
}

/**
 * True when the change writes code and no test: the pull request card's "no tests" warning.
 * A change that is only docs, or only generated files, is not missing anything.
 */
export function missingTests(files: readonly ChangedFile[], declaredGenerated?: ReadonlySet<string>): boolean {
  let code = false;
  for (const file of files) {
    const kind = fileKind(file.path, declaredGenerated);
    if (kind === "tests") return false;
    if (kind === "code") code = true;
  }
  return code;
}

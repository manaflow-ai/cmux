// Picks the Shiki language for one diff file: user overrides, user (custom) grammars, the parsed
// language, known file names, the extension, then the shebang. Every answer is checked against
// the languages that can load, so an unknown id falls through to the next rule and finally to
// plain text; a file never fails to render because of its language. Pure: no Shiki or DOM access,
// the caller passes what is loadable.

export const PLAIN_TEXT_LANGUAGE = "text";

/// The `extension -> language` and `file name -> language` maps a user writes in
/// `languages/overrides.json`. Values are language ids or aliases; `text` turns highlighting off.
export type LanguageOverrides = {
  extensions?: Record<string, string>;
  filenames?: Record<string, string>;
};

/// Where a user grammar applies, from its manifest.
export type CustomLanguageMapping = {
  id: string;
  aliases?: readonly string[];
  extensions?: readonly string[];
  filenames?: readonly string[];
};

export type LanguageDetectorConfig = {
  /// Whether a canonical id (after alias resolution) can be loaded: a bundled Shiki language
  /// or a registered user grammar.
  isLoadable: (language: string) => boolean;
  /// Built-in `extension -> language`, keyed without the leading dot; compound keys such as
  /// `component.ts` are allowed (Pierre's `EXTENSION_TO_FILE_FORMAT`).
  extensionMap: Readonly<Record<string, string>>;
  custom?: readonly CustomLanguageMapping[];
  overrides?: LanguageOverrides;
};

export type LanguageDetectionInput = {
  path: string;
  /// A language the patch parser or the host already chose; `text` counts as no choice.
  parsedLanguage?: unknown;
  /// The file's first line, for `#!` detection. Only consulted when nothing else matched.
  firstLine?: string;
};

/// File names (lowercased) whose language the extension does not tell.
const languageByFileName: Record<string, string> = {
  ".bash_aliases": "shellscript",
  ".bash_login": "shellscript",
  ".bash_logout": "shellscript",
  ".bash_profile": "shellscript",
  ".bashrc": "shellscript",
  ".envrc": "shellscript",
  ".profile": "shellscript",
  ".xprofile": "shellscript",
  ".zlogin": "shellscript",
  ".zlogout": "shellscript",
  ".zprofile": "shellscript",
  ".zshenv": "shellscript",
  ".zshrc": "shellscript",
  apkbuild: "shellscript",
  pkgbuild: "shellscript",
  ".env": "dotenv",
  ".vimrc": "viml",
  ".gvimrc": "viml",
  _vimrc: "viml",
  ".exrc": "viml",
  ".editorconfig": "ini",
  ".gitconfig": "ini",
  ".gitmodules": "ini",
  ".npmrc": "ini",
  ".babelrc": "jsonc",
  ".eslintrc": "jsonc",
  ".jshintrc": "jsonc",
  ".prettierrc": "jsonc",
  ".swcrc": "jsonc",
  "bun.lock": "jsonc",
  "devcontainer.json": "jsonc",
  "jsconfig.json": "jsonc",
  "tsconfig.json": "jsonc",
  "flake.lock": "json",
  "package.resolved": "json",
  ".clang-format": "yaml",
  ".clang-tidy": "yaml",
  "podfile.lock": "yaml",
  "cargo.lock": "toml",
  pipfile: "toml",
  "poetry.lock": "toml",
  "uv.lock": "toml",
  containerfile: "docker",
  dockerfile: "docker",
  bsdmakefile: "make",
  gnumakefile: "make",
  makefile: "make",
  justfile: "just",
  ".justfile": "just",
  "cmakelists.txt": "cmake",
  appfile: "ruby",
  berksfile: "ruby",
  brewfile: "ruby",
  capfile: "ruby",
  "config.ru": "ruby",
  dangerfile: "ruby",
  deliverfile: "ruby",
  fastfile: "ruby",
  gemfile: "ruby",
  guardfile: "ruby",
  gymfile: "ruby",
  matchfile: "ruby",
  pluginfile: "ruby",
  podfile: "ruby",
  rakefile: "ruby",
  scanfile: "ruby",
  snapfile: "ruby",
  thorfile: "ruby",
  vagrantfile: "ruby",
  ".irbrc": "ruby",
  ".pryrc": "ruby",
  jenkinsfile: "groovy",
  build: "python",
  "build.bazel": "python",
  "module.bazel": "python",
  sconscript: "python",
  sconstruct: "python",
  snakefile: "python",
  workspace: "python",
  "workspace.bazel": "python",
  wscript: "python",
  codeowners: "codeowners",
  commit_editmsg: "git-commit",
  merge_msg: "git-commit",
  "git-rebase-todo": "git-rebase",
  ".htaccess": "apache",
  "nginx.conf": "nginx",
  ssh_config: "ssh-config",
  sshd_config: "ssh-config",
};

/// File name patterns (lowercased basename) checked after the exact names.
const languageByFileNamePattern: Array<[RegExp, string]> = [
  [/^\.env\..+$/, "dotenv"],
  [/^(docker|container)file\..+$/, "docker"],
  [/^makefile\..+$/, "make"],
  [/^tsconfig\..+\.json$/, "jsonc"],
  [/^\.(babel|eslint|prettier)rc\.json$/, "jsonc"],
  [/^\.(bash|zsh)rc\..+$/, "shellscript"],
];

/// Extensions where cmux disagrees with, or fills a gap in, Pierre's map.
const cmuxLanguageByExtension: Record<string, string> = {
  adoc: "asciidoc",
  asciidoc: "asciidoc",
  bazel: "python",
  bzl: "python",
  "code-workspace": "jsonc",
  cu: "cpp",
  cuh: "cpp",
  entitlements: "xml",
  geojson: "json",
  gradle: "groovy",
  gyp: "python",
  gypi: "python",
  har: "json",
  hurl: "hurl",
  ino: "cpp",
  ipynb: "json",
  just: "just",
  kdl: "kdl",
  m: "objective-c",
  markdown: "markdown",
  md: "markdown",
  mdown: "markdown",
  mdx: "mdx",
  metal: "cpp",
  mkd: "markdown",
  mkdn: "markdown",
  ndjson: "jsonl",
  odin: "odin",
  pkl: "pkl",
  pl: "perl",
  plist: "xml",
  pyi: "python",
  pyw: "python",
  pyx: "python",
  ron: "ron",
  rst: "rst",
  storyboard: "xml",
  svg: "xml",
  toml: "toml",
  tsbuildinfo: "json",
  webmanifest: "json",
  xcprivacy: "xml",
  xcscheme: "xml",
  xcstrings: "json",
  xcworkspacedata: "xml",
  xib: "xml",
  "zsh-theme": "shellscript",
};

/// Interpreters named after `#!` (or `#!/usr/bin/env [-S]`), without version suffixes.
const languageByInterpreter: Record<string, string> = {
  ash: "shellscript",
  awk: "awk",
  bash: "shellscript",
  bun: "typescript",
  dash: "shellscript",
  deno: "typescript",
  elixir: "elixir",
  fish: "fish",
  gawk: "awk",
  groovy: "groovy",
  julia: "julia",
  ksh: "shellscript",
  lua: "lua",
  luajit: "lua",
  make: "make",
  node: "javascript",
  nodejs: "javascript",
  nu: "nushell",
  osascript: "applescript",
  perl: "perl",
  php: "php",
  pwsh: "powershell",
  pypy: "python",
  python: "python",
  racket: "racket",
  rscript: "r",
  ruby: "ruby",
  sh: "shellscript",
  swift: "swift",
  tclsh: "tcl",
  "ts-node": "typescript",
  tsx: "typescript",
  wish: "tcl",
  zsh: "shellscript",
};

export function basenameOf(path: string): string {
  return path.split(/[\\/]/).at(-1)?.trim() ?? "";
}

/// Every dotted suffix of a basename, longest first: `a.spec.ts` -> `spec.ts`, `ts`;
/// `.zshrc` -> `zshrc`.
export function extensionCandidates(basename: string): string[] {
  const candidates: string[] = [];
  for (let index = basename.indexOf("."); index >= 0; index = basename.indexOf(".", index + 1)) {
    const suffix = basename.slice(index + 1);
    if (suffix.length > 0) candidates.push(suffix);
  }
  return candidates;
}

/// The language a `#!` line names, or undefined.
export function shebangLanguage(firstLine: string | undefined): string | undefined {
  const match = firstLine?.match(/^#!\s*(\S+)(.*)$/);
  if (match == null) return undefined;
  let program = basenameOf(match[1]);
  if (program === "env") {
    const args = match[2].trim().split(/\s+/);
    program = args.find((arg) => arg.length > 0 && !arg.startsWith("-") && !arg.includes("=")) ?? "";
  }
  const name = program.toLowerCase().replace(/[\d.]+$/, "");
  return languageByInterpreter[name];
}

export function createLanguageDetector(config: LanguageDetectorConfig) {
  const aliasToId = new Map<string, string>();
  const customByFileName = new Map<string, string>();
  const customByExtension = new Map<string, string>();
  for (const language of config.custom ?? []) {
    for (const alias of language.aliases ?? []) aliasToId.set(alias.toLowerCase(), language.id);
    for (const name of language.filenames ?? []) customByFileName.set(name.toLowerCase(), language.id);
    for (const extension of language.extensions ?? []) {
      customByExtension.set(normalizeExtension(extension), language.id);
    }
  }
  const overrideByFileName = lowerKeys(config.overrides?.filenames);
  const overrideByExtension = new Map(
    Object.entries(config.overrides?.extensions ?? {}).map(([key, value]) => [normalizeExtension(key), value]),
  );

  /// The loadable canonical id for an id or alias, `text` for an explicit plain-text choice,
  /// undefined when nothing by that name can load.
  const canonical = (value: unknown): string | undefined => {
    if (typeof value !== "string") return undefined;
    const trimmed = value.trim();
    if (trimmed.length === 0) return undefined;
    const lowered = trimmed.toLowerCase();
    if (lowered === "text" || lowered === "plain" || lowered === "plaintext" || lowered === "txt") {
      return PLAIN_TEXT_LANGUAGE;
    }
    // A user grammar's id and aliases win over a bundled language of the same name.
    for (const candidate of [aliasToId.get(lowered), trimmed, lowered]) {
      if (candidate != null && config.isLoadable(candidate)) return candidate;
    }
    return undefined;
  };

  const byExtension = (candidates: string[], table: (key: string) => string | undefined) => {
    for (const candidate of candidates) {
      const language = canonical(table(candidate));
      if (language != null) return language;
    }
    return undefined;
  };

  return function detect({ path, parsedLanguage, firstLine }: LanguageDetectionInput): string {
    const basename = basenameOf(path);
    const lowerName = basename.toLowerCase();
    const extensions = extensionCandidates(lowerName);
    const exactCaseExtensions = extensionCandidates(basename);

    const userChoice =
      canonical(overrideByFileName.get(lowerName)) ??
      byExtension(extensions, (key) => overrideByExtension.get(key)) ??
      canonical(customByFileName.get(lowerName)) ??
      byExtension(extensions, (key) => customByExtension.get(key));
    if (userChoice != null) return userChoice;

    const parsed = canonical(parsedLanguage);
    if (parsed != null && parsed !== PLAIN_TEXT_LANGUAGE) return parsed;

    const known =
      canonical(languageByFileName[lowerName]) ??
      canonical(languageByFileNamePattern.find(([pattern]) => pattern.test(lowerName))?.[1]) ??
      byExtension(extensions, (key) => cmuxLanguageByExtension[key]) ??
      byExtension(exactCaseExtensions, (key) => config.extensionMap[key]) ??
      byExtension(extensions, (key) => config.extensionMap[key]) ??
      canonical(config.extensionMap[basename]) ??
      canonical(shebangLanguage(firstLine));
    return known ?? PLAIN_TEXT_LANGUAGE;
  };
}

export type LanguageDetector = ReturnType<typeof createLanguageDetector>;

function normalizeExtension(extension: string): string {
  return extension
    .trim()
    .replace(/^\*?\./, "")
    .toLowerCase();
}

function lowerKeys(record: Record<string, string> | undefined): Map<string, string> {
  return new Map(Object.entries(record ?? {}).map(([key, value]) => [key.toLowerCase(), value]));
}

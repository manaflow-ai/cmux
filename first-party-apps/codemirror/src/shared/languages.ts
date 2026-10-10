// Language ids (shared by the editor apps; identical copies in
// first-party-apps/codemirror/src/shared). The document type's
// language id wins; a path's extension is the fallback for diffs.

const BY_EXTENSION: Record<string, string> = {
  ts: "typescript", tsx: "typescript", mts: "typescript", cts: "typescript",
  js: "javascript", jsx: "javascript", mjs: "javascript", cjs: "javascript",
  json: "json", jsonc: "json",
  md: "markdown", markdown: "markdown", mdx: "markdown",
  py: "python", rs: "rust", go: "go", swift: "swift", rb: "ruby", java: "java", kt: "kotlin",
  c: "cpp", h: "cpp", cc: "cpp", cpp: "cpp", hpp: "cpp", m: "objective-c", mm: "objective-c",
  css: "css", scss: "scss", less: "less", html: "html", htm: "html", xml: "xml", svg: "xml",
  sh: "shell", bash: "shell", zsh: "shell", fish: "shell",
  yml: "yaml", yaml: "yaml", toml: "ini", ini: "ini", sql: "sql", zig: "plaintext", txt: "plaintext"
}

const BY_NAME: Record<string, string> = { dockerfile: "dockerfile", makefile: "plaintext", "cmux.json": "json" }

export function languageForPath(path: string | undefined): string {
  if (!path) return "plaintext"
  const name = path.slice(path.lastIndexOf("/") + 1).toLowerCase()
  if (BY_NAME[name]) return BY_NAME[name]!
  const dot = name.lastIndexOf(".")
  return dot > 0 ? (BY_EXTENSION[name.slice(dot + 1)] ?? "plaintext") : "plaintext"
}

/** Display names for the status line. */
const NAMES: Record<string, string> = {
  typescript: "TypeScript", javascript: "JavaScript", json: "JSON", markdown: "Markdown", python: "Python", rust: "Rust", go: "Go",
  swift: "Swift", ruby: "Ruby", java: "Java", kotlin: "Kotlin", cpp: "C/C++", "objective-c": "Objective-C", css: "CSS", scss: "SCSS",
  less: "Less", html: "HTML", xml: "XML", shell: "Shell", yaml: "YAML", ini: "TOML", sql: "SQL", dockerfile: "Dockerfile", plaintext: "Plain Text"
}

export const languageName = (id: string) => NAMES[id] ?? id

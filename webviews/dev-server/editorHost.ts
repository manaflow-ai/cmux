// Pure pieces of the code editor's dev host (plugins.ts `editorHost`), split out so tests can cover
// them. Dev server only; nothing here ships. The app's host (diff-host.md "Editor page") follows the
// same rules: any regular file under the readable roots opens; files outside the workspace roots, not
// valid UTF-8, binary or not writable open read only; a save writes the text's UTF-8 bytes only when
// the file's hash is the page's base hash and the bytes differ.
import fs from "node:fs";
import path from "node:path";
import { contentHash, stripJSONC } from "./markdownHost";

export type ReadOnlyReason = "outside" | "encoding" | "binary" | "permission";

/** The largest file the dev host opens (Monaco's heap operations stop at 256M characters). */
export const EDITOR_MAX_BYTES = 200 * 1024 * 1024;

export class EditorRefused extends Error {
  constructor(
    readonly code: "cmux.editor.not_found" | "cmux.editor.not_file" | "cmux.editor.too_large" | "cmux.editor.refused",
    message: string,
  ) {
    super(message);
  }
}

const below = (real: string, base: string) => real === base || real.startsWith(`${base}/`);

function realRoots(roots: readonly string[]): string[] {
  return roots.flatMap((root) => {
    try {
      return [fs.realpathSync(root)];
    } catch {
      return [];
    }
  });
}

/**
 * The files the dev editor may open: regular files whose real path is below a readable root (the
 * home folder and the workspace roots); writable only below a workspace root.
 */
export function editorFiles(options: { workspaceRoots: readonly string[]; readableRoots: readonly string[] }) {
  const workspace = realRoots(options.workspaceRoots);
  const readable = [...workspace, ...realRoots(options.readableRoots)];
  return {
    workspace,
    /** The real path of `requested` (absolute), or an EditorRefused. */
    resolve(requested: string): string {
      if (!requested || !path.isAbsolute(requested)) throw new EditorRefused("cmux.editor.not_found", requested);
      let real: string;
      try {
        real = fs.realpathSync(requested);
      } catch {
        throw new EditorRefused("cmux.editor.not_found", requested);
      }
      if (!readable.some((root) => below(real, root))) throw new EditorRefused("cmux.editor.refused", requested);
      const stat = fs.statSync(real);
      if (!stat.isFile()) throw new EditorRefused("cmux.editor.not_file", requested);
      if (stat.size > EDITOR_MAX_BYTES) throw new EditorRefused("cmux.editor.too_large", requested);
      return real;
    },
    /** Whether the page may save `file` (below a workspace root). */
    inWorkspace: (file: string) => workspace.some((root) => below(file, root)),
  };
}

export interface EditorFileContent {
  text: string;
  hash: string;
  size: number;
  readOnlyReason: ReadOnlyReason | null;
}

/** Whether `bytes` look binary: a NUL byte in the first 8000 bytes, as git decides. */
export function looksBinary(bytes: Uint8Array): boolean {
  const end = Math.min(bytes.length, 8000);
  for (let index = 0; index < end; index++) if (bytes[index] === 0) return true;
  return false;
}

/** Whether `bytes` are valid UTF-8. */
export function isUTF8(bytes: Uint8Array): boolean {
  try {
    new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
    return true;
  } catch {
    return false;
  }
}

/**
 * A file as the editor gets it, or undefined when it is gone. The text is the bytes decoded as UTF-8
 * with nothing removed: a BOM stays as U+FEFF, line endings stay. Not valid UTF-8, binary, outside
 * the workspace or not writable: read only, with the reason.
 */
export function readEditorFile(file: string, inWorkspace: boolean): EditorFileContent | undefined {
  let bytes: Buffer;
  try {
    bytes = fs.readFileSync(file);
  } catch {
    return undefined;
  }
  // `ignoreBOM: true` keeps U+FEFF in the text (TextDecoder strips it by default).
  const text = new TextDecoder("utf-8", { ignoreBOM: true }).decode(bytes);
  let readOnlyReason: ReadOnlyReason | null = null;
  if (looksBinary(bytes)) readOnlyReason = "binary";
  else if (!isUTF8(bytes)) readOnlyReason = "encoding";
  else if (!inWorkspace) readOnlyReason = "outside";
  else {
    try {
      fs.accessSync(file, fs.constants.W_OK);
    } catch {
      readOnlyReason = "permission";
    }
  }
  return { text, hash: contentHash(bytes), size: bytes.length, readOnlyReason };
}

export type EditorSaveOutcome =
  | { ok: true; hash: string; written: boolean }
  | { ok: false; code: "cmux.editor.conflict"; details: { hash: string | null; text?: string; deleted?: boolean } }
  | { ok: false; code: "cmux.editor.read_only" };

/**
 * `cmux.editor.save`: writes `text` as UTF-8 when the file's hash is `baseHash` (null: the file must
 * not exist), through a temporary file and a rename so a reader never sees half a file; the file keeps
 * its mode. Bytes equal to the file's are not written (`written: false`).
 */
export function saveEditorFile(
  file: string,
  text: string,
  baseHash: string | null,
  inWorkspace: boolean,
): EditorSaveOutcome {
  const current = readEditorFile(file, inWorkspace);
  if (current?.readOnlyReason || (!current && !inWorkspace)) return { ok: false, code: "cmux.editor.read_only" };
  if ((current?.hash ?? null) !== baseHash) {
    return {
      ok: false,
      code: "cmux.editor.conflict",
      details: current ? { hash: current.hash, text: current.text } : { hash: null, deleted: true },
    };
  }
  const bytes = Buffer.from(text, "utf8");
  const hash = contentHash(bytes);
  if (current && hash === current.hash) return { ok: true, hash, written: false };
  const temporary = path.join(path.dirname(file), `.${path.basename(file)}.cmux-save-${process.pid}`);
  let mode = 0o644;
  try {
    mode = fs.statSync(file).mode & 0o7777;
  } catch {}
  fs.writeFileSync(temporary, bytes, { mode });
  fs.renameSync(temporary, file);
  return { ok: true, hash, written: true };
}

/** The dev settings store for `cmux.editor.setPreference`: `editor.*` keys in a JSON file. */
export function editorPreferences(file: string) {
  const read = (): Record<string, unknown> => {
    try {
      const value = JSON.parse(fs.readFileSync(file, "utf8"));
      return value && typeof value === "object" && !Array.isArray(value) ? value : {};
    } catch {
      return {};
    }
  };
  return {
    file,
    read,
    /** Stores one key; false for a key outside `editor.*` or a value that is not small JSON. */
    set(key: string, value: unknown): boolean {
      if (!/^editor\.[A-Za-z][A-Za-z0-9.]{0,80}$/.test(key)) return false;
      const json = JSON.stringify(value);
      if (json === undefined || json.length > 2048) return false;
      const all = read();
      all[key] = value;
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, `${JSON.stringify(all, null, 2)}\n`);
      return true;
    },
  };
}

/** `section` with every `editor.a.b` preference set at `a.b` (preferences win). */
export function withPreferences(section: unknown, preferences: Record<string, unknown>): Record<string, unknown> {
  const root: Record<string, unknown> =
    section && typeof section === "object" && !Array.isArray(section)
      ? structuredClone(section as Record<string, unknown>)
      : {};
  for (const [key, value] of Object.entries(preferences)) {
    const parts = key.replace(/^editor\./, "").split(".");
    let node = root;
    for (const part of parts.slice(0, -1)) {
      const next = node[part];
      // A boolean shorthand (`minimap: false`) becomes the object form it stands for.
      node[part] =
        typeof next === "boolean"
          ? { enabled: next }
          : next && typeof next === "object" && !Array.isArray(next)
            ? next
            : {};
      node = node[part] as Record<string, unknown>;
    }
    node[parts.at(-1)!] = value;
  }
  return root;
}

/** The editor's look for the dev host: cmux.json's `editor` section with the preferences, theme.css. */
export function readEditorLook(
  configFile: string,
  preferences: Record<string, unknown>,
): { settings: Record<string, unknown>; syntaxTheme?: unknown; themeCSS: string } {
  let config: { editor?: unknown; appearance?: { syntaxTheme?: unknown } } = {};
  try {
    config = JSON.parse(stripJSONC(fs.readFileSync(configFile, "utf8")));
  } catch {}
  let themeCSS = "";
  try {
    themeCSS = fs.readFileSync(path.join(path.dirname(configFile), "editor", "theme.css"), "utf8");
  } catch {}
  return {
    settings: withPreferences(config.editor, preferences),
    syntaxTheme: config.appearance?.syntaxTheme,
    themeCSS,
  };
}

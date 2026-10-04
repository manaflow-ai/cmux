// The Files section of the selected machine (catalog `cloud.fs.*` and `cloud.file.*`, R71 C5).
// It reads on demand only: the first listing waits for Browse, so selecting a paused machine does not
// touch its disk. A small text file previews through `fs.stat` then `fs.read`; a larger file is never
// read. Make folder and save are ops with an idempotency key. Remove deletes data and push and pull
// reach files of this Mac, so the page never calls them: the host runs them after its native
// confirmation or file panel (`cmux.app.action.run`) and adds the local path the person picked.
// A reply for another machine than the selected one is dropped.
import type { PageClient } from "../shared/pageClient";
import type { MachineDetail } from "./detail";
import {
  ACTION_RUN,
  CloudOps,
  isUnsupported,
  type ActionRunResult,
  type FsEntry,
  type FsListResult,
  type FsReadResult,
} from "./ops";

/** Where Browse starts: the home of user `cmux`, the user the Cloud API names for the machine. */
export const FILES_HOME = "/home/cmux";

/** The largest file the page reads for a preview. Larger files show their size only. */
export const PREVIEW_LIMIT = 256 * 1024;

export interface FilePreview {
  path: string;
  size: number;
  /** The UTF-8 text of a small file. */
  text?: string;
  /** Larger than PREVIEW_LIMIT: not read. */
  tooLarge?: boolean;
  /** Not valid UTF-8 text. */
  binary?: boolean;
}

export interface FilesView {
  path: string;
  entries?: FsEntry[];
  loading: boolean;
  preview?: FilePreview;
}

export interface FilesHost {
  get(): MachineDetail | undefined;
  set(detail: MachineDetail): void;
  fail(error: unknown): void;
  unsupported(op: string): void;
  canChange(): boolean;
  key(): string;
}

/** `dir` + `name` without a double slash. */
export function joinPath(dir: string, name: string): string {
  return dir === "/" ? `/${name}` : `${dir}/${name}`;
}

export function parentPath(path: string): string {
  return path.slice(0, path.lastIndexOf("/")) || "/";
}

/** A single new folder name: no slash, no NUL or control character, not `.` or `..`. */
export function validName(name: string): boolean {
  // eslint-disable-next-line no-control-regex
  return name !== "" && name !== "." && name !== ".." && !/[/\u0000-\u001f\u007f]/.test(name);
}

function decodeText(base64: string): string | undefined {
  const bytes = Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
  if (bytes.includes(0)) return undefined;
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return undefined;
  }
}

function encodeText(text: string): string {
  let binary = "";
  for (const byte of new TextEncoder().encode(text)) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export class FilesReader {
  /** Bumped by each listing: an older listing's reply is dropped. */
  private generation = 0;

  constructor(
    private readonly client: PageClient | null,
    private readonly host: FilesHost,
  ) {}

  /** Lists a folder of the selected machine (Browse, a folder row, Up). */
  async open(path: string = FILES_HOME): Promise<void> {
    const machine = this.machine();
    if (!machine) return;
    const generation = ++this.generation;
    const current = this.host.get()?.files;
    const kept = current?.path === path ? current.entries : undefined;
    this.update(machine, { path, entries: kept, loading: true });
    try {
      const result = await this.client!.call<FsListResult>(CloudOps.fsList, { machine, path });
      if (generation !== this.generation) return;
      this.update(machine, { path: result.path ?? path, entries: result.entries, loading: false });
    } catch (error) {
      if (generation !== this.generation) return;
      this.update(machine, { path, entries: kept ?? [], loading: false });
      this.reject(machine, CloudOps.fsList, error);
    }
  }

  up(): Promise<void> {
    const files = this.host.get()?.files;
    return files ? this.open(parentPath(files.path)) : Promise.resolve();
  }

  /** Shows a small text file: its size from `fs.stat` first, so a large file is never read. */
  async preview(path: string): Promise<void> {
    const machine = this.machine();
    if (!machine) return;
    try {
      const stat = await this.client!.call<FsEntry>(CloudOps.fsStat, { machine, path });
      if (stat.kind === "directory") return this.open(path);
      const size = stat.size ?? 0;
      if (size > PREVIEW_LIMIT) return this.showPreview(machine, { path, size, tooLarge: true });
      const read = await this.client!.call<FsReadResult>(CloudOps.fsRead, { machine, path });
      const text = decodeText(read.dataBase64);
      this.showPreview(
        machine,
        text === undefined ? { path, size: read.size, binary: true } : { path, size: read.size, text },
      );
    } catch (error) {
      this.reject(machine, CloudOps.fsStat, error);
    }
  }

  closePreview(): void {
    const detail = this.host.get();
    if (detail?.files?.preview) this.host.set({ ...detail, files: { ...detail.files, preview: undefined } });
  }

  /** Writes the whole file (`fs.write`), then shows the saved text. */
  async save(path: string, text: string): Promise<void> {
    const machine = this.machine();
    if (!machine || !this.host.canChange()) return;
    const dataBase64 = encodeText(text);
    try {
      const result = await this.client!.call<{ size: number }>(CloudOps.fsWrite, {
        machine,
        path,
        dataBase64,
        idempotency_key: this.host.key(),
      });
      this.showPreview(machine, { path, size: result?.size ?? text.length, text });
      await this.refresh(machine);
    } catch (error) {
      this.reject(machine, CloudOps.fsWrite, error);
    }
  }

  /** Makes a folder in the current folder. A name that is not one path segment makes no call. */
  async mkdir(name: string): Promise<void> {
    const machine = this.machine();
    const files = this.host.get()?.files;
    const trimmed = name.trim();
    if (!machine || !files || !validName(trimmed) || !this.host.canChange()) return;
    try {
      await this.client!.call(CloudOps.fsMkdir, {
        machine,
        path: joinPath(files.path, trimmed),
        idempotency_key: this.host.key(),
      });
      await this.refresh(machine);
    } catch (error) {
      this.reject(machine, CloudOps.fsMkdir, error);
    }
  }

  /** Deletes a file or folder after the host's native confirmation. */
  async remove(path: string): Promise<void> {
    const machine = this.machine();
    if (!machine) return;
    if (!(await this.native(machine, CloudOps.fsRemove, { machine, path }))) return;
    const detail = this.host.get();
    if (detail?.machine === machine && detail.files?.preview?.path === path) this.closePreview();
    await this.refresh(machine);
  }

  /**
   * Copies a local file into the current folder. The host shows its native file panel, adds the
   * picked `localPath` and appends the file's name to `path` (README "Host gaps").
   */
  async push(): Promise<void> {
    const machine = this.machine();
    const files = this.host.get()?.files;
    if (!machine || !files) return;
    if (await this.native(machine, CloudOps.filePush, { machine, path: files.path })) await this.refresh(machine);
  }

  /** Copies a file of the machine to this Mac; the host's save panel picks `localPath`. */
  async pull(path: string): Promise<void> {
    const machine = this.machine();
    if (machine) await this.native(machine, CloudOps.filePull, { machine, path });
  }

  private machine(): string | undefined {
    return this.client ? this.host.get()?.machine : undefined;
  }

  /** A confirmed native action answers true; a declined sheet or a failure answers false. */
  private async native(machine: string, action: string, args: Record<string, unknown>): Promise<boolean> {
    if (!this.host.canChange()) return false;
    try {
      const result = await this.client!.call<ActionRunResult | null>(ACTION_RUN, {
        action,
        args: { ...args, idempotency_key: this.host.key() },
      });
      return result?.confirmed !== false;
    } catch (error) {
      this.reject(machine, action, error);
      return false;
    }
  }

  private async refresh(machine: string): Promise<void> {
    const files = this.host.get()?.files;
    if (files && this.host.get()?.machine === machine) await this.open(files.path);
  }

  private showPreview(machine: string, preview: FilePreview): void {
    const detail = this.host.get();
    if (detail?.machine !== machine || !detail.files) return;
    this.host.set({ ...detail, files: { ...detail.files, preview } });
  }

  /** Writes the view only while `machine` is still the selected one. */
  private update(machine: string, view: Omit<FilesView, "preview">): void {
    const detail = this.host.get();
    if (detail?.machine !== machine) return;
    this.host.set({ ...detail, files: { ...view, preview: detail.files?.preview } });
  }

  private reject(machine: string, op: string, error: unknown): void {
    if (this.host.get()?.machine !== machine) return;
    if (isUnsupported(error)) this.host.unsupported(op);
    else this.host.fail(error);
  }
}

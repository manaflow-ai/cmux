// The mock's files, port forwards and browser routes. Shapes follow the Cloud app server
// (first-party-apps/cloud/server/src/fs/files.rs, fs/transfer.rs, src/ports/ops.rs): file ops are the
// machine daemon's `fs.*` ops behind the `fs-v1` gate, and their errors are the server's
// (`unsupported` naming fs-v1, `file_ops_busy`, `file_too_large`, `transfer_busy`). Arguments the
// catalog does not list are refused like the server does. Nothing here touches a real machine or port.
import { pageError } from "../shared/pageClient";
import { sampleFiles, type SampleFile } from "./mockData";
import { CloudErrors, CloudOps, type BrowserRoute, type FsEntry, type PortForward, type TransferChanged } from "./ops";

type Params = Record<string, unknown>;

/** `cloud.fs.read` refuses files over 16 MiB before their bytes move (server `MAX_READ_BYTES`). */
export const READ_LIMIT = 16 * 1024 * 1024;
/** One daemon `fs.write` and one push carry at most 12 MiB (server `MAX_WRITE_BYTES`, decision D2). */
export const WRITE_LIMIT = 12 * 1024 * 1024;

/** The server runs at most 4 transfers at once; more answer `cmux.cloud.transfer_busy` (retryable). */
export const MAX_TRANSFERS = 4;

/** `cmux.cloud.not_found` as the server answers it (a daemon `fs.not_found`, a machine or snapshot). */
export function notFound(message: string) {
  return pageError(CloudErrors.notFound, message);
}

const FS_OPS = new Set<string>([
  CloudOps.fsList,
  CloudOps.fsStat,
  CloudOps.fsRead,
  CloudOps.fsWrite,
  CloudOps.fsMkdir,
  CloudOps.fsRemove,
  CloudOps.filePush,
  CloudOps.filePull,
]);

const EDGE_OPS = new Set<string>([CloudOps.portList, CloudOps.portForward, CloudOps.portClose, CloudOps.browserOpen]);

/** Refuses an argument the catalog does not list, like the server's `args::object`. */
export function only(p: Params, allowed: readonly string[]): void {
  const extra = Object.keys(p).find((key) => !allowed.includes(key));
  if (extra) throw pageError("cmux.cloud.invalid_args", `unknown field ${extra}`);
}

const parent = (path: string) => path.slice(0, path.lastIndexOf("/")) || "/";
const base = (path: string) => path.slice(path.lastIndexOf("/") + 1);
const bytes = (text: string) => new TextEncoder().encode(text);

function encode(text: string): string {
  let binary = "";
  for (const byte of bytes(text)) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function decode(base64: string): Uint8Array {
  return Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
}

const tooLarge = (what: string, size: number, bound: number) =>
  pageError(CloudErrors.fileTooLarge, `${what} is ${size} bytes; the limit is ${bound} bytes`);

export class MockFiles {
  private readonly machines = new Map<string, Map<string, SampleFile>>();
  /** Transfers that answered `running` and have not ended: each makes its end event. */
  private readonly running: Array<(cancelled?: boolean) => TransferChanged> = [];
  private nextTransfer = 1;
  /** Every file op worker is taken (server `MAX_FILE_OPS`): the next file op answers busy. */
  opsBusy = false;

  /** Ends every running transfer (the copy finished) and answers their events, in start order. */
  finishTransfers(): TransferChanged[] {
    return this.running.splice(0).map((finish) => finish());
  }

  /** `cloud.file.transfer.cancel` of every running transfer: each ends `cancelled`, with no bytes. */
  cancelTransfers(): TransferChanged[] {
    return this.running.splice(0).map((finish) => finish(true));
  }

  get runningTransfers(): number {
    return this.running.length;
  }

  static serves(op: string): boolean {
    return FS_OPS.has(op);
  }

  /** Checks the arguments the server checks before its `fs-v1` gate. */
  check(op: string, p: Params): void {
    if (op === CloudOps.filePush || op === CloudOps.filePull) only(p, ["machine", "localPath", "path"]);
    else if (op === CloudOps.fsWrite) only(p, ["machine", "path", "dataBase64", "mode", "baseRevision"]);
    else only(p, ["machine", "path"]);
    if (op === CloudOps.fsWrite && p.mode !== undefined && p.mode !== null)
      throw pageError(CloudErrors.unsupported, "The machine's daemon write keeps the file's mode; it cannot set one");
    if ((op === CloudOps.filePush || op === CloudOps.filePull) && this.running.length >= MAX_TRANSFERS)
      throw pageError(CloudErrors.transferBusy, "Other file transfers are running: try again when one ends", true);
  }

  /** Runs one file op after the gate passed. */
  serve(op: string, p: Params, machine: string): unknown {
    if (FS_OPS.has(op) && !op.startsWith("cmux.cloud.file.") && this.opsBusy)
      throw pageError(CloudErrors.fileOpsBusy, "Other file ops are running: try again when one ends", true);
    const tree = this.tree(machine);
    const path = String(p.path);
    switch (op) {
      case CloudOps.fsList: {
        if (this.get(tree, path).kind !== "directory")
          throw pageError("cmux.cloud.invalid_args", `${path} is not a directory`);
        const entries = [...tree.keys()]
          .filter((key) => key !== path && parent(key) === path)
          .map((key) => this.entry(tree, key, false));
        return { path, entries };
      }
      case CloudOps.fsStat:
        return this.entry(tree, path, true);
      case CloudOps.fsRead: {
        const file = this.get(tree, path);
        if (file.kind === "directory") throw pageError("cmux.cloud.invalid_args", `${path} is a directory`);
        const size = this.size(file);
        if (size > READ_LIMIT || file.text === undefined) throw tooLarge(path, size, READ_LIMIT);
        return { path, dataBase64: encode(file.text), size };
      }
      case CloudOps.fsWrite: {
        const data = decode(String(p.dataBase64));
        if (data.length > WRITE_LIMIT) throw tooLarge("the data", data.length, WRITE_LIMIT);
        const current = tree.get(path);
        if (typeof p.baseRevision === "string" && (!current || this.revision(current) !== p.baseRevision))
          throw pageError("cmux.cloud.conflict", `${path} changed since it was read`);
        const next: SampleFile = {
          kind: "file",
          text: new TextDecoder().decode(data),
          modifiedAt: (current?.modifiedAt ?? 0) + 1,
        };
        tree.set(path, next);
        return { ok: true, path, size: data.length, revision: this.revision(next) };
      }
      case CloudOps.fsMkdir:
        this.get(tree, parent(path));
        if (tree.has(path)) throw pageError("cmux.cloud.conflict", `${path} exists`);
        tree.set(path, { kind: "directory" });
        return { ok: true, path };
      case CloudOps.fsRemove:
        this.get(tree, path);
        for (const key of tree.keys()) if (key === path || key.startsWith(`${path}/`)) tree.delete(key);
        return { ok: true, path };
      case CloudOps.filePush:
        // The file lands when the copy ends, not when the op answers.
        return this.transfer(machine, "push", path, String(p.localPath), () => {
          tree.set(path, { kind: "file", text: "uploaded\n" });
          return 9;
        });
      default: {
        const size = this.size(this.get(tree, path));
        return this.transfer(machine, "pull", path, String(p.localPath), () => size);
      }
    }
  }

  /** Answers `running` at once; the end event comes from `finishTransfers` (the server's worker). */
  private transfer(machine: string, direction: "push" | "pull", path: string, localPath: string, copy: () => number) {
    const transfer = `transfer-${this.nextTransfer++}`;
    this.running.push((cancelled) =>
      cancelled
        ? { transfer, machine, direction, path, localPath, state: "cancelled" }
        : { transfer, machine, direction, path, localPath, state: "done", bytes: copy() },
    );
    return { ok: true, transfer, state: "running", machine, path, localPath };
  }

  private tree(machine: string): Map<string, SampleFile> {
    let tree = this.machines.get(machine);
    if (!tree) this.machines.set(machine, (tree = sampleFiles()));
    return tree;
  }

  private get(tree: Map<string, SampleFile>, path: string): SampleFile {
    const file = tree.get(path);
    if (!file) throw notFound(`${path} does not exist`);
    return file;
  }

  private size(file: SampleFile): number {
    return file.text === undefined ? (file.size ?? 0) : bytes(file.text).length;
  }

  /** The daemon's revision string (`s<size>-m<mtime>`). */
  private revision(file: SampleFile): string {
    return `s${this.size(file)}-m${file.modifiedAt ?? 0}`;
  }

  /** A list entry has the name; a stat answer has the full path and the revision. */
  private entry(tree: Map<string, SampleFile>, path: string, stat: boolean): FsEntry {
    const file = this.get(tree, path);
    return {
      ...(stat ? { path } : { name: base(path) }),
      kind: file.kind,
      size: file.kind === "file" ? this.size(file) : null,
      mode: null,
      modifiedAt: file.modifiedAt ?? null,
      ...(stat && file.kind === "file" ? { revision: this.revision(file) } : {}),
    };
  }
}

/** This Mac's forwards and browser routes: one forward per (machine, port), one route per machine. */
export class MockEdge {
  forwards: PortForward[] = [];
  private nextPort = 49_152;

  static serves(op: string): boolean {
    return EDGE_OPS.has(op);
  }

  serve(op: string, p: Params, machineOf: (p: Params) => string): unknown {
    switch (op) {
      case CloudOps.portList:
        only(p, ["machine"]);
        return {
          forwards: this.forwards.filter((forward) => p.machine === undefined || forward.machine === p.machine),
        };
      case CloudOps.portForward: {
        only(p, ["machine", "port"]);
        const machine = machineOf(p);
        const port = Number(p.port);
        const open = this.forwards.find((f) => f.machine === machine && f.port === port && f.state === "up");
        if (open) return open;
        const forward: PortForward = {
          machine,
          port,
          host: "127.0.0.1",
          localPort: this.nextPort++,
          generation: 1,
          state: "up",
          reason: null,
        };
        this.forwards = [...this.forwards.filter((f) => !(f.machine === machine && f.port === port)), forward];
        return forward;
      }
      case CloudOps.portClose: {
        only(p, ["machine", "port"]);
        const machine = String(p.machine);
        const before = this.forwards.length;
        this.forwards = this.forwards.filter((f) => !(f.machine === machine && f.port === p.port));
        return { machine, port: p.port, closed: this.forwards.length < before };
      }
      default: {
        only(p, ["machine", "port", "host", "path"]);
        const route: BrowserRoute = {
          machine: machineOf(p),
          proxy: { kind: "http", host: "127.0.0.1", port: this.nextPort++ },
          url: `http://${typeof p.host === "string" ? p.host : "localhost"}:${Number(p.port)}${typeof p.path === "string" ? p.path : "/"}`,
          generation: 1,
        };
        return route;
      }
    }
  }
}

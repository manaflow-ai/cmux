// The mock's files, port forwards and browser routes (R71 C5). Shapes follow the Cloud app server
// (first-party-apps/cloud/server/tests/fixtures/fs-*.json, src/ports/ops.rs); arguments the catalog
// does not list are refused like the server does. Nothing here touches a real machine or port.
import { pageError } from "../shared/pageClient";
import { sampleFiles, type SampleFile } from "./mockData";
import { CloudOps, type BrowserRoute, type FsEntry, type PortForward } from "./ops";

type Params = Record<string, unknown>;

/** `cloud.fs.read` refuses files over 16 MiB before their bytes move. */
const READ_LIMIT = 16 * 1024 * 1024;

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
  if (extra) throw pageError("cmux.cloud.invalid_args", `unknown argument ${extra}`);
}

const parent = (path: string) => path.slice(0, path.lastIndexOf("/")) || "/";
const base = (path: string) => path.slice(path.lastIndexOf("/") + 1);
const bytes = (text: string) => new TextEncoder().encode(text);

function encode(text: string): string {
  let binary = "";
  for (const byte of bytes(text)) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function decode(base64: string): string {
  return new TextDecoder().decode(Uint8Array.from(atob(base64), (char) => char.charCodeAt(0)));
}

export class MockFiles {
  private readonly machines = new Map<string, Map<string, SampleFile>>();

  static serves(op: string): boolean {
    return FS_OPS.has(op);
  }

  serve(op: string, p: Params, machine: string): unknown {
    const tree = this.tree(machine);
    const path = String(p.path);
    switch (op) {
      case CloudOps.fsList: {
        only(p, ["machine", "path"]);
        if (this.get(tree, path).kind !== "directory") throw pageError("cmux.cloud.invalid_args", `${path} is not a folder`);
        const entries = [...tree.keys()].filter((key) => key !== path && parent(key) === path).map((key) => this.entry(tree, key, false));
        return { path, entries };
      }
      case CloudOps.fsStat:
        only(p, ["machine", "path"]);
        return this.entry(tree, path, true);
      case CloudOps.fsRead: {
        only(p, ["machine", "path"]);
        const file = this.get(tree, path);
        const size = this.size(file);
        if (size > READ_LIMIT || file.text === undefined) throw pageError("cmux.cloud.file_too_large", `${path} is too large`);
        return { path, dataBase64: encode(file.text), size };
      }
      case CloudOps.fsWrite: {
        only(p, ["machine", "path", "dataBase64", "mode", "baseRevision"]);
        const text = decode(String(p.dataBase64));
        tree.set(path, { ...tree.get(path), kind: "file", text, size: undefined });
        return { ok: true, path, size: bytes(text).length };
      }
      case CloudOps.fsMkdir:
        only(p, ["machine", "path"]);
        this.get(tree, parent(path));
        tree.set(path, { kind: "directory" });
        return { ok: true, path };
      case CloudOps.fsRemove:
        only(p, ["machine", "path"]);
        this.get(tree, path);
        for (const key of [...tree.keys()]) if (key === path || key.startsWith(`${path}/`)) tree.delete(key);
        return { ok: true, path };
      case CloudOps.filePush:
        only(p, ["machine", "localPath", "path"]);
        tree.set(path, { kind: "file", text: "uploaded\n" });
        return { ok: true, machine, path, localPath: p.localPath, bytes: 9 };
      default: {
        only(p, ["machine", "localPath", "path"]);
        return { ok: true, machine, path, localPath: p.localPath, bytes: this.size(this.get(tree, path)) };
      }
    }
  }

  private tree(machine: string): Map<string, SampleFile> {
    let tree = this.machines.get(machine);
    if (!tree) this.machines.set(machine, (tree = sampleFiles()));
    return tree;
  }

  private get(tree: Map<string, SampleFile>, path: string): SampleFile {
    const file = tree.get(path);
    if (!file) throw pageError("cmux.cloud.not_found", `no such path ${path}`);
    return file;
  }

  private size(file: SampleFile): number {
    return file.text === undefined ? (file.size ?? 0) : bytes(file.text).length;
  }

  /** A list entry has the name; a stat answer has the full path. */
  private entry(tree: Map<string, SampleFile>, path: string, stat: boolean): FsEntry {
    const file = this.get(tree, path);
    return {
      ...(stat ? { path } : { name: base(path) }),
      kind: file.kind,
      ...(file.kind === "file" ? { size: this.size(file) } : {}),
      ...(file.mode !== undefined ? { mode: file.mode } : {}),
      ...(file.modifiedAt !== undefined ? { modifiedAt: file.modifiedAt } : {}),
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
        return { forwards: this.forwards.filter((forward) => p.machine === undefined || forward.machine === p.machine) };
      case CloudOps.portForward: {
        only(p, ["machine", "port"]);
        const machine = machineOf(p);
        const port = Number(p.port);
        const open = this.forwards.find((f) => f.machine === machine && f.port === port && f.state === "up");
        if (open) return open;
        const forward: PortForward = { machine, port, host: "127.0.0.1", localPort: this.nextPort++, generation: 1, state: "up", reason: null };
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

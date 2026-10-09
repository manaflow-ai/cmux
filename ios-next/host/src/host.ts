// HostCore wires the providers into one RpcServer. Every Link (WebRTC peer,
// loopback, future transports) is attached to the same core.

import { hostname, release } from "node:os";
import { RpcServer, type HostInfo } from "./rpc/index.ts";
import type { Link } from "./transport/link.ts";
import { AgentsProvider, type AgentsProviderOptions } from "./providers/agents.ts";
import { BrowserProvider, type BrowserProviderOptions } from "./providers/browser/index.ts";
import { ChiefProvider } from "./providers/chief.ts";
import { FilesProvider, type FilesOptions } from "./providers/files.ts";
import { TerminalProvider, type TerminalOptions } from "./providers/terminal.ts";
import { VERSION, type Logger } from "./util.ts";

export interface HostCoreOptions {
  hostId?: string;
  hostName?: string;
  log?: Logger;
  terminal?: TerminalOptions;
  agents?: AgentsProviderOptions;
  browser?: BrowserProviderOptions;
  conversationsPath?: string;
  files?: FilesOptions;
}

export class HostCore {
  readonly server: RpcServer;
  readonly terminals: TerminalProvider;
  readonly agents: AgentsProvider;
  readonly chief: ChiefProvider;
  readonly browser: BrowserProvider;
  readonly files: FilesProvider;
  hostId: string;
  readonly hostName: string;

  constructor(opts: HostCoreOptions = {}) {
    const log = opts.log ?? (() => {});
    this.hostId = opts.hostId ?? "local";
    this.hostName = opts.hostName ?? hostname().replace(/\.local$/, "");
    this.server = new RpcServer(() => this.info(), log);
    this.terminals = new TerminalProvider(opts.terminal);
    this.agents = new AgentsProvider({ log, ...opts.agents });
    this.chief = new ChiefProvider(this.agents, { log, hostName: this.hostName, path: opts.conversationsPath });
    this.browser = new BrowserProvider({ log, ...opts.browser });
    this.files = new FilesProvider(opts.files);
    this.terminals.register(this.server);
    this.agents.register(this.server);
    this.chief.register(this.server);
    this.browser.register(this.server);
    this.files.register(this.server);
  }

  info(): HostInfo {
    const capabilities = ["term.v1", "agent.v1", "conv.v1", "fs.v1"];
    if (this.browser.capable) capabilities.push("browser.v1");
    return {
      hostId: this.hostId,
      hostName: this.hostName,
      os: `macOS ${release()}`,
      version: VERSION,
      capabilities,
    };
  }

  attach(link: Link) {
    return this.server.attach(link);
  }

  shutdown(): void {
    this.terminals.closeAll();
    this.agents.shutdown();
    this.chief.flush();
    this.browser.close();
  }
}

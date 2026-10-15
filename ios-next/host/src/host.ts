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
import type { AgentSession } from "./protocol.ts";
import type { AcpmuxAgents } from "./bridge/acpmuxAgents.ts";
import type { DaemonTerminals } from "./bridge/daemonTerminals.ts";
import { DaemonLayout, registerLayout, StandaloneLayout, type LayoutSource } from "./layout/index.ts";
import type { MacBrowser } from "./bridge/macBrowser.ts";

const HARNESS_DISPLAY: Record<string, string> = { claude: "Claude Code", codex: "Codex", opencode: "OpenCode", gemini: "Gemini" };

export interface HostCoreOptions {
  hostId?: string;
  hostName?: string;
  log?: Logger;
  terminal?: TerminalOptions;
  agents?: AgentsProviderOptions;
  browser?: BrowserProviderOptions;
  conversationsPath?: string;
  files?: FilesOptions;
  /**
   * Bridge to the cmux-next app on this Mac: when set, term.* and agent.*
   * are served from its daemon and acpmux instead of the host's own PTYs and
   * agents (Chief keeps using the host's agents for its own session).
   */
  bridge?: { terminals?: DaemonTerminals; agents?: AcpmuxAgents; layout?: LayoutSource; mac?: MacBrowser };
}

export class HostCore {
  readonly server: RpcServer;
  readonly terminals: TerminalProvider;
  readonly agents: AgentsProvider;
  readonly chief: ChiefProvider;
  readonly browser: BrowserProvider;
  readonly files: FilesProvider;
  readonly bridge: { terminals?: DaemonTerminals; agents?: AcpmuxAgents; layout?: LayoutSource; mac?: MacBrowser };
  readonly layout: LayoutSource;
  hostId: string;
  readonly hostName: string;

  constructor(opts: HostCoreOptions = {}) {
    const log = opts.log ?? (() => {});
    this.hostId = opts.hostId ?? "local";
    this.hostName = opts.hostName ?? hostname().replace(/\.local$/, "");
    this.server = new RpcServer(() => this.info(), log);
    this.terminals = new TerminalProvider(opts.terminal);
    this.agents = new AgentsProvider({ log, ...opts.agents });
    const bridgedAgents = opts.bridge?.agents;
    this.chief = new ChiefProvider(this.agents, {
      log,
      hostName: this.hostName,
      path: opts.conversationsPath,
      // Bridge mode: Chief's /spawn starts a real cmux-next (acpmux) session
      // and keeps an agent:<sessionId> conversation for it.
      ...(bridgedAgents
        ? {
            bridged: {
              create: async (harness: string, task: string) => ({
                session: await bridgedAgents.create({ harness, prompt: task }),
                harnessName: HARNESS_DISPLAY[harness] ?? harness,
              }),
              prompt: (sessionId: string, text: string) => bridgedAgents.prompt(sessionId, text, []),
              lastReply: (sessionId: string) => bridgedAgents.lastReply(sessionId),
            },
          }
        : {}),
    });
    bridgedAgents?.on("event", (topic, payload) => {
      if (topic === "agent.session") this.chief.bridgedSession((payload as { session: AgentSession }).session);
      else if (topic === "agent.removed") this.chief.bridgedRemoved((payload as { sessionId: string }).sessionId);
    });
    this.browser = new BrowserProvider({ log, ...opts.browser });
    this.files = new FilesProvider({ log, ...opts.files });
    this.bridge = opts.bridge ?? {};
    if (this.bridge.terminals) this.bridge.terminals.register(this.server);
    else this.terminals.register(this.server);
    if (this.bridge.agents) this.bridge.agents.register(this.server);
    else this.agents.register(this.server);
    if (this.bridge.layout) this.layout = this.bridge.layout;
    else {
      const standalone = new StandaloneLayout(
        {
          terminals: () => this.terminals.list(),
          tabs: async () => (this.browser.connected ? (await this.browser.list()).map((t) => ({ id: t.id, title: t.title, url: t.url })) : []),
        },
        this.hostName,
      );
      let pending: NodeJS.Timeout | null = null;
      const changed = (topic: string) => {
        if (!/^(term\.(updated|exited)|browser\.(tab|closed))$/.test(topic) || pending) return;
        pending = setTimeout(() => {
          pending = null;
          void standalone.changed().catch(() => {});
        }, 150);
        pending.unref?.();
      };
      this.terminals.on("event", changed);
      this.browser.on("event", changed);
      this.layout = standalone;
    }
    registerLayout(this.server, this.layout);
    const layout = this.layout;
    if (layout instanceof DaemonLayout) this.browser.on("event", () => layout.invalidate());
    const mac = this.bridge.mac;
    if (mac) {
      // The Mac's "view browser tabs" setting decides which browser browser.*
      // serves: the Mac's own tabs (mirrored) when on, the host's Chrome otherwise.
      this.server.register("browser.macStatus", () => mac.current);
      mac.on("targets", () => {
        if (layout instanceof DaemonLayout) layout.invalidate();
      });
      mac.on("status", (status) => {
        this.server.broadcast("browser.macStatus", status);
        this.browser.reconnect();
        if (status.state === "on") void this.browser.connect().catch((err) => log(`Mac browser connect failed: ${(err as Error).message}`));
        if (layout instanceof DaemonLayout) layout.invalidate();
      });
    }
    this.chief.register(this.server);
    this.browser.register(this.server);
    this.files.register(this.server);
  }

  info(): HostInfo {
    const capabilities = ["term.v1", "agent.v1", "conv.v1", "fs.v1", "layout.v1"];
    if (this.browser.capable) capabilities.push("browser.v1");
    // Terminals belong to the Mac (cmux-next app): the phone must not resize them.
    if (this.bridge.terminals) capabilities.push("term.mirror.v1");
    // Agent sessions belong to the Mac (acpmux): permission allows happen there.
    if (this.bridge.agents) capabilities.push("agent.mirror.v1");
    // Mac browser tabs and the browser.macStatus banner (bridge mode).
    if (this.bridge.mac) capabilities.push("browser.mac.v1");
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
    this.bridge.terminals?.shutdown();
    this.bridge.agents?.shutdown();
    this.layout.shutdown();
    this.bridge.mac?.stop();
    this.chief.flush();
    this.browser.close();
    this.files.close();
  }
}

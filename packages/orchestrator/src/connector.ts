import {
  createMorphCloudClient,
  type MorphCloudClient,
  type InstanceModel,
  type InstanceHttpService,
  execInstanceInstanceIdExecPost,
  getInstanceInstanceInstanceIdGet,
  listInstancesInstanceGet,
} from "@cmux/morphcloud-openapi-client";

/**
 * Morph Connector
 *
 * Connects to Morph instances to:
 * 1. List running sessions
 * 2. Execute commands (for injecting messages)
 * 3. Read Claude Code output
 */

export interface MorphSession {
  instanceId: string;
  status: string;
  metadata: Record<string, string>;
  httpServices: Array<{ name: string; url: string }>;
}

export interface SessionFilter {
  userId?: string;
  teamId?: string;
  taskRunId?: string;
}

export interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

export class MorphConnector {
  private client: MorphCloudClient;

  constructor(apiKey?: string) {
    const key = apiKey ?? process.env.MORPH_API_KEY;
    if (!key) {
      throw new Error("MORPH_API_KEY is required");
    }
    this.client = createMorphCloudClient({
      headers: {
        Authorization: `Bearer ${key}`,
      },
    });
  }

  /**
   * List running cmux sessions, optionally filtered by user/team
   */
  async listSessions(filter?: SessionFilter): Promise<MorphSession[]> {
    const response = await listInstancesInstanceGet({
      client: this.client,
    });

    // Response data is InstanceModelCollection with a .data array
    const collection = response.data;
    if (!collection?.data) {
      return [];
    }

    // Filter for cmux instances
    let instances = collection.data.filter((instance: InstanceModel) => {
      const metadata = instance.metadata;
      return metadata?.app?.startsWith("cmux");
    });

    // Apply additional filters
    if (filter?.userId) {
      instances = instances.filter(
        (i: InstanceModel) => i.metadata?.userId === filter.userId
      );
    }
    if (filter?.teamId) {
      instances = instances.filter(
        (i: InstanceModel) => i.metadata?.teamId === filter.teamId
      );
    }
    if (filter?.taskRunId) {
      instances = instances.filter(
        (i: InstanceModel) => i.metadata?.taskRunId === filter.taskRunId
      );
    }

    return instances.map((instance: InstanceModel) => ({
      instanceId: instance.id,
      status: instance.status ?? "unknown",
      metadata: instance.metadata ?? {},
      httpServices: (instance.networking?.http_services ?? []).map(
        (svc: InstanceHttpService) => ({
          name: svc.name,
          url: svc.url,
        })
      ),
    }));
  }

  /**
   * Get a specific session
   */
  async getSession(instanceId: string): Promise<MorphSession | null> {
    const response = await getInstanceInstanceInstanceIdGet({
      client: this.client,
      path: { instance_id: instanceId },
    });

    if (!response.data) {
      return null;
    }

    const instance = response.data;
    return {
      instanceId: instance.id,
      status: instance.status ?? "unknown",
      metadata: instance.metadata ?? {},
      httpServices: (instance.networking?.http_services ?? []).map(
        (svc: InstanceHttpService) => ({
          name: svc.name,
          url: svc.url,
        })
      ),
    };
  }

  /**
   * Execute a command in a session
   * Note: command is passed as a shell string, wrapped in bash -c
   */
  async exec(instanceId: string, command: string): Promise<ExecResult> {
    const response = await execInstanceInstanceIdExecPost({
      client: this.client,
      path: { instance_id: instanceId },
      body: { command: ["bash", "-c", command] },
    });

    if (!response.data) {
      throw new Error(`Exec failed: ${JSON.stringify(response.error)}`);
    }

    return {
      stdout: response.data.stdout ?? "",
      stderr: response.data.stderr ?? "",
      exitCode: response.data.exit_code ?? -1,
    };
  }

  /**
   * Read the Claude Code log file from a session
   * Claude Code typically writes to a log file we can tail
   */
  async readClaudeCodeOutput(
    instanceId: string,
    lastLines: number = 100
  ): Promise<string> {
    // Try common log locations
    const logPaths = [
      "/root/.claude/logs/claude.log",
      "/tmp/claude-code.log",
      "/root/workspace/.claude.log",
    ];

    for (const logPath of logPaths) {
      try {
        const result = await this.exec(
          instanceId,
          `tail -n ${lastLines} ${logPath} 2>/dev/null || echo ""`
        );
        if (result.stdout.trim()) {
          return result.stdout;
        }
      } catch {
        // Log file doesn't exist, try next
      }
    }

    return "";
  }

  /**
   * Read the tmux pane output (if Claude Code runs in tmux)
   */
  async readTmuxOutput(
    instanceId: string,
    sessionName: string = "main"
  ): Promise<string> {
    try {
      const result = await this.exec(
        instanceId,
        `tmux capture-pane -t ${sessionName} -p -S -500 2>/dev/null || echo ""`
      );
      return result.stdout;
    } catch {
      return "";
    }
  }

  /**
   * Find the tmux session where Claude Code is running
   */
  async findClaudeCodeSession(instanceId: string): Promise<string | null> {
    try {
      // List all tmux sessions and find one running claude-code
      const result = await this.exec(
        instanceId,
        `tmux list-sessions -F "#{session_name}" 2>/dev/null || echo ""`
      );

      const sessions = result.stdout.trim().split("\n").filter(Boolean);

      // Try each session to find one running claude-code
      for (const session of sessions) {
        const paneCheck = await this.exec(
          instanceId,
          `tmux list-panes -t "${session}" -F "#{pane_current_command}" 2>/dev/null | grep -E "(claude|bun|node)" || echo ""`
        );
        if (paneCheck.stdout.trim()) {
          return session;
        }
      }

      // Fallback: try common session names
      const commonNames = ["main", "agent", "claude", "0"];
      for (const name of commonNames) {
        const check = await this.exec(
          instanceId,
          `tmux has-session -t "${name}" 2>/dev/null && echo "EXISTS" || echo ""`
        );
        if (check.stdout.includes("EXISTS")) {
          return name;
        }
      }

      return null;
    } catch {
      return null;
    }
  }

  /**
   * Inject a message into Claude Code's conversation
   * Finds the right tmux session and sends keystrokes
   */
  async injectMessage(instanceId: string, message: string): Promise<boolean> {
    try {
      // Find the tmux session
      const sessionName = await this.findClaudeCodeSession(instanceId);
      if (!sessionName) {
        console.error(`[Orchestrator] No tmux session found in ${instanceId}`);
        return false;
      }

      // Escape the message for shell
      const escapedMessage = message
        .replace(/\\/g, "\\\\")
        .replace(/"/g, '\\"')
        .replace(/\$/g, "\\$")
        .replace(/`/g, "\\`")
        .replace(/'/g, "\\'");

      // Send to tmux session
      const result = await this.exec(
        instanceId,
        `tmux send-keys -t "${sessionName}" "${escapedMessage}" Enter 2>&1`
      );

      // Check if send-keys succeeded (no output usually means success)
      return result.exitCode === 0;
    } catch (error) {
      console.error(`[Orchestrator] Failed to inject message:`, error);
      return false;
    }
  }

  /**
   * Check if Claude Code is currently running in a session
   */
  async isClaudeCodeRunning(instanceId: string): Promise<boolean> {
    try {
      const result = await this.exec(
        instanceId,
        `pgrep -f "claude-code" || pgrep -f "@anthropic-ai/claude-code" || echo ""`
      );
      return result.stdout.trim().length > 0;
    } catch {
      return false;
    }
  }
}

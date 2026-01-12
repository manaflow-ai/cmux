/**
 * Docker Connector for cmux-local
 *
 * Uses Docker as the runtime and state store.
 * All task metadata is stored in Docker labels.
 */

import { spawn } from "node:child_process";
import * as path from "node:path";
import * as fs from "node:fs";
import { nanoid } from "nanoid";
import { type Task, type MCPQuestion, type MCPProgress, BASE_PORT, getTaskPort } from "./types.js";

/**
 * Orchestration Protocol - instructs Claude to output structured markers
 */
const ORCHESTRATION_PROTOCOL = `
## Orchestration Protocol

You are being monitored by an orchestrator that helps humans stay in the loop.
Use these lightweight markers in your output so the orchestrator can extract key information:

**When you make a significant decision:**
\`\`\`
DECISION: [topic] -> [choice] because [rationale]
\`\`\`
Example: DECISION: [hashing algorithm] -> [bcrypt] because simpler and sufficient for our scale

**When you need human input (unclear requirements, multiple valid approaches, etc.):**
\`\`\`
QUESTION: [your question]
OPTIONS: [option1] | [option2] | [option3]
LEANING: [your suggestion] because [why]
\`\`\`
Example:
QUESTION: Should sessions use JWT or cookies?
OPTIONS: JWT (stateless) | Cookies (simpler)
LEANING: Cookies because simpler for MVP, avoids refresh token complexity

**When you make an assumption that the human should know about:**
\`\`\`
ASSUMING: [what you're assuming]
\`\`\`
Example: ASSUMING: 24 hour session expiry is acceptable

**When your focus changes to a new task area:**
\`\`\`
FOCUS: [what you're working on now]
\`\`\`
Example: FOCUS: Implementing password hashing

**Guidelines:**
- Use markers sparingly - only for significant decisions, not every tiny choice
- Keep working even if you haven't heard back on a QUESTION - don't block yourself
- If you're 80%+ confident on a decision, just note it with DECISION and continue
- Use QUESTION only when genuinely uncertain about user intent or when there are multiple valid approaches

The orchestrator will surface important questions to the human and auto-answer trivial ones.
Continue to work normally - these markers are just annotations on your natural workflow.
`;

/**
 * Wrap a user prompt with the orchestration protocol
 */
function wrapPromptWithProtocol(userPrompt: string): string {
  return `${ORCHESTRATION_PROTOCOL}

---

## Your Task

${userPrompt}`;
}

/**
 * Execute a command and return stdout
 */
async function exec(command: string): Promise<{ stdout: string; stderr: string; code: number }> {
  return new Promise((resolve) => {
    const child = spawn("bash", ["-c", command]);
    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (data) => {
      stdout += data.toString();
    });

    child.stderr.on("data", (data) => {
      stderr += data.toString();
    });

    child.on("close", (code) => {
      resolve({ stdout, stderr, code: code ?? 0 });
    });

    child.on("error", (err) => {
      resolve({ stdout, stderr: err.message, code: 1 });
    });
  });
}

/**
 * Find a free port starting from the given base
 */
async function findFreePort(start: number): Promise<number> {
  for (let port = start; port < start + 100; port++) {
    const result = await exec(`lsof -i :${port} 2>/dev/null | grep LISTEN`);
    if (!result.stdout.trim()) {
      return port;
    }
  }
  throw new Error(`No free port found in range ${start}-${start + 100}`);
}

/**
 * Escape a string for use in shell commands
 */
function escapeShell(str: string): string {
  return str
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\$/g, "\\$")
    .replace(/`/g, "\\`");
}

export class DockerConnector {
  private imageName = "cmux-local-worker";
  private imageBuilding = false;

  /**
   * Check if Docker is available
   */
  async checkDocker(): Promise<boolean> {
    const result = await exec("docker info 2>/dev/null");
    return result.code === 0;
  }

  /**
   * Get the path to the Dockerfile
   */
  private getDockerfilePath(): string {
    // Try to find Dockerfile relative to this file
    // Use import.meta.url which is standard ESM
    const currentDir = path.dirname(new URL(import.meta.url).pathname);
    const possiblePaths = [
      path.join(currentDir, "..", "Dockerfile"),
      path.join(currentDir, "..", "..", "Dockerfile"),
      path.join(process.cwd(), "packages", "cmux-local", "Dockerfile"),
    ];

    for (const p of possiblePaths) {
      if (fs.existsSync(p)) {
        return p;
      }
    }

    return "";
  }

  /**
   * Build or ensure the worker image exists
   */
  async ensureImage(): Promise<void> {
    // Check if image exists
    const result = await exec(`docker images -q ${this.imageName}`);
    if (result.stdout.trim()) {
      return; // Image exists
    }

    if (this.imageBuilding) {
      // Wait for build to complete
      while (this.imageBuilding) {
        await new Promise((r) => setTimeout(r, 1000));
      }
      return;
    }

    this.imageBuilding = true;

    try {
      console.log("Building cmux-local-worker image (this may take a few minutes)...");

      // Try to use Dockerfile from package
      const dockerfilePath = this.getDockerfilePath();

      let buildCmd: string;
      if (dockerfilePath && fs.existsSync(dockerfilePath)) {
        const dockerfileDir = path.dirname(dockerfilePath);
        buildCmd = `docker build -t ${this.imageName} "${dockerfileDir}"`;
      } else {
        // Fallback: inline Dockerfile
        const dockerfile = `
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y curl git tmux ca-certificates && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs && rm -rf /var/lib/apt/lists/*
RUN curl -L https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64 -o /usr/local/bin/ttyd && chmod +x /usr/local/bin/ttyd
RUN npm install -g @anthropic-ai/claude-code
WORKDIR /workspace
EXPOSE 7681
CMD ["ttyd", "-p", "7681", "bash"]
`.trim();

        // Write dockerfile to temp and build
        const tmpDir = `/tmp/cmux-local-build-${Date.now()}`;
        await exec(`mkdir -p "${tmpDir}"`);
        fs.writeFileSync(`${tmpDir}/Dockerfile`, dockerfile);
        buildCmd = `docker build -t ${this.imageName} "${tmpDir}"`;
      }

      const buildResult = await exec(buildCmd);
      if (buildResult.code !== 0) {
        throw new Error(`Failed to build image: ${buildResult.stderr}`);
      }

      console.log("Image built successfully!");
    } finally {
      this.imageBuilding = false;
    }
  }

  /**
   * List all cmux tasks (Docker containers with cmux.task label)
   */
  async listTasks(): Promise<Task[]> {
    const result = await exec(
      `docker ps -a --filter "label=cmux.task=true" --format '{{.ID}}\\t{{.Names}}\\t{{.Status}}\\t{{.Label "cmux.repo"}}\\t{{.Label "cmux.prompt"}}\\t{{.Label "cmux.port"}}\\t{{.Label "cmux.number"}}\\t{{.Label "cmux.startedAt"}}\\t{{.Label "cmux.cmuxDir"}}'`
    );

    if (!result.stdout.trim()) {
      return [];
    }

    const tasks: Task[] = [];

    for (const line of result.stdout.trim().split("\n")) {
      const [containerId, name, status, repo, prompt, port, number, startedAt, cmuxDir] = line.split("\t");

      if (!containerId || !name) continue;

      const isRunning = status?.toLowerCase().includes("up");
      const taskId = name.replace("cmux-", "");

      tasks.push({
        id: taskId,
        number: parseInt(number || "0", 10),
        containerId,
        repoPath: repo || "",
        repoName: repo?.split("/").pop() || "unknown",
        prompt: prompt || "",
        terminalPort: parseInt(port || "0", 10),
        cmuxDir: cmuxDir || `/tmp/cmux-${taskId}`,
        status: isRunning ? "running" : "done",
        startedAt: startedAt ? new Date(startedAt) : new Date(),
        questions: [],
      });
    }

    // Sort by number
    return tasks.sort((a, b) => a.number - b.number);
  }

  /**
   * Read MCP questions from a task's communication directory
   */
  readMCPQuestions(task: Task): MCPQuestion[] {
    const questionsFile = path.join(task.cmuxDir, "questions.json");
    try {
      if (fs.existsSync(questionsFile)) {
        const content = fs.readFileSync(questionsFile, "utf-8");
        const questions = JSON.parse(content) as MCPQuestion[];
        // Filter to unanswered questions
        return questions.filter((q) => !q.answered);
      }
    } catch {
      // File doesn't exist or is invalid
    }
    return [];
  }

  /**
   * Read MCP progress updates from a task's communication directory
   */
  readMCPProgress(task: Task): MCPProgress[] {
    const progressFile = path.join(task.cmuxDir, "progress.json");
    try {
      if (fs.existsSync(progressFile)) {
        const content = fs.readFileSync(progressFile, "utf-8");
        return JSON.parse(content) as MCPProgress[];
      }
    } catch {
      // File doesn't exist or is invalid
    }
    return [];
  }

  /**
   * Write an answer to an MCP question
   */
  writeMCPAnswer(task: Task, questionId: string, answer: string): void {
    const answersFile = path.join(task.cmuxDir, "answers.json");
    let answers: Array<{ questionId: string; answer: string; timestamp: string }> = [];

    try {
      if (fs.existsSync(answersFile)) {
        answers = JSON.parse(fs.readFileSync(answersFile, "utf-8"));
      }
    } catch {
      // File doesn't exist or is invalid
    }

    answers.push({
      questionId,
      answer,
      timestamp: new Date().toISOString(),
    });

    fs.writeFileSync(answersFile, JSON.stringify(answers, null, 2));
  }

  /**
   * Get the next available task number
   */
  async getNextTaskNumber(): Promise<number> {
    const tasks = await this.listTasks();
    if (tasks.length === 0) return 1;
    return Math.max(...tasks.map((t) => t.number)) + 1;
  }

  /**
   * Start a new task
   */
  async startTask(repoPath: string, prompt: string, model?: string): Promise<Task> {
    await this.ensureImage();

    const taskId = nanoid(8);
    const taskNumber = await this.getNextTaskNumber();
    const terminalPort = await findFreePort(getTaskPort(taskNumber));
    const containerName = `cmux-${taskId}`;
    const startedAt = new Date().toISOString();

    // Resolve absolute path
    const absolutePath = repoPath.startsWith("/")
      ? repoPath
      : `${process.cwd()}/${repoPath}`.replace(/\/\.\//g, "/").replace(/\/+/g, "/");

    const repoName = absolutePath.split("/").pop() || "workspace";

    // Wrap prompt with orchestration protocol so Claude outputs structured markers
    const orchestratedPrompt = wrapPromptWithProtocol(prompt);

    // Escape prompt for shell
    const escapedPrompt = escapeShell(prompt);

    // Model flag (default to opus if specified)
    const modelFlag = model ? `--model ${model}` : "";

    // Start container with tmux + Claude Code
    // Use base64 encoding to safely pass the prompt and a startup script
    const promptBase64 = Buffer.from(orchestratedPrompt).toString("base64");

    // Create a startup script that will be base64 encoded
    const startupScript = `#!/bin/bash
PROMPT=$(echo '${promptBase64}' | base64 -d)
claude ${modelFlag} --dangerously-skip-permissions "\$PROMPT"
`.trim();
    const startupScriptBase64 = Buffer.from(startupScript).toString("base64");

    // Simple approach: ttyd starts tmux with Claude Code when browser connects
    // This is more reliable than trying to pre-start tmux in a non-interactive shell
    const startScript = [
      `echo '${startupScriptBase64}' | base64 -d > /tmp/start.sh`,
      `chmod +x /tmp/start.sh`,
      `ttyd -W -p 7681 tmux new-session -s main /tmp/start.sh`,
    ].join(" && ");

    // Build environment variables - prefer OAuth token over API key
    const envVars: string[] = [];
    if (process.env.CLAUDE_CODE_OAUTH_TOKEN) {
      envVars.push(`-e CLAUDE_CODE_OAUTH_TOKEN="${process.env.CLAUDE_CODE_OAUTH_TOKEN}"`);
    }
    if (process.env.ANTHROPIC_API_KEY) {
      envVars.push(`-e ANTHROPIC_API_KEY="${process.env.ANTHROPIC_API_KEY}"`);
    }
    const envString = envVars.join(" \\\n      ");

    // Create a host directory for this task's communication files
    const cmuxDir = `/tmp/cmux-${taskId}`;
    await exec(`mkdir -p "${cmuxDir}"`);

    const dockerCmd = `docker run -d \\
      --name ${containerName} \\
      --label cmux.task=true \\
      --label cmux.repo="${absolutePath}" \\
      --label cmux.prompt="${escapedPrompt}" \\
      --label cmux.port=${terminalPort} \\
      --label cmux.number=${taskNumber} \\
      --label cmux.startedAt="${startedAt}" \\
      --label cmux.cmuxDir="${cmuxDir}" \\
      -v "${absolutePath}":/workspace \\
      -v "${cmuxDir}":/tmp/cmux \\
      -p ${terminalPort}:7681 \\
      -w /workspace \\
      ${envString} \\
      ${this.imageName} \\
      bash -c '${startScript}'
    `;

    const result = await exec(dockerCmd);

    if (result.code !== 0) {
      throw new Error(`Failed to start container: ${result.stderr}`);
    }

    return {
      id: taskId,
      number: taskNumber,
      containerId: result.stdout.trim().slice(0, 12),
      repoPath: absolutePath,
      repoName,
      prompt,
      terminalPort,
      status: "starting",
      startedAt: new Date(startedAt),
      questions: [],
    };
  }

  /**
   * Stop a task
   */
  async stopTask(taskId: string): Promise<void> {
    const result = await exec(`docker stop cmux-${taskId} && docker rm cmux-${taskId}`);
    if (result.code !== 0) {
      throw new Error(`Failed to stop task: ${result.stderr}`);
    }
  }

  /**
   * Stop all tasks
   */
  async stopAllTasks(): Promise<void> {
    const tasks = await this.listTasks();
    for (const task of tasks) {
      try {
        await this.stopTask(task.id);
      } catch (error) {
        console.error(`Failed to stop task ${task.id}:`, error);
      }
    }
  }

  /**
   * Read tmux output from a task
   */
  async readOutput(taskId: string, lines: number = 500): Promise<string> {
    const result = await exec(
      `docker exec cmux-${taskId} tmux capture-pane -t main -p -S -${lines} 2>/dev/null`
    );
    return result.stdout;
  }

  /**
   * Inject a message into the Claude Code session
   */
  async injectMessage(taskId: string, message: string): Promise<boolean> {
    const escapedMessage = escapeShell(message);
    const result = await exec(
      `docker exec cmux-${taskId} tmux send-keys -t main "${escapedMessage}" Enter`
    );
    return result.code === 0;
  }

  /**
   * Execute a command in a task container
   */
  async exec(taskId: string, command: string): Promise<{ stdout: string; stderr: string; code: number }> {
    return exec(`docker exec cmux-${taskId} bash -c "${escapeShell(command)}"`);
  }

  /**
   * Open terminal URL in browser
   */
  async openTerminal(taskId: string): Promise<void> {
    const tasks = await this.listTasks();
    const task = tasks.find((t) => t.id === taskId);
    if (!task) {
      throw new Error(`Task ${taskId} not found`);
    }

    const url = `http://localhost:${task.terminalPort}`;

    // Cross-platform open
    const openCmd =
      process.platform === "darwin"
        ? `open "${url}"`
        : process.platform === "win32"
          ? `start "${url}"`
          : `xdg-open "${url}"`;

    await exec(openCmd);
  }
}

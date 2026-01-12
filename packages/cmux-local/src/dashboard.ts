/**
 * Dashboard TUI - Interactive terminal dashboard with arrow key navigation
 */

import * as path from "node:path";
import * as fs from "node:fs";
import * as os from "node:os";
import { spawnSync } from "node:child_process";
import chalk from "chalk";
import { search, input } from "@inquirer/prompts";
import { LocalRunner, DEFAULT_MODEL } from "./local.js";
import { type Task, type Question, type ActivityEntry } from "./types.js";
import { extractCurrentActivity } from "./extractor.js";

// Track MCP questions we've already seen (by their MCP ID)
const mcpQuestionsSeen: Set<string> = new Set();

// Track which questions are MCP-based (so we know to write answers to filesystem)
const mcpQuestionIds: Map<string, { taskId: string; mcpId: string }> = new Map();

// ─────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────

const BOX = {
  topLeft: "╭",
  topRight: "╮",
  bottomLeft: "╰",
  bottomRight: "╯",
  horizontal: "─",
  vertical: "│",
};

// Common directories where developers keep their projects
const PROJECT_DIRS = [
  "~/Projects",
  "~/projects",
  "~/Code",
  "~/code",
  "~/Development",
  "~/development",
  "~/Dev",
  "~/dev",
  "~/repos",
  "~/Repos",
  "~/src",
  "~/work",
  "~/Work",
  "~/github",
  "~/GitHub",
  "~/git",
];

// ─────────────────────────────────────────────────────────────
// State
// ─────────────────────────────────────────────────────────────

const runner = new LocalRunner();
let tasks: Task[] = [];
const questions: Map<string, { question: Question; taskId: string }> = new Map();
const activity: ActivityEntry[] = [];
const taskCurrentActivity: Map<string, string> = new Map();
let questionCounter = 0;
let _isRunning = true;
let recentRepos: string[] = [];
let discoveredRepos: Array<{ path: string; name: string; lastModified: number }> = [];

// Interactive state
let selectedIndex = 0;
let inputMode = false; // True when in inquirer prompts
let viewMode: "dashboard" | "inbox" | "attached" = "dashboard"; // Track current view

// ─────────────────────────────────────────────────────────────
// Utility Functions
// ─────────────────────────────────────────────────────────────

function expandPath(p: string): string {
  if (p.startsWith("~/")) {
    return path.join(os.homedir(), p.slice(2));
  }
  return p;
}

function loadRecentRepos(): void {
  const configPath = path.join(os.homedir(), ".cmux-local", "recent-repos.json");
  try {
    if (fs.existsSync(configPath)) {
      recentRepos = JSON.parse(fs.readFileSync(configPath, "utf-8"));
    }
  } catch {
    recentRepos = [];
  }
}

function saveRecentRepos(): void {
  const configDir = path.join(os.homedir(), ".cmux-local");
  const configPath = path.join(configDir, "recent-repos.json");
  try {
    if (!fs.existsSync(configDir)) {
      fs.mkdirSync(configDir, { recursive: true });
    }
    fs.writeFileSync(configPath, JSON.stringify(recentRepos.slice(0, 20)));
  } catch {
    // Ignore save errors
  }
}

function addRecentRepo(repoPath: string): void {
  const absolute = path.resolve(repoPath);
  recentRepos = [absolute, ...recentRepos.filter((r) => r !== absolute)].slice(0, 20);
  saveRecentRepos();
}

function discoverGitRepos(): Array<{ path: string; name: string; lastModified: number }> {
  const repos: Array<{ path: string; name: string; lastModified: number }> = [];
  const seen = new Set<string>();

  const cwd = process.cwd();
  if (fs.existsSync(path.join(cwd, ".git"))) {
    repos.push({
      path: cwd,
      name: path.basename(cwd),
      lastModified: Date.now(),
    });
    seen.add(cwd);
  }

  for (const repoPath of recentRepos) {
    if (!seen.has(repoPath) && fs.existsSync(repoPath)) {
      try {
        const stat = fs.statSync(repoPath);
        repos.push({
          path: repoPath,
          name: path.basename(repoPath),
          lastModified: stat.mtimeMs,
        });
        seen.add(repoPath);
      } catch {
        // Skip inaccessible paths
      }
    }
  }

  for (const dir of PROJECT_DIRS) {
    const expanded = expandPath(dir);
    if (!fs.existsSync(expanded)) continue;

    try {
      const entries = fs.readdirSync(expanded, { withFileTypes: true });
      for (const entry of entries) {
        if (!entry.isDirectory()) continue;
        if (entry.name.startsWith(".")) continue;

        const fullPath = path.join(expanded, entry.name);
        if (seen.has(fullPath)) continue;

        const gitPath = path.join(fullPath, ".git");
        if (fs.existsSync(gitPath)) {
          try {
            const stat = fs.statSync(fullPath);
            repos.push({
              path: fullPath,
              name: entry.name,
              lastModified: stat.mtimeMs,
            });
            seen.add(fullPath);
          } catch {
            // Skip inaccessible
          }
        }
      }
    } catch {
      // Skip inaccessible directories
    }
  }

  repos.sort((a, b) => b.lastModified - a.lastModified);
  return repos;
}

function formatTimeAgo(timestamp: number): string {
  const seconds = Math.floor((Date.now() - timestamp) / 1000);

  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  if (seconds < 604800) return `${Math.floor(seconds / 86400)}d ago`;
  return `${Math.floor(seconds / 604800)}w ago`;
}

// ─────────────────────────────────────────────────────────────
// Display Functions
// ─────────────────────────────────────────────────────────────

function render(): void {
  // Move to top-left and clear screen
  process.stdout.write("\x1b[H\x1b[J");

  const width = 70;

  console.log();
  console.log(chalk.cyan(`  ${BOX.topLeft}${BOX.horizontal.repeat(width - 2)}${BOX.topRight}`));
  console.log(chalk.cyan(`  ${BOX.vertical} ${chalk.bold("ocmux")} ${chalk.gray("- Orchestrated Claude Multiplexer")}${" ".repeat(width - 43)}${BOX.vertical}`));
  console.log(chalk.cyan(`  ${BOX.bottomLeft}${BOX.horizontal.repeat(width - 2)}${BOX.bottomRight}`));

  // Get running tasks for selection
  const runningTasks = tasks.filter((t) => t.status === "running" || t.status === "starting");
  const completedTasks = tasks.filter((t) => t.status === "done");

  // Clamp selectedIndex
  const maxIndex = runningTasks.length - 1;
  if (selectedIndex > maxIndex) selectedIndex = Math.max(0, maxIndex);
  if (selectedIndex < 0) selectedIndex = 0;

  // In Progress Section (yellow = working)
  console.log(chalk.bold.yellow(`\n  ● In Progress`) + chalk.gray(` (${runningTasks.length})`));
  console.log(chalk.gray("  " + "─".repeat(60)));

  if (runningTasks.length === 0) {
    console.log(chalk.gray("    No tasks in progress. Press 'n' to start a new task."));
  } else {
    runningTasks.forEach((task, idx) => {
      const isSelected = idx === selectedIndex;
      const prefix = isSelected ? chalk.cyan("▶ ") : "  ";
      const highlight = isSelected ? chalk.cyan.bold : chalk.white;
      // Running = yellow/orange, starting = dim yellow
      const icon = task.status === "running" ? chalk.yellow("●") : chalk.yellow.dim("◌");
      const time = task.startedAt.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", hour12: false });
      const currentAct = taskCurrentActivity.get(task.id);

      console.log(
        `  ${prefix}${chalk.gray(task.number.toString().padStart(2))} ${icon} ` +
        highlight(task.repoName.padEnd(15).slice(0, 15)) +
        chalk.gray(` "${task.prompt.slice(0, 25)}${task.prompt.length > 25 ? "..." : ""}" `) +
        chalk.gray(`${time}`)
      );

      if (currentAct) {
        console.log(chalk.gray(`      └─ ${chalk.blue(currentAct)}`));
      }
    });
  }

  // Questions/Inbox Section - always show
  const qCount = questions.size;
  const qLabel = qCount > 0 ? chalk.bold.yellow(`\n  ⚠ Inbox`) : chalk.bold.gray(`\n  ✉ Inbox`);
  console.log(qLabel + chalk.gray(` (${qCount} pending) - press 'i' to view`));
  console.log(chalk.gray("  " + "─".repeat(60)));
  if (qCount === 0) {
    console.log(chalk.gray("    No questions from agents yet"));
  } else {
    const questionList = Array.from(questions.entries()).slice(0, 3);
    for (const [key, { question, taskId }] of questionList) {
      const task = tasks.find((t) => t.id === taskId);
      const preview = question.question.slice(0, 45) + (question.question.length > 45 ? "..." : "");
      console.log(
        chalk.yellow(`    [${key}]`) +
        chalk.gray(` ${task?.repoName || "?"}: `) +
        chalk.white(preview)
      );
    }
  }

  // Completed Section (green = done)
  if (completedTasks.length > 0) {
    console.log(chalk.bold.green(`\n  ✓ Completed`) + chalk.gray(` (${completedTasks.length})`));
    console.log(chalk.gray("  " + "─".repeat(60)));
    for (const task of completedTasks.slice(0, 2)) {
      const time = task.startedAt.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", hour12: false });
      console.log(
        `    ${chalk.gray(task.number.toString().padStart(2))} ${chalk.green("✓")} ${chalk.gray(task.repoName.padEnd(15).slice(0, 15))} ${chalk.gray(`"${task.prompt.slice(0, 25)}..."`)} ${chalk.gray(time)}`
      );
    }
    if (completedTasks.length > 2) {
      console.log(chalk.gray(`    ... and ${completedTasks.length - 2} more`));
    }
  }

  // Help bar
  console.log();
  console.log(chalk.gray("  ─".repeat(30)));
  console.log(
    chalk.gray("  ") +
    chalk.cyan("j/k") + chalk.gray(" nav  ") +
    chalk.cyan("Enter") + chalk.gray(" attach  ") +
    chalk.cyan("n") + chalk.gray(" new  ") +
    chalk.cyan("s") + chalk.gray(" stop  ") +
    chalk.cyan("i") + chalk.gray(" inbox  ") +
    chalk.cyan("q") + chalk.gray(" quit")
  );
}

// ─────────────────────────────────────────────────────────────
// Inbox View
// ─────────────────────────────────────────────────────────────

function showInbox(): void {
  viewMode = "inbox";
  process.stdout.write("\x1b[H\x1b[J");

  console.log();
  console.log(chalk.bold.yellow("  ╭────────────────────────────────────────────────────────────────╮"));
  console.log(chalk.bold.yellow("  │                         INBOX                                  │"));
  console.log(chalk.bold.yellow("  ╰────────────────────────────────────────────────────────────────╯"));
  console.log();

  if (questions.size === 0) {
    console.log(chalk.gray("  No pending questions from agents."));
    console.log();
    console.log(chalk.gray("  Agents can ask questions by writing to their inbox file."));
    console.log(chalk.gray("  Questions will appear here when they need human input."));
  } else {
    for (const [key, { question, taskId }] of questions.entries()) {
      const task = tasks.find((t) => t.id === taskId);
      console.log(chalk.yellow(`  [${key}]`) + chalk.gray(` from ${task?.repoName || "unknown"}`));
      console.log(chalk.white(`      ${question.question}`));
      if (question.options && question.options.length > 0) {
        console.log(chalk.gray("      Options:"));
        for (const opt of question.options) {
          console.log(chalk.cyan(`        • ${opt}`));
        }
      }
      console.log();
    }
  }

  console.log();
  console.log(chalk.gray("  ─".repeat(30)));
  console.log(chalk.gray("  Press any key to return to dashboard"));

  // Wait for any keypress then return to dashboard
  const returnHandler = (): void => {
    process.stdin.removeListener("data", returnHandler);
    viewMode = "dashboard";
    render();
  };
  process.stdin.once("data", returnHandler);
}

// ─────────────────────────────────────────────────────────────
// Task Actions
// ─────────────────────────────────────────────────────────────

function attachToTask(task: Task): void {
  const sessionName = `cmux-${task.id}`;
  spawnSync("tmux", ["attach-session", "-t", sessionName], {
    stdio: "inherit",
  });
}

async function handleNewTask(): Promise<void> {
  inputMode = true;
  // Exit raw mode for inquirer
  if (process.stdin.isTTY) {
    process.stdin.setRawMode(false);
  }

  console.log();
  console.log(chalk.bold.cyan("  ╭─────────────────────────────────────────────────────────────╮"));
  console.log(chalk.bold.cyan("  │                    Start New Task                           │"));
  console.log(chalk.bold.cyan("  ╰─────────────────────────────────────────────────────────────╯"));

  discoveredRepos = discoverGitRepos();

  let selectedRepo: string;

  try {
    const repoChoices = discoveredRepos.map((repo) => {
      const timeAgo = formatTimeAgo(repo.lastModified);
      const isCurrent = repo.path === process.cwd();
      const isRecent = recentRepos.includes(repo.path);

      let prefix = "  ";
      if (isCurrent) prefix = chalk.green("→ ");
      else if (isRecent) prefix = chalk.yellow("★ ");

      return {
        name: `${prefix}${repo.name}`,
        value: repo.path,
        description: `${repo.path} ${chalk.gray(`(${timeAgo})`)}`,
      };
    });

    repoChoices.push({
      name: chalk.gray("  Enter custom path..."),
      value: "__custom__",
      description: "Type a path to a git repository",
    });

    selectedRepo = await search({
      message: "Select project (type to filter):",
      source: async (term) => {
        if (!term) return repoChoices;
        const lower = term.toLowerCase();
        return repoChoices.filter((choice) => {
          const searchable = `${choice.name} ${choice.value}`.toLowerCase();
          return searchable.includes(lower);
        });
      },
    });

    if (selectedRepo === "__custom__") {
      selectedRepo = await input({
        message: "Enter path:",
        default: process.cwd(),
        validate: (value) => {
          const expanded = expandPath(value);
          if (!fs.existsSync(expanded)) return "Path does not exist";
          return true;
        },
      });
      selectedRepo = expandPath(selectedRepo);
    }
  } catch {
    console.log(chalk.yellow("\n  Cancelled."));
    inputMode = false;
    return;
  }

  if (!fs.existsSync(selectedRepo)) {
    console.log(chalk.red(`  Path not found: ${selectedRepo}`));
    inputMode = false;
    return;
  }

  const repoName = path.basename(selectedRepo);
  console.log(chalk.green(`  ✓ Selected: ${repoName}`) + chalk.gray(` (${selectedRepo})`));

  console.log(chalk.bold("\n  Task Description"));
  console.log(chalk.gray("  " + "─".repeat(60)));

  let taskPrompt: string;
  try {
    taskPrompt = await input({
      message: ">",
      validate: (value) => {
        if (!value.trim()) return "Task description is required";
        return true;
      },
    });
  } catch {
    console.log(chalk.yellow("\n  Cancelled."));
    inputMode = false;
    return;
  }

  console.log(chalk.gray("\n  Starting..."));
  try {
    const task = await runner.startTask(selectedRepo, taskPrompt, DEFAULT_MODEL);
    addRecentRepo(selectedRepo);

    activity.unshift({
      timestamp: new Date(),
      taskId: task.id,
      taskName: repoName,
      type: "info",
      message: `Started: "${taskPrompt.slice(0, 30)}..."`,
    });

    console.log(chalk.green(`\n  ✓ Started task #${task.number}`));
    await refreshTasks();
  } catch (err) {
    console.error(chalk.red("  Failed to start task:"), err);
  } finally {
    inputMode = false;
  }
}

// ─────────────────────────────────────────────────────────────
// Polling & Updates
// ─────────────────────────────────────────────────────────────

async function refreshTasks(): Promise<void> {
  try {
    tasks = await runner.listTasks();

    for (const task of tasks) {
      if (task.status === "running" || task.status === "starting") {
        try {
          const output = await runner.readOutput(task.id);
          const currentAct = extractCurrentActivity(output);
          if (currentAct) {
            taskCurrentActivity.set(task.id, currentAct);
          }
        } catch {
          // Container might not be ready
        }

        try {
          const inboxQuestions = runner.readInboxQuestions(task);
          for (const iq of inboxQuestions) {
            if (mcpQuestionsSeen.has(iq.id)) continue;

            if (iq.importance === "low") {
              mcpQuestionsSeen.add(iq.id);
              continue;
            }

            mcpQuestionsSeen.add(iq.id);
            questionCounter++;
            const key = `q${questionCounter}`;

            mcpQuestionIds.set(key, { taskId: task.id, mcpId: iq.id });

            const question: Question = {
              id: iq.id,
              taskId: task.id,
              question: iq.question,
              suggestion: iq.context,
              options: iq.options,
              status: "open",
              askedAt: new Date(iq.timestamp),
            };

            questions.set(key, { question, taskId: task.id });

            activity.unshift({
              timestamp: new Date(),
              taskId: task.id,
              taskName: task.repoName,
              type: "question",
              message: `[${iq.importance.toUpperCase()}] ${iq.question.slice(0, 30)}...`,
            });
          }
        } catch {
          // Inbox files might not exist yet
        }

        while (activity.length > 30) {
          activity.pop();
        }
      }
    }
  } catch (err) {
    console.error(chalk.red("  Error refreshing tasks:"), err);
  }
}

// ─────────────────────────────────────────────────────────────
// Main Entry - Interactive Mode
// ─────────────────────────────────────────────────────────────

export async function runDashboard(): Promise<void> {
  loadRecentRepos();
  discoveredRepos = discoverGitRepos();

  const { ok, missing } = await runner.checkRequirements();
  if (!ok) {
    console.error(chalk.red("\n  Missing requirements:"));
    for (const m of missing) {
      console.error(chalk.red(`    - ${m}`));
    }
    console.error();
    process.exit(1);
  }

  // Initial load
  await refreshTasks();

  // Set up raw mode for interactive input
  if (process.stdin.isTTY) {
    process.stdin.setRawMode(true);
  }
  process.stdin.resume();
  process.stdin.setEncoding("utf8");

  // Initial render
  render();

  // Set up polling - only refresh data, don't render if not on dashboard
  const pollInterval = setInterval(async () => {
    await refreshTasks();
    // Only re-render if we're on the dashboard view
    if (viewMode === "dashboard") {
      render();
    }
  }, 3000);

  // Handle keypresses
  process.stdin.on("data", async (key: string) => {
    // Ignore keypresses during input mode (inquirer is handling input)
    if (inputMode) return;

    const runningTasks = tasks.filter((t) => t.status === "running" || t.status === "starting");

    // Ctrl+C or q to quit
    if (key === "\u0003" || key === "q" || key === "Q") {
      _isRunning = false;
      clearInterval(pollInterval);
      if (process.stdin.isTTY) {
        process.stdin.setRawMode(false);
      }
      console.log(chalk.gray("\n  Goodbye!\n"));
      process.exit(0);
    }

    // Arrow up (various formats)
    if (key === "\u001b[A" || key === "\x1b[A" || key === "\x1bOA") {
      if (selectedIndex > 0) {
        selectedIndex--;
        render();
      }
      return;
    }

    // Arrow down (various formats)
    if (key === "\u001b[B" || key === "\x1b[B" || key === "\x1bOB") {
      if (selectedIndex < runningTasks.length - 1) {
        selectedIndex++;
        render();
      }
      return;
    }

    // j/k vim-style navigation
    if (key === "k" || key === "K") {
      if (selectedIndex > 0) {
        selectedIndex--;
        render();
      }
      return;
    }

    if (key === "j" || key === "J") {
      if (selectedIndex < runningTasks.length - 1) {
        selectedIndex++;
        render();
      }
      return;
    }

    // Enter - attach to selected task
    if (key === "\r" || key === "\n") {
      if (runningTasks.length > 0 && runningTasks[selectedIndex]) {
        const task = runningTasks[selectedIndex];
        // Set viewMode to prevent polling from rendering
        viewMode = "attached";
        // Show hint before attaching
        process.stdout.write("\x1b[H\x1b[J");
        console.log(chalk.cyan("\n  Attaching to task #" + task.number + "...\n"));
        console.log(chalk.gray("  Windows: Ctrl+B, 0 (claude) | Ctrl+B, 1 (diff) | Ctrl+B, 2 (shell)"));
        console.log(chalk.gray("  Detach:  Ctrl+B, D to return to ocmux\n"));
        await new Promise(r => setTimeout(r, 800));

        if (process.stdin.isTTY) {
          process.stdin.setRawMode(false);
        }
        attachToTask(task);
        if (process.stdin.isTTY) {
          process.stdin.setRawMode(true);
        }
        // Reset viewMode when returning to dashboard
        viewMode = "dashboard";
        await refreshTasks();
        render();
      }
      return;
    }

    // n - new task
    if (key === "n" || key === "N") {
      clearInterval(pollInterval);
      await handleNewTask();
      // Re-enable raw mode after inquirer
      if (process.stdin.isTTY) {
        process.stdin.setRawMode(true);
      }
      // Restart polling
      setInterval(async () => {
        await refreshTasks();
        render();
      }, 3000);
      render();
      return;
    }

    // s - stop selected task
    if (key === "s" || key === "S") {
      if (runningTasks.length > 0 && runningTasks[selectedIndex]) {
        const task = runningTasks[selectedIndex];
        await runner.stopTask(task.id);
        await refreshTasks();
        render();
      }
      return;
    }

    // r - refresh
    if (key === "r" || key === "R") {
      await refreshTasks();
      render();
      return;
    }

    // i - view inbox
    if (key === "i" || key === "I") {
      showInbox();
      return;
    }
  });
}

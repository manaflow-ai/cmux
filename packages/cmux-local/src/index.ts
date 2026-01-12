#!/usr/bin/env bun
/**
 * CMUX Local - Local Claude Code Orchestrator
 *
 * A CLI for managing Claude Code sessions in local Docker containers.
 *
 * Usage:
 *   cmux-local              Start interactive mode
 *   cmux-local start <path> "<prompt>"   Start a new task
 *   cmux-local list         List all tasks
 *   cmux-local --help       Show help
 */

import * as readline from "node:readline";
import * as path from "node:path";
import * as fs from "node:fs";
import { config } from "dotenv";
import chalk from "chalk";

// Load .env from multiple possible locations
const envPaths = [
  path.join(process.cwd(), ".env"),
  path.join(process.cwd(), "..", "..", ".env"), // cmux root from packages/cmux-local
  path.resolve(__dirname, "..", "..", "..", ".env"), // cmux root from src
  path.join(process.env.HOME || "", ".env"),
];

for (const envPath of envPaths) {
  if (fs.existsSync(envPath)) {
    config({ path: envPath });
    break;
  }
}
import { LocalRunner, DEFAULT_MODEL } from "./local.js";
import { type Task, type Question, type ActivityEntry } from "./types.js";
import { extractQuestionsFromOutput } from "./extractor.js";
import { runDashboard } from "./dashboard.js";

// ─────────────────────────────────────────────────────────────
// State
// ─────────────────────────────────────────────────────────────

const runner = new LocalRunner();
let tasks: Task[] = [];
const questions: Map<string, { question: Question; taskId: string }> = new Map();
const activity: ActivityEntry[] = [];
let questionCounter = 0;
const _isRunning = true;

// ─────────────────────────────────────────────────────────────
// Display Functions
// ─────────────────────────────────────────────────────────────

function _clearScreen(): void {
  process.stdout.write("\x1b[2J\x1b[H");
}

function _printHeader(): void {
  console.log(chalk.bold.cyan("\n  CMUX Local") + chalk.gray(" - Local Claude Code Orchestrator"));
  console.log(chalk.gray("  " + "─".repeat(55)));
}

function getStatusIcon(status: Task["status"]): string {
  switch (status) {
    case "starting":
      return chalk.yellow("◌");
    case "running":
      return chalk.green("●");
    case "question":
      return chalk.yellow("◐");
    case "done":
      return chalk.gray("○");
    case "error":
      return chalk.red("✗");
    default:
      return chalk.gray("?");
  }
}

function printTasks(): void {
  console.log(chalk.bold("\n  Tasks") + chalk.gray(` (${tasks.length})`));
  console.log(chalk.gray("  " + "─".repeat(55)));

  if (tasks.length === 0) {
    console.log(chalk.gray("  No tasks running. Use 'new' to start one."));
    return;
  }

  for (const task of tasks) {
    const icon = getStatusIcon(task.status);
    const hasQuestions = Array.from(questions.values()).some((q) => q.taskId === task.id);
    const questionBadge = hasQuestions ? chalk.yellow(" [?]") : "";

    console.log(
      `  ${chalk.gray(task.number.toString().padStart(2))} ${icon} ` +
        `${chalk.white(task.repoName.padEnd(14).slice(0, 14))} ` +
        `${chalk.gray('"' + task.prompt.slice(0, 28) + (task.prompt.length > 28 ? "..." : "") + '"')} ` +
        `${chalk.cyan(":" + task.terminalPort)}${questionBadge}`
    );
  }
}

function printQuestions(): void {
  const openQuestions = Array.from(questions.entries());

  console.log(chalk.bold.yellow("\n  Questions") + chalk.gray(` (${openQuestions.length})`));
  console.log(chalk.gray("  " + "─".repeat(55)));

  if (openQuestions.length === 0) {
    console.log(chalk.gray("  No pending questions."));
    return;
  }

  for (const [key, { question, taskId }] of openQuestions) {
    const task = tasks.find((t) => t.id === taskId);
    const taskName = task?.repoName || taskId.slice(0, 8);

    console.log(chalk.cyan(`  [${key}]`) + chalk.gray(` ${taskName}:`));
    console.log(chalk.white(`       "${question.question}"`));
    if (question.suggestion) {
      console.log(chalk.blue(`       → ${question.suggestion}`));
    }
  }
}

function printActivity(): void {
  const recent = activity.slice(0, 5);

  console.log(chalk.bold("\n  Activity"));
  console.log(chalk.gray("  " + "─".repeat(55)));

  if (recent.length === 0) {
    console.log(chalk.gray("  No activity yet."));
    return;
  }

  for (const entry of recent) {
    const time = entry.timestamp.toLocaleTimeString("en-US", {
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    });
    const color =
      entry.type === "question"
        ? chalk.yellow
        : entry.type === "error"
          ? chalk.red
          : chalk.gray;

    console.log(
      chalk.gray(`  ${time} `) +
        chalk.cyan(`${entry.taskName.slice(0, 10).padEnd(10)} `) +
        color(entry.message.slice(0, 40) + (entry.message.length > 40 ? "..." : ""))
    );
  }
}

function printHelp(): void {
  console.log(chalk.bold("\n  Commands:"));
  console.log(`  ${chalk.cyan("new")}                    Start a new task (prompts for repo + task)`);
  console.log(`  ${chalk.cyan("start <path> <prompt>")} Start task with explicit path and prompt`);
  console.log(`  ${chalk.cyan("list")} or ${chalk.cyan("ls")}            Refresh and show all tasks`);
  console.log(`  ${chalk.cyan("open <n>")}              Open terminal for task n in browser`);
  console.log(`  ${chalk.cyan("q<n> <answer>")}         Answer question n (e.g., q1 use JWT)`);
  console.log(`  ${chalk.cyan("tell <n> <message>")}    Send message to task n`);
  console.log(`  ${chalk.cyan("stop <n>")}              Stop task n`);
  console.log(`  ${chalk.cyan("stop-all")}              Stop all tasks`);
  console.log(`  ${chalk.cyan("help")}                  Show this help`);
  console.log(`  ${chalk.cyan("quit")} or ${chalk.cyan("q")}            Exit`);
}

function printStatus(): void {
  printTasks();
  printQuestions();
  printActivity();
  console.log();
}

// ─────────────────────────────────────────────────────────────
// Polling & Updates
// ─────────────────────────────────────────────────────────────

async function refreshTasks(): Promise<void> {
  try {
    tasks = await runner.listTasks();

    // Read output from each running task
    for (const task of tasks) {
      if (task.status === "running" || task.status === "starting") {
        try {
          const output = await runner.readOutput(task.id);
          const extracted = extractQuestionsFromOutput(output, task.id);

          // Add new questions
          for (const q of extracted.questions) {
            const existingKeys = Array.from(questions.keys());
            const alreadyExists = existingKeys.some((k) => {
              const existing = questions.get(k);
              return existing?.question.question === q.question;
            });

            if (!alreadyExists) {
              questionCounter++;
              const key = `q${questionCounter}`;
              questions.set(key, { question: q, taskId: task.id });

              activity.unshift({
                timestamp: new Date(),
                taskId: task.id,
                taskName: task.repoName,
                type: "question",
                message: q.question.slice(0, 50),
              });

              console.log(chalk.yellow(`\n  [${key}] New question from ${task.repoName}:`));
              console.log(chalk.white(`       "${q.question}"`));
              if (q.suggestion) {
                console.log(chalk.blue(`       → ${q.suggestion}`));
              }
              console.log(chalk.gray(`       Reply: ${key} <your answer>\n`));
            }
          }
        } catch {
          // Container might not be ready
        }
      }
    }
  } catch (err) {
    console.error(chalk.red("  Error refreshing tasks:"), err);
  }
}

// ─────────────────────────────────────────────────────────────
// Command Handlers
// ─────────────────────────────────────────────────────────────

async function handleNew(rl: readline.Interface): Promise<void> {
  return new Promise((resolve) => {
    rl.question(chalk.cyan("  Repo path: ") + chalk.gray(`(${process.cwd()}) `), (repoInput) => {
      const repoPath = repoInput.trim() || process.cwd();

      rl.question(chalk.cyan("  Task description: "), async (prompt) => {
        if (!prompt.trim()) {
          console.log(chalk.red("  Task description is required."));
          resolve();
          return;
        }

        try {
          console.log(chalk.gray("  Starting task..."));
          const task = await runner.startTask(repoPath, prompt.trim());

          activity.unshift({
            timestamp: new Date(),
            taskId: task.id,
            taskName: task.repoName,
            type: "info",
            message: `Started: "${prompt.slice(0, 30)}..."`,
          });

          console.log(chalk.green(`  ✓ Started task #${task.number} (${task.id})`));
          console.log(chalk.gray(`    Terminal: `) + chalk.cyan(`http://localhost:${task.terminalPort}`));

          await refreshTasks();
        } catch (err) {
          console.error(chalk.red("  Failed to start task:"), err);
        }

        resolve();
      });
    });
  });
}

async function _handleCommand(input: string, rl: readline.Interface): Promise<void> {
  const parts = input.trim().split(/\s+/);
  const command = parts[0]?.toLowerCase();

  if (!command) return;

  switch (command) {
    case "new":
    case "n":
      await handleNew(rl);
      break;

    case "start": {
      const repoPath = parts[1];
      const prompt = parts.slice(2).join(" ");

      if (!repoPath || !prompt) {
        console.log(chalk.red("  Usage: start <repo-path> <prompt>"));
        break;
      }

      try {
        console.log(chalk.gray("  Starting task..."));
        const task = await runner.startTask(repoPath, prompt);
        console.log(chalk.green(`  ✓ Started task #${task.number}`));
        console.log(chalk.gray(`    Terminal: `) + chalk.cyan(`http://localhost:${task.terminalPort}`));
        await refreshTasks();
      } catch (err) {
        console.error(chalk.red("  Failed:"), err);
      }
      break;
    }

    case "list":
    case "ls":
    case "status":
    case "s":
      await refreshTasks();
      printStatus();
      break;

    case "open":
    case "o": {
      const taskNum = parseInt(parts[1] || "", 10);
      const task = tasks.find((t) => t.number === taskNum);

      if (!task) {
        console.log(chalk.red(`  Task ${taskNum} not found.`));
        break;
      }

      try {
        await runner.openTerminal(task.id);
        console.log(chalk.green(`  Opened http://localhost:${task.terminalPort}`));
      } catch (err) {
        console.error(chalk.red("  Failed to open:"), err);
      }
      break;
    }

    case "stop": {
      const taskNum = parseInt(parts[1] || "", 10);
      const task = tasks.find((t) => t.number === taskNum);

      if (!task) {
        console.log(chalk.red(`  Task ${taskNum} not found.`));
        break;
      }

      try {
        await runner.stopTask(task.id);
        console.log(chalk.green(`  Stopped task #${taskNum}`));
        await refreshTasks();
      } catch (err) {
        console.error(chalk.red("  Failed:"), err);
      }
      break;
    }

    case "stop-all": {
      try {
        await runner.stopAllTasks();
        console.log(chalk.green("  Stopped all tasks."));
        await refreshTasks();
      } catch (err) {
        console.error(chalk.red("  Failed:"), err);
      }
      break;
    }

    case "tell": {
      const taskNum = parseInt(parts[1] || "", 10);
      const message = parts.slice(2).join(" ");
      const task = tasks.find((t) => t.number === taskNum);

      if (!task || !message) {
        console.log(chalk.red("  Usage: tell <task-number> <message>"));
        break;
      }

      const success = await runner.injectMessage(task.id, message);
      console.log(success ? chalk.green("  Sent.") : chalk.red("  Failed."));
      break;
    }

    case "help":
    case "h":
    case "?":
      printHelp();
      break;

    case "quit":
    case "exit":
    case "q":
      // This function is now unused, using dashboard TUI instead
      break;

    default: {
      // Check if answering a question (q1, q2, etc.)
      if (/^q\d+$/.test(command)) {
        const answer = parts.slice(1).join(" ");
        if (!answer) {
          console.log(chalk.red(`  Usage: ${command} <answer>`));
          break;
        }

        const entry = questions.get(command);
        if (!entry) {
          console.log(chalk.red(`  Question ${command} not found.`));
          break;
        }

        const task = tasks.find((t) => t.id === entry.taskId);
        if (!task) {
          console.log(chalk.red("  Task not found."));
          break;
        }

        const success = await runner.injectMessage(task.id, answer);
        if (success) {
          questions.delete(command);
          activity.unshift({
            timestamp: new Date(),
            taskId: task.id,
            taskName: task.repoName,
            type: "info",
            message: `Answered: "${answer.slice(0, 30)}..."`,
          });
          console.log(chalk.green("  Answer sent."));
        } else {
          console.log(chalk.red("  Failed to send answer."));
        }
        break;
      }

      console.log(chalk.red(`  Unknown command: ${command}. Type 'help' for commands.`));
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const args = process.argv.slice(2);

  // Handle --help
  if (args.includes("--help") || args.includes("-h")) {
    console.log(`
${chalk.bold.cyan("CMUX Local")} - Local Claude Code Orchestrator

${chalk.bold("USAGE:")}
  cmux-local                       Start interactive mode
  cmux-local "<prompt>"            Start task in current directory
  cmux-local list                  List running tasks
  cmux-local stop-all              Stop all tasks
  cmux-local --help                Show this help

${chalk.bold("INTERACTIVE COMMANDS:")}
  new                     Start new task (prompts for repo + task)
  start . <prompt>        Start task in current directory
  list                    Show all tasks and questions
  open <n>                Attach to terminal for task n
  q<n> <answer>           Answer question n
  tell <n> <message>      Send message to task n
  stop <n>                Stop task n
  stop-all                Stop all tasks
  quit                    Exit

${chalk.bold("REQUIREMENTS:")}
  - tmux (brew install tmux)
  - claude CLI (npm i -g @anthropic-ai/claude-code)
  - CLAUDE_CODE_OAUTH_TOKEN environment variable

${chalk.bold("QUICK START:")}
  # Start a task in your project
  cd ~/myproject
  cmux-local "Add dark mode toggle"

  # Or interactive mode
  cmux-local

${chalk.bold("MODEL:")}
  Default: ${DEFAULT_MODEL} (Opus 4.5)
  Override with: cmux-local "prompt" --model claude-sonnet-4-20250514
`);
    process.exit(0);
  }

  // Check requirements
  const { ok, missing } = await runner.checkRequirements();
  if (!ok) {
    console.error(chalk.red("\n  Missing requirements:"));
    for (const m of missing) {
      console.error(chalk.red(`    - ${m}`));
    }
    console.error();
    process.exit(1);
  }

  // Handle direct task start: cmux-local "prompt" [--model <model>]
  if (args.length > 0 && !["list", "ls", "stop-all", "start"].includes(args[0])) {
    // Parse --model flag
    let model: string | undefined;
    const modelIndex = args.indexOf("--model");
    if (modelIndex !== -1 && args[modelIndex + 1]) {
      model = args[modelIndex + 1];
      args.splice(modelIndex, 2); // Remove --model and its value
    }

    const prompt = args.join(" ");
    const repoPath = process.cwd();

    const actualModel = model || DEFAULT_MODEL;
    console.log(chalk.gray(`\n  Starting task in ${repoPath}...`));
    console.log(chalk.gray(`  Using model: ${actualModel}`));

    try {
      const task = await runner.startTask(repoPath, prompt, actualModel);
      console.log(chalk.green(`\n  ✓ Started task #${task.number} (${task.id})`));
      console.log(chalk.gray(`    Attach to session: `) + chalk.cyan(`tmux attach -t cmux-${task.id}`));
      console.log(chalk.gray(`\n  Run 'cmux-local' to monitor and answer questions.\n`));
    } catch (err) {
      console.error(chalk.red("  Failed:"), err);
      process.exit(1);
    }
    process.exit(0);
  }

  // Handle list
  if (args[0] === "list" || args[0] === "ls") {
    tasks = await runner.listTasks();
    printTasks();
    process.exit(0);
  }

  // Handle stop-all
  if (args[0] === "stop-all") {
    try {
      await runner.stopAllTasks();
      console.log(chalk.green("  Stopped all tasks."));
    } catch (err) {
      console.error(chalk.red("  Failed:"), err);
      process.exit(1);
    }
    process.exit(0);
  }

  // Interactive mode - use new dashboard TUI
  await runDashboard();
}

main().catch((err) => {
  console.error(chalk.red("Fatal error:"), err);
  process.exit(1);
});

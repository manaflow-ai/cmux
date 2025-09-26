import type { ClientToServerEvents, ServerToClientEvents } from "@cmux/shared";
import * as http from "http";
import { execFile, execSync } from "node:child_process";
import { Server } from "socket.io";
import { io, Socket } from "socket.io-client";
import * as vscode from "vscode";

// Create output channel for cmux logs
const outputChannel = vscode.window.createOutputChannel("cmux");
const debugShowOutput = process.env.CMUX_DEBUG_SHOW_OUTPUT === "1";

// Log immediately when module loads
console.log("[cmux] Extension module loaded");

// Socket.IO server instance
let ioServer: Server | null = null;
let httpServer: http.Server | null = null;
let workerSocket: Socket<ServerToClientEvents, ClientToServerEvents> | null =
  null;

// Track active terminals
const activeTerminals = new Map<string, vscode.Terminal>();
let isSetupComplete = false;

// Track file watcher and debounce timer
let fileWatcher: vscode.FileSystemWatcher | null = null;
let refreshDebounceTimer: NodeJS.Timeout | null = null;

function log(message: string, ...args: unknown[]) {
  const safeStringify = (value: unknown): string => {
    if (value instanceof Error) {
      return `${value.name}: ${value.message}`;
    }
    if (typeof value === "object" && value !== null) {
      try {
        return JSON.stringify(value, null, 2);
      } catch {
        return String(value);
      }
    }
    return String(value);
  };
  const timestamp = new Date().toISOString();
  const formattedMessage = `[${timestamp}] ${message}`;
  if (args.length > 0) {
    outputChannel.appendLine(
      formattedMessage + " " + args.map((arg) => safeStringify(arg)).join(" ")
    );
  } else {
    outputChannel.appendLine(formattedMessage);
  }
}

async function resolveDefaultBaseRef(repositoryPath: string): Promise<string> {
  try {
    const out = execSync(
      "git symbolic-ref --quiet refs/remotes/origin/HEAD || git remote show origin | sed -n 's/\tHEAD branch: //p'",
      { cwd: repositoryPath, encoding: "utf8" }
    );
    const ref = out.trim();
    if (ref.startsWith("refs/remotes/origin/")) {
      return ref; // e.g. refs/remotes/origin/main
    }
    if (ref) {
      return `origin/${ref}`;
    }
  } catch {
    // ignore and fall back
  }
  return "origin/main";
}

async function hasTmuxSessions(): Promise<boolean> {
  return new Promise((resolve) => {
    try {
      execFile("tmux", ["list-sessions"], (error, stdout) => {
        if (error) {
          // tmux not installed or no server/sessions
          resolve(false);
          return;
        }
        resolve(stdout.trim().length > 0);
      });
    } catch {
      resolve(false);
    }
  });
}

function tryExecGit(repoPath: string, cmd: string): string | null {
  try {
    const out = execSync(cmd, { cwd: repoPath, encoding: "utf8" });
    return out.trim();
  } catch {
    return null;
  }
}

async function resolveMergeBase(
  repositoryPath: string,
  defaultBaseRef: string
): Promise<string | null> {
  const hasBase = tryExecGit(
    repositoryPath,
    `git rev-parse --verify --quiet "${defaultBaseRef}^{}"`
  );
  if (!hasBase) {
    // Best-effort fetch to get remote refs; ignore failures
    tryExecGit(repositoryPath, "git fetch --quiet origin --prune");
  }
  const mergeBase = tryExecGit(
    repositoryPath,
    `git merge-base HEAD "${defaultBaseRef}"`
  );
  return mergeBase && /^[0-9a-f]{7,40}$/i.test(mergeBase) ? mergeBase : null;
}

// Track the current multi-diff editor URI
let _currentMultiDiffUri: string | null = null;

type OpenMultiDiffOptions = {
  preserveFocus?: boolean;
  suppressNotifications?: boolean;
};

async function openMultiDiffEditor(
  baseRef?: string,
  useMergeBase: boolean = true,
  options: OpenMultiDiffOptions = {}
) {
  log("=== openMultiDiffEditor called ===");
  log("baseRef:", baseRef);
  log("useMergeBase:", useMergeBase);
  log("options:", options);

  const { preserveFocus = false, suppressNotifications = false } = options;

  const previousActiveTextEditor = preserveFocus
    ? vscode.window.activeTextEditor ?? null
    : null;
  const previousActiveTerminal = preserveFocus
    ? vscode.window.activeTerminal ?? null
    : null;
  const previousActiveTab = preserveFocus
    ? vscode.window.tabGroups.activeTabGroup?.activeTab ?? null
    : null;

  // Get the Git extension
  const gitExtension = vscode.extensions.getExtension("vscode.git");
  if (!gitExtension) {
    vscode.window.showErrorMessage("Git extension not found");
    return;
  }

  const git = gitExtension.exports;
  const api = git.getAPI(1);

  // Get the first repository (or you can select a specific one)
  const repository = api.repositories[0];
  if (!repository) {
    vscode.window.showErrorMessage("No Git repository found");
    return;
  }

  const repoPath = repository.rootUri.fsPath;
  log("Repository path:", repoPath);

  const resolvedDefaultBase =
    baseRef || (await resolveDefaultBaseRef(repoPath));
  log("Resolved default base:", resolvedDefaultBase);

  const resolvedMergeBase = useMergeBase
    ? await resolveMergeBase(repoPath, resolvedDefaultBase)
    : null;
  log("Resolved merge base:", resolvedMergeBase);

  const effectiveBase = resolvedMergeBase || resolvedDefaultBase;
  log("Effective base:", effectiveBase);

  // Get all changed files between base and current working tree
  try {
    // Get ALL changes - use git diff to compare base with working tree
    const cmd = `git diff --name-only ${effectiveBase}`;
    log("Running git diff command:", cmd);
    const diffOutput = execSync(cmd, { cwd: repoPath, encoding: "utf8" });
    log("Git diff output:", diffOutput);

    const files = diffOutput
      .trim()
      .split("\n")
      .filter((f) => f);
    log("Changed files:", files);

    // Always create resources - even if empty, still open the view
    const resources =
      files.length > 0
        ? files.map((file) => {
            const fileUri = vscode.Uri.file(`${repoPath}/${file}`);
            const baseUri = api.toGitUri(fileUri, effectiveBase);

            // Match the exact structure used by VS Code's git extension
            return {
              originalUri: baseUri,
              modifiedUri: fileUri,
            };
          })
        : [];

    log(
      "Resources for multi-diff:",
      resources.map((r) => ({
        originalUri: r.originalUri.toString(),
        modifiedUri: r.modifiedUri.toString(),
      }))
    );

    // Extract base branch name for title (e.g., "main" from "origin/main" or "refs/remotes/origin/main")
    const baseBranchName = resolvedDefaultBase
      .replace(/^refs\/remotes\//, "")
      .replace(/^origin\//, "");

    const title = `All Changes vs ${baseBranchName}`;

    // Create a consistent multiDiffSourceUri that will reuse the same editor
    // Using a fixed scheme and path ensures VS Code reuses the existing tab
    const multiDiffSourceUri = vscode.Uri.from({
      scheme: "cmux-all-changes",
      path: `${repoPath}/all-changes-vs-base`,
    });

    // Check if we have an existing multi-diff editor open
    const multiDiffUriString = multiDiffSourceUri.toString();
    const tabs = vscode.window.tabGroups.all.flatMap((g) => g.tabs);
    const existingTab = tabs.find(
      (tab) => tab.label && tab.label.includes("All Changes vs")
    );

    if (existingTab && !preserveFocus) {
      // Try to activate the existing tab first to preserve position
      // This helps maintain scroll position and user context
      const tabGroup = vscode.window.tabGroups.all.find((g) =>
        g.tabs.includes(existingTab)
      );
      if (tabGroup) {
        // Make sure the tab is active before updating
        await vscode.commands.executeCommand(
          "workbench.action.focusActiveEditorGroup"
        );
      }
    }

    // Store the current URI
    _currentMultiDiffUri = multiDiffUriString;

    // Execute the command - VS Code will try to update the existing view if possible
    // The multiDiffSourceUri acts as the key - same URI should update the same editor
    await vscode.commands.executeCommand("_workbench.openMultiDiffEditor", {
      multiDiffSourceUri,
      title,
      resources,
    });

    if (preserveFocus) {
      try {
        // Restore terminal focus if it changed
        if (
          previousActiveTerminal &&
          vscode.window.terminals.includes(previousActiveTerminal) &&
          vscode.window.activeTerminal !== previousActiveTerminal
        ) {
          previousActiveTerminal.show();
        } else if (
          previousActiveTextEditor &&
          !previousActiveTextEditor.document.isClosed
        ) {
          const activeEditor = vscode.window.activeTextEditor;
          const sameDocument =
            activeEditor &&
            activeEditor.document.uri.toString() ===
              previousActiveTextEditor.document.uri.toString();

          if (!sameDocument) {
            await vscode.window.showTextDocument(
              previousActiveTextEditor.document,
              {
                viewColumn: previousActiveTextEditor.viewColumn,
                preserveFocus: false,
              }
            );
          }
        } else if (
          previousActiveTab &&
          vscode.window.tabGroups.activeTabGroup?.activeTab !==
            previousActiveTab
        ) {
          const tabGroupsWithOpen =
            vscode.window.tabGroups as unknown as {
              openTab?: (
                tab: vscode.Tab,
                options?: { preserveFocus?: boolean }
              ) => Thenable<void>;
            };

          if (typeof tabGroupsWithOpen.openTab === "function") {
            await tabGroupsWithOpen.openTab(previousActiveTab, {
              preserveFocus: false,
            });
          }
        }
      } catch (error) {
        log("Failed to restore focus after multi diff refresh", error);
      }
    }

    log("Multi-diff editor opened successfully");
    if (files.length > 0 && !suppressNotifications) {
      vscode.window.showInformationMessage(
        `Showing ${files.length} file(s) changed vs ${baseBranchName}`
      );
    }
  } catch (error: unknown) {
    log("Error opening diff:", error);
    if (error instanceof Error) {
      log("Error stack:", error.stack);
      vscode.window.showErrorMessage(
        `Failed to open changes: ${error.message}`
      );
    } else {
      vscode.window.showErrorMessage("Failed to open changes");
    }
  }
}

async function setupDefaultTerminal() {
  log("Setting up default terminal");

  // Prevent duplicate setup
  if (isSetupComplete) {
    log("Setup already complete, skipping");
    return;
  }

  // If no tmux sessions exist, skip any UI/terminal work entirely
  const hasSessions = await hasTmuxSessions();
  if (!hasSessions) {
    log("No tmux sessions found; skipping terminal setup and attach");
    return;
  }

  // if an existing editor is called "bash", early return
  const activeEditors = vscode.window.visibleTextEditors;
  for (const editor of activeEditors) {
    if (editor.document.fileName === "bash") {
      log("Bash editor already exists, skipping terminal setup");
      return;
    }
  }

  isSetupComplete = true; // Set this BEFORE creating UI elements to prevent race conditions

  // Open Source Control view
  log("Opening SCM view...");
  await vscode.commands.executeCommand("workbench.view.scm");

  // Open git changes view
  log("Opening git changes view...");
  await openMultiDiffEditor();

  // Create terminal for default tmux session
  log("Creating terminal for default tmux session");

  const terminal = vscode.window.createTerminal({
    name: `Default Session`,
    location: vscode.TerminalLocation.Editor,
    cwd: "/root/workspace",
    env: process.env,
  });

  terminal.show();

  // Store terminal reference
  activeTerminals.set("default", terminal);

  // Attach to default tmux session with a small delay to ensure it's ready
  setTimeout(() => {
    terminal.sendText(`tmux attach`);
    log("Attached to default tmux session");
  }, 500); // 500ms delay to ensure tmux session is ready

  log("Created terminal successfully");

  // After terminal is created, ensure the terminal is active and move to right group
  setTimeout(async () => {
    // Focus on the terminal tab
    terminal.show();

    // Move the active editor (terminal) to the right group
    log("Moving terminal editor to right group");
    await vscode.commands.executeCommand(
      "workbench.action.moveEditorToRightGroup"
    );

    // Ensure terminal has focus
    // await vscode.commands.executeCommand("workbench.action.terminal.focus");

    log("Terminal setup complete");
  }, 100);
}

function connectToWorker() {
  if (workerSocket && workerSocket.connected) {
    log("Worker socket already connected");
    return;
  }

  log("Creating worker socket connection...");

  // Clean up existing socket if any
  if (workerSocket) {
    workerSocket.removeAllListeners();
    workerSocket.disconnect();
  }

  workerSocket = io("http://localhost:39377/vscode", {
    reconnection: true,
    reconnectionAttempts: 5,
    reconnectionDelay: 1000,
  }) as Socket<ServerToClientEvents, ClientToServerEvents>;

  // Set up event handlers only once
  workerSocket.once("connect", () => {
    log("Connected to worker socket server");
    // Setup default terminal on first connection
    if (!isSetupComplete) {
      log("Setting up default terminal...");
      setupDefaultTerminal();
    }
  });

  workerSocket.on("disconnect", () => {
    log("Disconnected from worker socket server");
  });

  workerSocket.on("connect_error", (error) => {
    log("Worker socket error:", error);
  });

  // Handle reconnection without duplicating setup
  workerSocket.io.on("reconnect", () => {
    log("Reconnected to worker socket server");
  });
}

function startSocketServer() {
  try {
    const port = 39376;
    httpServer = http.createServer();
    ioServer = new Server(httpServer, {
      cors: {
        origin: "*",
        methods: ["GET", "POST"],
      },
    });

    ioServer.on("connection", (socket) => {
      log("Socket client connected:", socket.id);

      // Health check
      socket.on("vscode:ping", (callback) => {
        log("Received ping from client");
        callback({ timestamp: Date.now() });
        socket.emit("vscode:pong");
      });

      // Get status
      socket.on("vscode:get-status", (callback) => {
        const workspaceFolders =
          vscode.workspace.workspaceFolders?.map((f) => f.uri.fsPath) || [];
        const extensions = vscode.extensions.all.map((e) => e.id);

        callback({
          ready: true,
          workspaceFolders,
          extensions,
        });
      });

      // Terminal operations
      socket.on("vscode:create-terminal", (data, callback) => {
        try {
          const { name = "Terminal", command } = data;
          const terminal = vscode.window.createTerminal({
            name,
            location: vscode.TerminalLocation.Panel,
          });
          terminal.show();
          if (command) {
            terminal.sendText(command);
          }
          callback({ success: true });
        } catch (error: unknown) {
          if (error instanceof Error) {
            callback({ success: false, error: error.message });
          } else {
            callback({ success: false, error: "Unknown error" });
          }
        }
      });

      socket.on("disconnect", () => {
        log("Socket client disconnected:", socket.id);
      });
    });

    httpServer.listen(port, () => {
      log(`Socket.IO server listening on port ${port}`);
    });
  } catch (error) {
    log("Failed to start Socket.IO server:", error);
  }
}

export function activate(context: vscode.ExtensionContext) {
  // Log activation
  console.log("[cmux] activate() called");
  log("[cmux] activate() called");

  // Register command to show output
  const showOutputCommand = vscode.commands.registerCommand(
    "cmux.showOutput",
    () => {
      outputChannel.show();
    }
  );
  context.subscriptions.push(showOutputCommand);

  // Log activation without showing output channel
  outputChannel.appendLine("=== cmux Extension Activating ===");

  log("[cmux] Extension activated, output channel ready");

  // In dev runs, optionally show output for visibility
  if (debugShowOutput) {
    outputChannel.show(true);
  } else {
    // Otherwise keep the panel closed for a cleaner UX
    vscode.commands.executeCommand("workbench.action.closePanel");
  }

  log("cmux is being activated");

  // Start Socket.IO server
  startSocketServer();

  // Connect to worker immediately and set up handlers
  connectToWorker();

  const disposable = vscode.commands.registerCommand(
    "cmux.helloWorld",
    async () => {
      log("Hello World from cmux!");
      vscode.window.showInformationMessage("Hello World from cmux!");
    }
  );

  const run = vscode.commands.registerCommand("cmux.run", async () => {
    // Force setup default terminal
    if (workerSocket && workerSocket.connected) {
      log("Manually setting up default terminal...");
      isSetupComplete = false; // Allow setup to run again
      setupDefaultTerminal();
    } else {
      connectToWorker();
    }
  });

  // Open all changes vs default base (origin/HEAD or origin/main)
  const openAllChangesVsBase = vscode.commands.registerCommand(
    "cmux.git.openAllChangesAgainstBase",
    async () => {
      await openMultiDiffEditor(undefined, true);

      // Set up file watcher for auto-refresh if not already set up
      if (!fileWatcher && vscode.workspace.workspaceFolders) {
        const gitExtension = vscode.extensions.getExtension("vscode.git");
        if (gitExtension) {
          const git = gitExtension.exports;
          const api = git.getAPI(1);
          const repository = api.repositories[0];

          if (repository) {
            const repoPath = repository.rootUri.fsPath;
            log("Setting up file watcher for auto-refresh");

            // Watch all files in the repository
            const pattern = new vscode.RelativePattern(repoPath, "**/*");
            fileWatcher = vscode.workspace.createFileSystemWatcher(pattern);

            // Debounced refresh function
            const refreshDiffView = () => {
              // Clear existing timer
              if (refreshDebounceTimer) {
                clearTimeout(refreshDebounceTimer);
              }

              // Set new timer to refresh after 500ms of no changes
              refreshDebounceTimer = setTimeout(async () => {
                log("Auto-refreshing diff view due to file changes");
                await openMultiDiffEditor(undefined, true, {
                  preserveFocus: true,
                  suppressNotifications: true,
                });
              }, 500);
            };

            // Watch for file changes
            fileWatcher.onDidChange(refreshDiffView);
            fileWatcher.onDidCreate(refreshDiffView);
            fileWatcher.onDidDelete(refreshDiffView);

            // Clean up watcher on disposal
            context.subscriptions.push(fileWatcher);
          }
        }
      }
    }
  );

  context.subscriptions.push(disposable);
  context.subscriptions.push(run);
  context.subscriptions.push(openAllChangesVsBase);
}

export function deactivate() {
  log("cmux extension is now deactivated!");
  isSetupComplete = false;

  // Clean up file watcher and timer
  if (fileWatcher) {
    fileWatcher.dispose();
    fileWatcher = null;
  }
  if (refreshDebounceTimer) {
    clearTimeout(refreshDebounceTimer);
    refreshDebounceTimer = null;
  }

  // Clean up worker socket
  if (workerSocket) {
    workerSocket.removeAllListeners();
    workerSocket.disconnect();
    workerSocket = null;
  }

  // Clean up Socket.IO server
  if (ioServer) {
    ioServer.close();
    ioServer = null;
  }
  if (httpServer) {
    httpServer.close();
    httpServer = null;
  }

  // Clean up terminals
  activeTerminals.forEach((terminal) => terminal.dispose());
  activeTerminals.clear();

  outputChannel.dispose();
}

import { promises as fs } from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

/**
 * Interface for a parsed Claude JSONL message
 */
interface ClaudeMessage {
  type: "user" | "assistant" | "system";
  timestamp?: string;
  content?: string;
  hasToolUse?: boolean;
  [key: string]: unknown;
}

/**
 * Get the Claude project directory path for a given working directory
 * @param workingDir The working directory path (e.g., "/root/workspace")
 * @returns The Claude project directory path
 */
export function getClaudeProjectPath(workingDir: string): string {
  const homeDir = os.homedir();
  // Claude stores project files in ~/.claude/projects/{encoded-path}/
  // Replace forward slashes with hyphens to encode the path
  const encodedPath = workingDir.replace(/\//g, "-");
  return path.join(homeDir, ".claude", "projects", encodedPath);
}

/**
 * Get the most recent JSONL file from the Claude project directory
 * @param projectDir The Claude project directory path
 * @returns The path to the most recent JSONL file, or null if none found
 */
async function getMostRecentJsonlFile(projectDir: string): Promise<string | null> {
  try {
    // Check if project directory exists
    await fs.access(projectDir);
    
    // Get the most recent JSONL file
    const files = await fs.readdir(projectDir);
    const jsonlFiles = files
      .filter((f) => f.endsWith(".jsonl"))
      .sort((a, b) => b.localeCompare(a)); // Sort by name (most recent first)

    if (jsonlFiles.length === 0) {
      return null;
    }

    const firstFile = jsonlFiles[0];
    if (!firstFile) {
      return null;
    }

    return path.join(projectDir, firstFile);
  } catch {
    // Directory doesn't exist or other error
    return null;
  }
}

/**
 * Parse the last message from a Claude JSONL file
 * @param filePath The path to the JSONL file
 * @returns The last message, or null if unable to parse
 */
async function getLastMessage(filePath: string): Promise<ClaudeMessage | null> {
  try {
    const content = await fs.readFile(filePath, "utf-8");
    const lines = content.split("\n").filter((line) => line.trim());
    
    if (lines.length === 0) {
      return null;
    }

    const lastLine = lines[lines.length - 1];
    if (!lastLine) {
      return null;
    }

    try {
      const parsed = JSON.parse(lastLine);
      const lastMessage: ClaudeMessage = {
        type: parsed.type,
        timestamp: parsed.timestamp,
        content: "",
        hasToolUse: false,
      };
      
      // Extract content and check for tool_use
      const messageContent = parsed.message?.content;
      if (Array.isArray(messageContent)) {
        for (const item of messageContent) {
          if (item?.type === "text" && item?.text) {
            lastMessage.content = (lastMessage.content || "") + item.text + " ";
          } else if (item?.type === "tool_use") {
            lastMessage.hasToolUse = true;
          }
        }
      } else if (typeof messageContent === "string") {
        lastMessage.content = messageContent;
      }
      
      if (lastMessage.content) {
        lastMessage.content = lastMessage.content.trim();
      }
      
      return lastMessage;
    } catch {
      // Failed to parse JSON
      return null;
    }
  } catch {
    // Failed to read file
    return null;
  }
}

/**
 * Check if a Claude session is complete based on JSONL files
 * 
 * Claude completion detection logic:
 * - Claude is considered complete when:
 *   1. The last message is from assistant AND
 *   2. The assistant message has NO tool_use (just text response) AND
 *   3. There has been no new activity for a certain period (indicating Claude has stopped)
 * 
 * The key indicator is that Claude's last message must NOT contain tool_use.
 * When Claude includes tool_use in its message, it's waiting for tool results to continue.
 * When Claude responds with only text (no tool_use), it has finished its current task.
 * 
 * @param projectPath The Claude project directory path (or use workingDir to auto-compute)
 * @param workingDir Optional working directory to compute project path from
 * @param minIdleTimeMs Minimum time since last message to consider session idle (default 10 seconds)
 * @returns true if the session is complete, false otherwise
 */
export async function checkClaudeProjectFileCompletion(
  projectPath?: string,
  workingDir?: string,
  minIdleTimeMs: number = 10000
): Promise<boolean> {
  // Compute project path if not provided
  const projectDir = projectPath || (workingDir ? getClaudeProjectPath(workingDir) : null);
  
  if (!projectDir) {
    throw new Error("Either projectPath or workingDir must be provided");
  }

  // Get the most recent JSONL file
  const jsonlFile = await getMostRecentJsonlFile(projectDir);
  if (!jsonlFile) {
    // No JSONL files found - Claude hasn't started yet
    return false;
  }

  try {
    const fileContent = await fs.readFile(jsonlFile, "utf-8");
    const lines = fileContent.split("\n").filter((line) => line.trim());
    
    if (lines.length === 0) {
      return false;
    }

    // Parse the last few messages to understand the pattern
    const recentMessages: Array<{ 
      type: string; 
      timestamp?: string; 
      content?: string;
      hasToolUse?: boolean;
    }> = [];
    const linesToCheck = Math.min(10, lines.length); // Check last 10 messages
    
    for (let i = lines.length - linesToCheck; i < lines.length; i++) {
      try {
        const msg = JSON.parse(lines[i] as string);
        const messageContent = msg.message?.content;
        let textContent = "";
        let hasToolUse = false;
        
        // Extract text content from Claude's message structure
        if (Array.isArray(messageContent)) {
          for (const item of messageContent) {
            if (item?.type === "text" && item?.text) {
              textContent += item.text + " ";
            } else if (item?.type === "tool_use") {
              hasToolUse = true;
            }
          }
        } else if (typeof messageContent === "string") {
          textContent = messageContent;
        }
        
        recentMessages.push({
          type: msg.type,
          timestamp: msg.timestamp,
          content: textContent.trim(),
          hasToolUse
        });
      } catch {
        // Skip malformed lines
      }
    }
    
    if (recentMessages.length === 0) {
      return false;
    }
    
    const lastMessage = recentMessages[recentMessages.length - 1];
    
    // Check 1: Last message must be from assistant
    if (lastMessage?.type !== "assistant") {
      return false;
    }
    
    // Check 2: CRITICAL - If the last assistant message has tool_use, it's NOT complete
    // Claude is waiting for tool results when it has tool_use in its message
    if (lastMessage.hasToolUse) {
      console.log(`[Claude Detector] Not complete: Last assistant message has tool_use (waiting for tool result)`);
      return false;
    }
    
    // Check 3: Check if the session has been idle
    if (lastMessage.timestamp) {
      const lastMessageTime = new Date(lastMessage.timestamp).getTime();
      const timeSinceLastMessage = Date.now() - lastMessageTime;
      
      if (timeSinceLastMessage < minIdleTimeMs) {
        // Not enough idle time - Claude might still be working
        console.log(`[Claude Detector] Not idle long enough: ${timeSinceLastMessage}ms < ${minIdleTimeMs}ms`);
        return false;
      }
    }
    
    // Check 4: Optional - Look for completion indicators in the last assistant message
    // This is now secondary since the main indicator is no tool_use
    const completionPhrases = [
      "completed successfully",
      "task is complete",
      "task complete",
      "finished successfully", 
      "i've completed",
      "i have completed",
      "successfully completed",
      "successfully implemented",
      "changes have been made",
      "implementation is complete",
      "everything is working",
      "should now work",
      "should be working",
      "is now working",
      "has been fixed",
      "has been implemented",
      "has been added",
      "has been updated",
      "ready to use",
      "ready for use",
      "all set",
      "you're all set",
      "done!",
      "complete!",
      "finished!",
    ];
    
    const content = lastMessage.content?.toLowerCase() || "";
    const hasCompletionPhrase = completionPhrases.some(phrase => content.includes(phrase));
    
    console.log(`[Claude Detector] Completion check:`, {
      isAssistant: lastMessage?.type === "assistant",
      hasToolUse: lastMessage.hasToolUse,
      idleTime: lastMessage.timestamp ? Date.now() - new Date(lastMessage.timestamp).getTime() : 0,
      hasCompletionPhrase,
      contentPreview: content.substring(0, 100)
    });
    
    // Claude is complete when:
    // 1. Last message is from assistant (checked above)
    // 2. Last message has NO tool_use (checked above) 
    // 3. Session has been idle for minIdleTimeMs (checked above)
    // 4. Optionally has completion phrases (bonus indicator)
    
    // If we've passed all the checks above, Claude is complete
    return true;
    
  } catch (error) {
    console.error(`[Claude Detector] Error checking completion:`, error);
    return false;
  }
}

/**
 * Options for monitoring Claude completion
 */
export interface ClaudeCompletionMonitorOptions {
  workingDir: string;
  checkIntervalMs?: number;
  maxRuntimeMs?: number;
  minRuntimeMs?: number;
  onComplete?: () => void | Promise<void>;
  onError?: (error: Error) => void;
}

/**
 * Monitor a Claude session for completion
 * Returns a function to stop monitoring
 */
export function monitorClaudeCompletion(
  options: ClaudeCompletionMonitorOptions
): () => void {
  const {
    workingDir,
    checkIntervalMs = 5000,
    maxRuntimeMs = 20 * 60 * 1000, // 20 minutes
    minRuntimeMs = 30000, // 30 seconds
    onComplete,
    onError,
  } = options;

  const startTime = Date.now();
  const projectPath = getClaudeProjectPath(workingDir);
  let intervalId: NodeJS.Timeout | null = null;
  let stopped = false;

  const checkCompletion = async () => {
    if (stopped) return;

    try {
      const elapsedMs = Date.now() - startTime;
      
      // Don't consider task complete too early
      if (elapsedMs < minRuntimeMs) {
        return;
      }

      // Check if max runtime exceeded
      if (elapsedMs > maxRuntimeMs) {
        stop();
        if (onError) {
          onError(new Error(`Claude session exceeded max runtime of ${maxRuntimeMs}ms`));
        }
        return;
      }

      // Check if Claude session is complete
      // Use a 10 second idle time to ensure Claude has actually stopped
      const isComplete = await checkClaudeProjectFileCompletion(projectPath, undefined, 10000);
      if (isComplete) {
        stop();
        if (onComplete) {
          await onComplete();
        }
      }
    } catch (error) {
      if (onError) {
        onError(error instanceof Error ? error : new Error(String(error)));
      }
    }
  };

  // Start monitoring
  intervalId = setInterval(checkCompletion, checkIntervalMs);
  
  // Also check immediately (after min runtime)
  setTimeout(checkCompletion, minRuntimeMs);

  // Return stop function
  const stop = () => {
    stopped = true;
    if (intervalId) {
      clearInterval(intervalId);
      intervalId = null;
    }
  };

  return stop;
}

/**
 * Get information about the Claude session state
 */
export interface ClaudeSessionInfo {
  projectPath: string;
  hasProjectDir: boolean;
  jsonlFiles: string[];
  mostRecentFile: string | null;
  lastMessage: ClaudeMessage | null;
  isComplete: boolean;
}

/**
 * Get detailed information about a Claude session
 */
export async function getClaudeSessionInfo(workingDir: string): Promise<ClaudeSessionInfo> {
  const projectPath = getClaudeProjectPath(workingDir);
  
  let hasProjectDir = false;
  let jsonlFiles: string[] = [];
  let mostRecentFile: string | null = null;
  let lastMessage: ClaudeMessage | null = null;
  let isComplete = false;

  try {
    await fs.access(projectPath);
    hasProjectDir = true;
    
    const files = await fs.readdir(projectPath);
    jsonlFiles = files
      .filter((f) => f.endsWith(".jsonl"))
      .sort((a, b) => b.localeCompare(a));
    
    if (jsonlFiles.length > 0) {
      const firstFile = jsonlFiles[0];
      if (firstFile) {
        mostRecentFile = path.join(projectPath, firstFile);
        lastMessage = await getLastMessage(mostRecentFile);
        // Use the more robust completion check
        isComplete = await checkClaudeProjectFileCompletion(projectPath);
      }
    }
  } catch {
    // Project directory doesn't exist
  }

  return {
    projectPath,
    hasProjectDir,
    jsonlFiles,
    mostRecentFile,
    lastMessage,
    isComplete,
  };
}

/**
 * Export all functions and types for convenience
 */
export default {
  getClaudeProjectPath,
  checkClaudeProjectFileCompletion,
  monitorClaudeCompletion,
  getClaudeSessionInfo,
};
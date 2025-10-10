import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { appendFile, readFile, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";

export type LogLevel = "info" | "error" | "warn";

const isErrnoException = (error: unknown): error is NodeJS.ErrnoException =>
  typeof error === "object" && error !== null && "code" in error;

class Logger {
  private readonly MAX_LOG_SIZE = 10 * 1024 * 1024; // 10MB
  private readonly logDir: string;
  private readonly logFile: string;

  constructor(logFileName: string = "cmux-cli.log") {
    this.logDir = path.join(homedir(), ".cmux", "logs");
    this.logFile = path.join(this.logDir, logFileName);
    this.ensureLogDirectory();
  }

  ensureLogDirectory(): void {
    try {
      // Ensure log directory exists
      if (!existsSync(this.logDir)) {
        mkdirSync(this.logDir, { recursive: true });
      }

      // Make sure the log file exists
      if (!existsSync(this.logFile)) {
        writeFileSync(this.logFile, "");
      }
    } catch (error) {
      // If we can't create the log directory, just log to console
      console.error("Failed to initialize logger:", error);
    }
  }

  private async rotateLogIfNeeded(): Promise<void> {
    try {
      const stats = await stat(this.logFile);
      if (stats.size > this.MAX_LOG_SIZE) {
        // Rotate log file
        const timestamp = new Date().toISOString().replace(/:/g, "-");
        const rotatedFile = path.join(this.logDir, `cmux-${timestamp}.log`);
        const content = await readFile(this.logFile, "utf-8");
        await writeFile(rotatedFile, content);
        await writeFile(this.logFile, "");
      }
    } catch (error) {
      // File doesn't exist yet, that's ok
    }
  }

  private async log(message: string, level: LogLevel): Promise<void> {
    await this.rotateLogIfNeeded();

    const timestamp = new Date().toISOString();
    const logEntry = `[${timestamp}] [${level.toUpperCase()}] ${message}\n`;

    try {
      await appendFile(this.logFile, logEntry);
    } catch (error) {
      // If the directory was deleted, recreate it
      if (isErrnoException(error) && error.code === "ENOENT") {
        this.ensureLogDirectory();
        // Try once more
        try {
          await appendFile(this.logFile, logEntry);
          return;
        } catch (retryError) {
          // If it still fails, fall through to console logging
        }
      }
      // Fallback to console if logging fails
      console.error("Failed to write to log file:", error);
      console.log(message);
    }
  }

  info(message: string): Promise<void> {
    return this.log(message, "info");
  }

  error(message: string): Promise<void> {
    return this.log(message, "error");
  }

  warn(message: string): Promise<void> {
    return this.log(message, "warn");
  }
}

// Create a singleton instance
export const logger = new Logger();

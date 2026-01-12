import { EventEmitter } from "node:events";
import { MorphConnector, type MorphSession, type SessionFilter } from "./connector.js";
import {
  type SessionSpec,
  type Question,
  createEmptySpec,
  answerQuestion,
  skipQuestion,
  flagAssumption,
  approveDecision,
  getOpenQuestions,
  isBlocked,
} from "./spec.js";
import {
  extractFromOutput,
  applyExtractionToSpec,
  classifyQuestion,
} from "./extractor.js";

export * from "./spec.js";
export * from "./extractor.js";
export * from "./connector.js";
export * from "./protocol.js";

/**
 * Session Orchestrator
 *
 * Manages multiple Claude Code sessions:
 * 1. Monitors output streams
 * 2. Extracts decisions/questions/assumptions
 * 3. Filters questions for human attention
 * 4. Injects human responses back
 */

export interface OrchestratorEvents {
  sessionDiscovered: (session: MorphSession) => void;
  sessionLost: (instanceId: string) => void;
  specUpdated: (instanceId: string, spec: SessionSpec) => void;
  questionSurfaced: (instanceId: string, question: Question) => void;
  questionAutoAnswered: (
    instanceId: string,
    question: Question,
    answer: string
  ) => void;
}

export interface OrchestratorOptions {
  pollIntervalMs?: number;
  autoAnswerEnabled?: boolean;
  filter?: SessionFilter;
}

export class SessionOrchestrator extends EventEmitter {
  private connector: MorphConnector;
  private specs: Map<string, SessionSpec> = new Map();
  private sessions: Map<string, MorphSession> = new Map();
  private pollInterval: NodeJS.Timeout | null = null;
  private options: Required<Omit<OrchestratorOptions, "filter">> & { filter?: SessionFilter };

  constructor(options: OrchestratorOptions = {}) {
    super();
    this.connector = new MorphConnector();
    this.options = {
      pollIntervalMs: options.pollIntervalMs ?? 5000,
      autoAnswerEnabled: options.autoAnswerEnabled ?? true,
      filter: options.filter,
    };
  }

  /**
   * Start monitoring sessions
   */
  start(): void {
    if (this.pollInterval) {
      return; // Already running
    }

    // Initial poll
    this.poll().catch(console.error);

    // Set up recurring poll
    this.pollInterval = setInterval(() => {
      this.poll().catch(console.error);
    }, this.options.pollIntervalMs);
  }

  /**
   * Stop monitoring sessions
   */
  stop(): void {
    if (this.pollInterval) {
      clearInterval(this.pollInterval);
      this.pollInterval = null;
    }
  }

  /**
   * Poll for session updates
   */
  private async poll(): Promise<void> {
    // Discover sessions (with optional filter)
    const currentSessions = await this.connector.listSessions(this.options.filter);
    const currentIds = new Set(currentSessions.map((s) => s.instanceId));

    // Check for new sessions
    for (const session of currentSessions) {
      if (!this.sessions.has(session.instanceId)) {
        this.sessions.set(session.instanceId, session);
        this.specs.set(
          session.instanceId,
          createEmptySpec(session.instanceId, session.metadata.taskRunId)
        );
        this.emit("sessionDiscovered", session);
      }
    }

    // Check for lost sessions
    for (const [instanceId] of this.sessions) {
      if (!currentIds.has(instanceId)) {
        this.sessions.delete(instanceId);
        this.specs.delete(instanceId);
        this.emit("sessionLost", instanceId);
      }
    }

    // Update specs for all active sessions
    for (const session of currentSessions) {
      if (session.status === "running") {
        await this.updateSessionSpec(session.instanceId);
      }
    }
  }

  /**
   * Update spec for a specific session
   */
  private async updateSessionSpec(instanceId: string): Promise<void> {
    const spec = this.specs.get(instanceId);
    if (!spec) return;

    // Read output from the session
    const output = await this.connector.readTmuxOutput(instanceId);
    if (!output) return;

    // Extract structured data from output
    const extraction = extractFromOutput(output, spec);

    // If nothing new, skip
    if (
      extraction.decisions.length === 0 &&
      extraction.questions.length === 0 &&
      extraction.assumptions.length === 0 &&
      !extraction.focus
    ) {
      return;
    }

    // Apply extraction to spec
    const updatedSpec = applyExtractionToSpec(spec, extraction);
    this.specs.set(instanceId, updatedSpec);
    this.emit("specUpdated", instanceId, updatedSpec);

    // Process new questions
    for (const question of extraction.questions) {
      await this.processQuestion(instanceId, question);
    }
  }

  /**
   * Process a new question - classify and route appropriately
   */
  private async processQuestion(
    instanceId: string,
    question: Question
  ): Promise<void> {
    const classification = classifyQuestion(question);

    switch (classification) {
      case "surface":
        // Surface to human
        this.emit("questionSurfaced", instanceId, question);
        break;

      case "auto-answer":
        if (this.options.autoAnswerEnabled) {
          // Try to auto-answer
          const answer = await this.tryAutoAnswer(instanceId, question);
          if (answer) {
            await this.answerQuestion(instanceId, question.id, answer);
            this.emit("questionAutoAnswered", instanceId, question, answer);
          } else {
            // Couldn't auto-answer, surface to human
            this.emit("questionSurfaced", instanceId, question);
          }
        } else {
          this.emit("questionSurfaced", instanceId, question);
        }
        break;

      case "skip":
        // Skip without surfacing
        await this.skipQuestion(instanceId, question.id);
        break;
    }
  }

  /**
   * Try to auto-answer a question by searching the codebase
   */
  private async tryAutoAnswer(
    instanceId: string,
    question: Question
  ): Promise<string | null> {
    const q = question.question.toLowerCase();

    // For "where is" questions, try to find the file
    if (q.includes("where is") || q.includes("what file")) {
      // Extract what they're looking for
      const match = q.match(
        /(?:where is|what file.*?)(?:the\s+)?(\w+(?:\s+\w+)?)/i
      );
      if (match) {
        const searchTerm = match[1];
        try {
          const result = await this.connector.exec(
            instanceId,
            `find /root/workspace -name "*${searchTerm}*" -type f 2>/dev/null | head -5`
          );
          if (result.stdout.trim()) {
            return `Found at: ${result.stdout.trim().split("\n")[0]}`;
          }
        } catch {
          // Search failed
        }
      }
    }

    return null;
  }

  /**
   * Answer a question (from human input)
   */
  async answerQuestion(
    instanceId: string,
    questionId: string,
    answer: string
  ): Promise<boolean> {
    const spec = this.specs.get(instanceId);
    if (!spec) return false;

    // Update spec
    const updatedSpec = answerQuestion(spec, questionId, answer);
    this.specs.set(instanceId, updatedSpec);

    // Inject answer into Claude Code
    const success = await this.connector.injectMessage(instanceId, answer);

    if (success) {
      this.emit("specUpdated", instanceId, updatedSpec);
    }

    return success;
  }

  /**
   * Skip a question
   */
  async skipQuestion(instanceId: string, questionId: string): Promise<void> {
    const spec = this.specs.get(instanceId);
    if (!spec) return;

    const updatedSpec = skipQuestion(spec, questionId);
    this.specs.set(instanceId, updatedSpec);
    this.emit("specUpdated", instanceId, updatedSpec);
  }

  /**
   * Flag an assumption as incorrect
   */
  async flagAssumption(
    instanceId: string,
    assumptionId: string,
    correction: string
  ): Promise<boolean> {
    const spec = this.specs.get(instanceId);
    if (!spec) return false;

    // Update spec
    const updatedSpec = flagAssumption(spec, assumptionId, correction);
    this.specs.set(instanceId, updatedSpec);

    // Inject correction into Claude Code
    const message = `CORRECTION: ${correction}`;
    const success = await this.connector.injectMessage(instanceId, message);

    if (success) {
      this.emit("specUpdated", instanceId, updatedSpec);
    }

    return success;
  }

  /**
   * Approve a decision
   */
  approveDecision(instanceId: string, decisionId: string): void {
    const spec = this.specs.get(instanceId);
    if (!spec) return;

    const updatedSpec = approveDecision(spec, decisionId);
    this.specs.set(instanceId, updatedSpec);
    this.emit("specUpdated", instanceId, updatedSpec);
  }

  /**
   * Send a free-form message to a session
   */
  async sendMessage(instanceId: string, message: string): Promise<boolean> {
    return this.connector.injectMessage(instanceId, message);
  }

  /**
   * Get all active sessions
   */
  getSessions(): MorphSession[] {
    return Array.from(this.sessions.values());
  }

  /**
   * Get spec for a session
   */
  getSpec(instanceId: string): SessionSpec | undefined {
    return this.specs.get(instanceId);
  }

  /**
   * Get all specs
   */
  getAllSpecs(): Map<string, SessionSpec> {
    return new Map(this.specs);
  }

  /**
   * Get sessions with open questions
   */
  getSessionsWithQuestions(): Array<{
    session: MorphSession;
    questions: Question[];
  }> {
    const result: Array<{ session: MorphSession; questions: Question[] }> = [];

    for (const session of this.sessions.values()) {
      const spec = this.specs.get(session.instanceId);
      if (spec) {
        const openQuestions = getOpenQuestions(spec);
        if (openQuestions.length > 0) {
          result.push({ session, questions: openQuestions });
        }
      }
    }

    return result;
  }

  /**
   * Get blocked sessions
   */
  getBlockedSessions(): Array<{ session: MorphSession; blockedOn: string }> {
    const result: Array<{ session: MorphSession; blockedOn: string }> = [];

    for (const session of this.sessions.values()) {
      const spec = this.specs.get(session.instanceId);
      if (spec && isBlocked(spec) && spec.blockedOn) {
        result.push({ session, blockedOn: spec.blockedOn });
      }
    }

    return result;
  }
}

// Re-export types
export type { MorphSession } from "./connector.js";
export type {
  SessionSpec,
  Decision,
  Question,
  Assumption,
} from "./spec.js";
export type { ExtractionResult } from "./extractor.js";

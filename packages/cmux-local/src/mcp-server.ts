#!/usr/bin/env node
/**
 * MCP Server for cmux-local
 *
 * Provides tools for Claude Code to communicate with the orchestrator:
 * - ask_user_question: Ask an important question to the human operator
 * - report_progress: Report current progress/status
 * - report_decision: Report a decision that was made
 *
 * Communication is via JSON files in /tmp/cmux/:
 * - /tmp/cmux/questions.json - Questions waiting for answers
 * - /tmp/cmux/answers.json - Answers from the orchestrator
 * - /tmp/cmux/progress.json - Progress updates
 */

import * as fs from "node:fs";
import * as path from "node:path";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const CMUX_DIR = "/tmp/cmux";
const QUESTIONS_FILE = path.join(CMUX_DIR, "questions.json");
const ANSWERS_FILE = path.join(CMUX_DIR, "answers.json");
const PROGRESS_FILE = path.join(CMUX_DIR, "progress.json");

// Ensure directory exists
if (!fs.existsSync(CMUX_DIR)) {
  fs.mkdirSync(CMUX_DIR, { recursive: true });
}

interface Question {
  id: string;
  question: string;
  context?: string;
  importance: "high" | "medium" | "low";
  timestamp: string;
  answered: boolean;
}

interface Answer {
  questionId: string;
  answer: string;
  timestamp: string;
}

function generateId(): string {
  return Math.random().toString(36).substring(2, 10);
}

function readJsonFile<T>(filePath: string, defaultValue: T): T {
  try {
    if (fs.existsSync(filePath)) {
      return JSON.parse(fs.readFileSync(filePath, "utf-8"));
    }
  } catch {
    // File doesn't exist or is invalid
  }
  return defaultValue;
}

function writeJsonFile(filePath: string, data: unknown): void {
  fs.writeFileSync(filePath, JSON.stringify(data, null, 2));
}

async function waitForAnswer(questionId: string, timeoutMs: number = 300000): Promise<string | null> {
  const startTime = Date.now();
  const pollInterval = 1000; // Poll every second

  while (Date.now() - startTime < timeoutMs) {
    const answers = readJsonFile<Answer[]>(ANSWERS_FILE, []);
    const answer = answers.find((a) => a.questionId === questionId);

    if (answer) {
      // Remove the answer from the file
      const remainingAnswers = answers.filter((a) => a.questionId !== questionId);
      writeJsonFile(ANSWERS_FILE, remainingAnswers);
      return answer.answer;
    }

    await new Promise((resolve) => setTimeout(resolve, pollInterval));
  }

  return null; // Timeout
}

const server = new Server(
  {
    name: "cmux-orchestrator",
    version: "1.0.0",
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// List available tools
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: "ask_user_question",
        description: `Ask an important question to the human operator. Use this tool when you:
- Need clarification on requirements or intent
- Are unsure about a significant architectural decision
- Need to confirm before making a potentially breaking change
- Have multiple valid approaches and need guidance

DO NOT use this for:
- Questions you can answer yourself with reasoning
- Simple yes/no confirmations for routine operations
- Questions about syntax or implementation details you can look up

The orchestrator will filter out unimportant questions, so only ask when genuinely needed.`,
        inputSchema: {
          type: "object",
          properties: {
            question: {
              type: "string",
              description: "The question to ask the user. Be specific and provide context.",
            },
            context: {
              type: "string",
              description: "Additional context about why you're asking this question and what you've considered so far.",
            },
            importance: {
              type: "string",
              enum: ["high", "medium", "low"],
              description: "How important is this question? High = blocking decision, Medium = would help but can proceed, Low = nice to know",
            },
            options: {
              type: "array",
              items: { type: "string" },
              description: "Optional list of suggested options/answers",
            },
          },
          required: ["question", "importance"],
        },
      },
      {
        name: "report_progress",
        description: "Report your current progress to the orchestrator. Use this periodically to keep the human informed.",
        inputSchema: {
          type: "object",
          properties: {
            status: {
              type: "string",
              enum: ["starting", "in_progress", "blocked", "completed", "error"],
              description: "Current status",
            },
            summary: {
              type: "string",
              description: "Brief summary of what you're doing or have done",
            },
            details: {
              type: "string",
              description: "Optional detailed information",
            },
          },
          required: ["status", "summary"],
        },
      },
      {
        name: "report_decision",
        description: "Report a significant decision you've made. This helps the human understand your reasoning.",
        inputSchema: {
          type: "object",
          properties: {
            decision: {
              type: "string",
              description: "What decision was made",
            },
            reasoning: {
              type: "string",
              description: "Why this decision was made",
            },
            alternatives: {
              type: "array",
              items: { type: "string" },
              description: "What alternatives were considered",
            },
          },
          required: ["decision", "reasoning"],
        },
      },
    ],
  };
});

// Handle tool calls
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "ask_user_question": {
      const { question, context, importance, options } = args as {
        question: string;
        context?: string;
        importance: "high" | "medium" | "low";
        options?: string[];
      };

      const questionId = generateId();
      const questionObj: Question & { options?: string[] } = {
        id: questionId,
        question,
        context,
        importance,
        options,
        timestamp: new Date().toISOString(),
        answered: false,
      };

      // Add to questions file
      const questions = readJsonFile<Question[]>(QUESTIONS_FILE, []);
      questions.push(questionObj);
      writeJsonFile(QUESTIONS_FILE, questions);

      // Wait for answer (with timeout)
      const answer = await waitForAnswer(questionId, 300000); // 5 minute timeout

      if (answer) {
        // Mark question as answered
        const updatedQuestions = readJsonFile<Question[]>(QUESTIONS_FILE, []);
        const idx = updatedQuestions.findIndex((q) => q.id === questionId);
        if (idx !== -1) {
          updatedQuestions[idx].answered = true;
          writeJsonFile(QUESTIONS_FILE, updatedQuestions);
        }

        return {
          content: [
            {
              type: "text",
              text: `User's answer: ${answer}`,
            },
          ],
        };
      } else {
        return {
          content: [
            {
              type: "text",
              text: "The user did not respond within the timeout period. Please proceed with your best judgment or try asking a more specific question.",
            },
          ],
        };
      }
    }

    case "report_progress": {
      const { status, summary, details } = args as {
        status: string;
        summary: string;
        details?: string;
      };

      const progress = readJsonFile<Array<{
        status: string;
        summary: string;
        details?: string;
        timestamp: string;
      }>>(PROGRESS_FILE, []);

      progress.push({
        status,
        summary,
        details,
        timestamp: new Date().toISOString(),
      });

      // Keep only last 50 progress entries
      if (progress.length > 50) {
        progress.splice(0, progress.length - 50);
      }

      writeJsonFile(PROGRESS_FILE, progress);

      return {
        content: [
          {
            type: "text",
            text: "Progress reported to orchestrator.",
          },
        ],
      };
    }

    case "report_decision": {
      const { decision, reasoning, alternatives } = args as {
        decision: string;
        reasoning: string;
        alternatives?: string[];
      };

      // Add to progress file as a decision
      const progress = readJsonFile<Array<{
        type?: string;
        decision?: string;
        reasoning?: string;
        alternatives?: string[];
        timestamp: string;
      }>>(PROGRESS_FILE, []);

      progress.push({
        type: "decision",
        decision,
        reasoning,
        alternatives,
        timestamp: new Date().toISOString(),
      });

      writeJsonFile(PROGRESS_FILE, progress);

      return {
        content: [
          {
            type: "text",
            text: "Decision reported to orchestrator.",
          },
        ],
      };
    }

    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

// Start the server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("CMUX MCP Server running");
}

main().catch(console.error);

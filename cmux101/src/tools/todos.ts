import { z } from "zod";
import type { Tool, ToolContext, ToolResult } from "../core/types.js";

// ----------------------------------------------------------------------------
// Types
// ----------------------------------------------------------------------------

export interface Todo {
  id: string;
  subject: string;
  description?: string;
  activeForm?: string;
  status: "pending" | "in_progress" | "completed" | "deleted";
}

// ----------------------------------------------------------------------------
// Registry
// ----------------------------------------------------------------------------

const registry = new Map<string, Todo[]>();

function getList(sessionId: string): Todo[] {
  if (!registry.has(sessionId)) {
    registry.set(sessionId, []);
  }
  return registry.get(sessionId)!;
}

function formatList(todos: Todo[]): string {
  if (todos.length === 0) return "(no todos)";
  return todos
    .map((t) => {
      const badge =
        t.status === "pending"
          ? "[ ]"
          : t.status === "in_progress"
            ? "[~]"
            : t.status === "completed"
              ? "[x]"
              : "[d]";
      const desc = t.description ? ` — ${t.description}` : "";
      return `${badge} [${t.id}] ${t.subject}${desc}`;
    })
    .join("\n");
}

// ----------------------------------------------------------------------------
// todo_write
// ----------------------------------------------------------------------------

export const todoWriteTool: Tool = {
  name: "todo_write",
  description:
    "Replace the current session's todo list. Provide an array of todos to set the full plan.",
  inputSchema: z.object({
    todos: z.array(
      z.object({
        subject: z.string(),
        description: z.string().optional(),
        activeForm: z.string().optional(),
      }),
    ),
  }),
  defaultPermission: "allow",

  async run(input: unknown, ctx: ToolContext): Promise<ToolResult> {
    const parsed = (todoWriteTool.inputSchema as ReturnType<typeof z.object>).parse(input) as {
      todos: Array<{ subject: string; description?: string; activeForm?: string }>;
    };

    const sessionId = ctx.session.meta.id;
    const newList: Todo[] = parsed.todos.map((t, i) => ({
      id: String(i + 1),
      subject: t.subject,
      description: t.description,
      activeForm: t.activeForm,
      status: "pending",
    }));

    registry.set(sessionId, newList);

    return { content: formatList(newList) };
  },
};

// ----------------------------------------------------------------------------
// todo_list
// ----------------------------------------------------------------------------

export const todoListTool: Tool = {
  name: "todo_list",
  description: "List all todos for the current session.",
  inputSchema: z.object({}),
  defaultPermission: "allow",

  async run(_input: unknown, ctx: ToolContext): Promise<ToolResult> {
    const sessionId = ctx.session.meta.id;
    const list = getList(sessionId);
    return { content: formatList(list) };
  },
};

// ----------------------------------------------------------------------------
// todo_update
// ----------------------------------------------------------------------------

export const todoUpdateTool: Tool = {
  name: "todo_update",
  description: "Update a single todo by id. Patch status, subject, or activeForm.",
  inputSchema: z.object({
    id: z.string(),
    status: z.enum(["pending", "in_progress", "completed", "deleted"]).optional(),
    subject: z.string().optional(),
    activeForm: z.string().optional(),
  }),
  defaultPermission: "allow",

  async run(input: unknown, ctx: ToolContext): Promise<ToolResult> {
    const parsed = (todoUpdateTool.inputSchema as ReturnType<typeof z.object>).parse(input) as {
      id: string;
      status?: Todo["status"];
      subject?: string;
      activeForm?: string;
    };

    const sessionId = ctx.session.meta.id;
    const list = getList(sessionId);
    const idx = list.findIndex((t) => t.id === parsed.id);

    if (idx === -1) {
      return { content: `Todo with id "${parsed.id}" not found.`, isError: true };
    }

    if (parsed.status !== undefined) list[idx].status = parsed.status;
    if (parsed.subject !== undefined) list[idx].subject = parsed.subject;
    if (parsed.activeForm !== undefined) list[idx].activeForm = parsed.activeForm;

    return { content: formatList(list) };
  },
};

// ----------------------------------------------------------------------------
// Export
// ----------------------------------------------------------------------------

export const todoTools: Tool[] = [todoWriteTool, todoListTool, todoUpdateTool];

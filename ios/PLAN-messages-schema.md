# Messages Schema Plan

## Goal
Create a unified Convex schema to store chat messages from multiple AI coding assistants (scaffolds): Claude Code, Codex, Gemini CLI, and OpenCode.

## Research Summary

### Scaffolds Analyzed
| Scaffold | Session Storage | Message Format | Local Path |
|----------|----------------|----------------|------------|
| Claude Code | JSONL per session | `type`: user/assistant/system/result | `~/.claude/projects/{hash}/{session}.jsonl` |
| Codex | JSONL per day | `ThreadItem` types | `~/.codex/sessions/YYYY/MM/DD/*.jsonl` |
| Gemini CLI | JSON per session | `MessageRecord` | `~/.gemini/tmp/{hash}/chats/*.json` |
| OpenCode | JSON per entity | Messages + Parts | `~/.local/share/opencode/storage/` |

### Common Patterns
- All have sessions/threads as containers
- All have messages with roles (user/assistant)
- All have tool calls with id, name, input, output, status
- All track token usage (input, output, cache)
- All have timestamps
- All support parent-child message relationships

### Field Mapping
| Field | Claude | Codex | Gemini | OpenCode |
|-------|--------|-------|--------|----------|
| Session ID | `session_id` | `thread_id` | `sessionId` | `ses_<ts>` |
| Message ID | `uuid` | `id` | `id` | `msg_<ts>` |
| Role | user/assistant | user/assistant | user/gemini | user/assistant |
| Tool Call ID | `tool_use_id` | `call_id` | `callId` | `callID` |
| Parent Ref | `parentUuid` | - | - | `parentID` |
| Input Tokens | `input_tokens` | `input_tokens` | `input` | `tokens.input` |
| Output Tokens | `output_tokens` | `output_tokens` | `output` | `tokens.output` |
| Cache Tokens | `cache_read/creation` | `cached_input_tokens` | `cached` | `cache.read/write` |

---

## Schema Design

### Tables

#### 1. `chatSessions`
Container for a conversation/chat session.

```typescript
chatSessions: defineTable({
  // Core identifiers
  externalId: v.string(),        // Original session ID from scaffold
  scaffold: v.union(
    v.literal("claude"),
    v.literal("codex"),
    v.literal("gemini"),
    v.literal("opencode")
  ),

  // Ownership
  userId: v.id("users"),
  teamId: v.id("teams"),
  taskId: v.optional(v.id("tasks")), // Link to existing cmux task

  // Context
  title: v.string(),
  cwd: v.string(),               // Working directory
  gitBranch: v.optional(v.string()),
  gitCommit: v.optional(v.string()),

  // Timestamps
  createdAt: v.number(),
  updatedAt: v.number(),

  // Summary (AI-generated)
  summary: v.optional(v.string()),

  // Scaffold-specific metadata
  metadata: v.optional(v.any()),
})
.index("by_user", ["userId"])
.index("by_team", ["teamId", "updatedAt"])
.index("by_task", ["taskId"])
.index("by_external", ["scaffold", "externalId"])
```

#### 2. `chatMessages`
Individual messages within a session.

```typescript
chatMessages: defineTable({
  // Core identifiers
  externalId: v.string(),        // Original message ID from scaffold
  sessionId: v.id("chatSessions"),
  scaffold: v.union(
    v.literal("claude"),
    v.literal("codex"),
    v.literal("gemini"),
    v.literal("opencode")
  ),

  // Message content
  role: v.union(
    v.literal("user"),
    v.literal("assistant"),
    v.literal("system")
  ),
  content: v.string(),           // Text content

  // For tool results / follow-ups
  parentMessageId: v.optional(v.id("chatMessages")),
  parentToolCallId: v.optional(v.string()),

  // Model info (for assistant messages)
  model: v.optional(v.string()),

  // Token usage
  tokens: v.optional(v.object({
    input: v.number(),
    output: v.number(),
    cacheRead: v.optional(v.number()),
    cacheWrite: v.optional(v.number()),
    reasoning: v.optional(v.number()),
  })),

  // Cost tracking
  costUsd: v.optional(v.number()),

  // Timestamps
  createdAt: v.number(),
  completedAt: v.optional(v.number()),

  // Scaffold-specific metadata
  metadata: v.optional(v.any()),
})
.index("by_session", ["sessionId", "createdAt"])
.index("by_external", ["scaffold", "externalId"])
```

#### 3. `chatToolCalls`
Tool invocations within messages (separate for querying/streaming).

```typescript
chatToolCalls: defineTable({
  externalId: v.string(),        // tool_use_id / call_id / callId
  messageId: v.id("chatMessages"),
  sessionId: v.id("chatSessions"),
  scaffold: v.union(
    v.literal("claude"),
    v.literal("codex"),
    v.literal("gemini"),
    v.literal("opencode")
  ),

  // Tool info
  name: v.string(),              // e.g., "Bash", "Edit", "Read"
  input: v.any(),                // Tool arguments
  output: v.optional(v.string()), // Result (truncated if large)

  // Status
  status: v.union(
    v.literal("pending"),
    v.literal("running"),
    v.literal("completed"),
    v.literal("error"),
    v.literal("cancelled")
  ),
  error: v.optional(v.string()),

  // Timing
  startedAt: v.number(),
  completedAt: v.optional(v.number()),
  durationMs: v.optional(v.number()),

  // For display
  displayTitle: v.optional(v.string()),

  // Scaffold-specific metadata
  metadata: v.optional(v.any()),
})
.index("by_message", ["messageId"])
.index("by_session", ["sessionId", "startedAt"])
.index("by_external", ["scaffold", "externalId"])
```

---

## iOS Models

```swift
enum Scaffold: String, Codable {
    case claude
    case codex
    case gemini
    case opencode
}

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

struct ChatSession: Identifiable, Codable {
    let id: String              // Convex _id
    let externalId: String
    let scaffold: Scaffold
    let title: String
    let cwd: String
    let gitBranch: String?
    let summary: String?
    let createdAt: Date
    let updatedAt: Date
}

struct ChatMessage: Identifiable, Codable {
    let id: String              // Convex _id
    let sessionId: String
    let role: MessageRole
    let content: String
    let model: String?
    let tokens: TokenUsage?
    let costUsd: Double?
    let createdAt: Date
}

struct TokenUsage: Codable {
    let input: Int
    let output: Int
    let cacheRead: Int?
    let cacheWrite: Int?
    let reasoning: Int?
}

struct ToolCall: Identifiable, Codable {
    let id: String
    let name: String
    let status: ToolCallStatus
    let displayTitle: String?
    let durationMs: Int?
}

enum ToolCallStatus: String, Codable {
    case pending
    case running
    case completed
    case error
    case cancelled
}
```

---

## Sync Strategy

### Option A: Real-time sync via CLI hooks
- Claude Code has hooks (`SessionStart`, `PostToolUse`, etc.)
- Can POST to cmux API on each event
- Pro: Real-time updates
- Con: Requires hook setup per machine

### Option B: Periodic file sync
- Read local JSONL/JSON files periodically
- Dedupe via `externalId`
- Pro: Works without hook setup
- Con: Not real-time

### Option C: Hybrid
- Use hooks when available for real-time
- Fall back to file sync for import/backfill

---

## Implementation Steps

1. [ ] Add schema to `packages/convex/convex/schema.ts`
2. [ ] Create mutations: `createSession`, `createMessage`, `createToolCall`
3. [ ] Create queries: `listSessions`, `getSession`, `getMessages`, `getToolCalls`
4. [ ] Add HTTP endpoints for sync API
5. [ ] Create iOS models and Convex client integration
6. [ ] Implement sync (hooks or file-based)

---

## Open Questions

1. **Storage limits**: Should we truncate large tool outputs? (e.g., >10KB)
2. **Retention**: How long to keep messages? Archive old sessions?
3. **Search**: Do we need full-text search on message content?
4. **Streaming**: How to handle streaming assistant responses?

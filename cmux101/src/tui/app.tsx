/**
 * Root App component for the cmux101 TUI.
 * Wires together MessageList, UserInput, and the streaming event pipeline.
 */
import React, { useState, useCallback, useRef, useEffect } from "react";
import { Box, Text, useApp, useInput, useStdout } from "ink";
import { MessageList } from "./messages.js";
import type { StreamingState } from "./messages.js";
import { UserInput } from "./input.js";
import { theme } from "./theme.js";
import { applyStreamEvent, applyToolUpdate, initialStreamingState } from "./streamReducer.js";
import type { StreamEvent, Message } from "../core/types.js";
import type { SessionHandle } from "../core/types.js";

// ---------------------------------------------------------------------------
// Public handle shape exposed to the runner
// ---------------------------------------------------------------------------

export interface AppHandle {
  pushStreamEvent(event: StreamEvent): void;
  pushToolUpdate(update: {
    name: string;
    outputDelta?: string;
    status: StreamingState["status"];
  }): void;
  onMessageAppended(message: Message): void;
}

// ---------------------------------------------------------------------------
// InitialAppProps
// ---------------------------------------------------------------------------

export interface InitialAppProps {
  session: SessionHandle;
  send: (userText: string) => Promise<void>;
  abort: () => void;
  showThinking?: boolean;
  greeting?: string;
  /** Callback fired after mount, passing the AppHandle back to the runner. */
  onReady?: (handle: AppHandle) => void;
}

// ---------------------------------------------------------------------------
// Top bar
// ---------------------------------------------------------------------------

function TopBar({
  sessionId,
  model,
  cwd,
  columns,
}: {
  sessionId: string;
  model: string;
  cwd: string;
  columns: number;
}) {
  const short = sessionId.slice(0, 8);
  const line = ` session:${short}  model:${model}  cwd:${cwd} `;
  return (
    <Box borderStyle="single" borderColor={theme.accent} paddingX={1} width={columns}>
      <Text color={theme.accent}>{line}</Text>
    </Box>
  );
}

// ---------------------------------------------------------------------------
// Bottom hint bar
// ---------------------------------------------------------------------------

function BottomHint({ columns }: { columns: number }) {
  return (
    <Box borderStyle="single" borderColor={theme.dim} paddingX={1} width={columns}>
      <Text color={theme.dim}>↵ send  ⌃C abort  /help</Text>
    </Box>
  );
}

// ---------------------------------------------------------------------------
// App component
// ---------------------------------------------------------------------------

export function App({
  session,
  send,
  abort,
  showThinking = false,
  greeting,
  onReady,
}: InitialAppProps) {
  const app = useApp();
  const { stdout } = useStdout();
  const columns = stdout?.columns ?? 100;

  // Message history (copies from session.messages on mount + appended messages)
  const [messages, setMessages] = useState<Message[]>([
    ...(session.messages as Message[]),
  ]);

  // Streaming state — null when idle
  const [streaming, setStreaming] = useState<StreamingState | null>(null);

  // Disabled while the assistant is responding
  const [inputDisabled, setInputDisabled] = useState(false);

  // Track Ctrl+C press count for graceful exit
  const ctrlCCount = useRef(0);

  // ---------------------------------------------------------------------------
  // Ctrl+C handling
  // ---------------------------------------------------------------------------
  useInput((_input, key) => {
    if (key.ctrl && _input === "c") {
      ctrlCCount.current += 1;
      if (ctrlCCount.current === 1) {
        abort();
        // Re-enable input after abort
        setInputDisabled(false);
        setStreaming(null);
      } else {
        app.exit();
      }
    }
  });

  // ---------------------------------------------------------------------------
  // AppHandle — stable via ref so runner can hold onto it
  // ---------------------------------------------------------------------------
  const handleRef = useRef<AppHandle>({
    pushStreamEvent(event: StreamEvent) {
      setStreaming((prev) => {
        const base = prev ?? { ...initialStreamingState };
        const next = applyStreamEvent(base, event);
        if (next.status === "done") {
          // Will be cleaned up after message is appended
          setTimeout(() => setStreaming(null), 0);
        }
        return next;
      });

      if (event.kind === "message_start") {
        setInputDisabled(true);
        setStreaming({ ...initialStreamingState });
      }
    },

    pushToolUpdate(update) {
      setStreaming((prev) => {
        const base = prev ?? { ...initialStreamingState };
        return applyToolUpdate(base, update);
      });
    },

    onMessageAppended(message: Message) {
      setMessages((prev) => [...prev, message]);
      if (message.role === "assistant") {
        setStreaming(null);
        setInputDisabled(false);
      }
    },
  });

  // Fire onReady once after mount
  useEffect(() => {
    onReady?.(handleRef.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ---------------------------------------------------------------------------
  // Submit handler
  // ---------------------------------------------------------------------------
  const handleSubmit = useCallback(
    async (text: string) => {
      setInputDisabled(true);
      // Optimistically add user message to display
      const userMsg: Message = { role: "user", content: [{ type: "text", text }] };
      setMessages((prev) => [...prev, userMsg]);
      try {
        await send(text);
      } catch {
        setInputDisabled(false);
        setStreaming(null);
      }
    },
    [send]
  );

  // ---------------------------------------------------------------------------
  // Render
  // ---------------------------------------------------------------------------
  return (
    <Box flexDirection="column" width={columns}>
      <TopBar
        sessionId={session.meta.id}
        model={session.meta.model}
        cwd={session.meta.cwd}
        columns={columns}
      />

      {greeting != null && greeting.length > 0 && (
        <Box paddingX={1}>
          <Text color={theme.system}>{greeting}</Text>
        </Box>
      )}

      <Box flexDirection="column" flexGrow={1} paddingX={1}>
        <MessageList
          messages={messages}
          streaming={streaming}
          showThinking={showThinking}
        />
      </Box>

      <Box paddingX={1}>
        <UserInput onSubmit={handleSubmit} disabled={inputDisabled} />
      </Box>

      <BottomHint columns={columns} />
    </Box>
  );
}

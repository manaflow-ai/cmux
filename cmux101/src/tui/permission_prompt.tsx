/**
 * PermissionPrompt — overlay component shown when a tool requires interactive
 * approval. Captures a single keystroke and resolves the pending promise.
 */
import React from "react";
import { Box, Text, useInput } from "ink";
import { theme } from "./theme.js";

export type PermissionAnswer = "yes" | "no" | "yes-session" | "yes-always";

export interface PermissionPromptProps {
  toolName: string;
  input: unknown;
  onAnswer: (answer: PermissionAnswer) => void;
}

function prettyInput(input: unknown): string {
  try {
    const s = JSON.stringify(input, null, 2);
    if (s.length <= 500) return s;
    return s.slice(0, 497) + "...";
  } catch {
    return String(input);
  }
}

export function PermissionPrompt({ toolName, input, onAnswer }: PermissionPromptProps) {
  useInput((char, key) => {
    if (char === "y") {
      onAnswer("yes");
    } else if (char === "s") {
      onAnswer("yes-session");
    } else if (char === "a") {
      onAnswer("yes-always");
    } else if (char === "n" || key.escape) {
      onAnswer("no");
    }
  });

  const inputStr = prettyInput(input);

  return (
    <Box
      borderStyle="double"
      borderColor={theme.accent}
      flexDirection="column"
      paddingX={2}
      paddingY={1}
    >
      <Text color={theme.accent} bold>
        Permission required
      </Text>
      <Box marginTop={1}>
        <Text color={theme.toolName}>Tool: </Text>
        <Text color="white">{toolName}</Text>
      </Box>
      <Box marginTop={1} flexDirection="column">
        <Text color={theme.dim}>Input:</Text>
        <Text color={theme.assistant}>{inputStr}</Text>
      </Box>
      <Box marginTop={1} flexDirection="column">
        <Text color={theme.dim}>─────────────────────────</Text>
        <Text>
          <Text color="green">y</Text>
          <Text color={theme.dim}> yes (once)   </Text>
          <Text color="cyan">s</Text>
          <Text color={theme.dim}> yes (session)   </Text>
          <Text color="yellow">a</Text>
          <Text color={theme.dim}> yes (always)   </Text>
          <Text color="red">n</Text>
          <Text color={theme.dim}>/Esc no</Text>
        </Text>
      </Box>
    </Box>
  );
}

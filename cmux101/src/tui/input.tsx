/**
 * UserInput — text entry bar with optional slash-command autocomplete.
 *
 * Limitation (v1): Single-line only. ink-text-input does not natively support
 * multi-line; Shift+Enter would require raw PTY manipulation. A future version
 * can swap in a custom multi-line editor component.
 */
import React, { useState } from "react";
import { Box, Text, useInput } from "ink";
import TextInput from "ink-text-input";
import { theme } from "./theme.js";

export interface UserInputProps {
  onSubmit: (text: string) => void;
  disabled?: boolean;
  /** Optional list of slash-command names (without the leading "/"). */
  commands?: string[];
}

export function UserInput({ onSubmit, disabled = false, commands = [] }: UserInputProps) {
  const [value, setValue] = useState("");
  const [submitted, setSubmitted] = useState(false);

  // Derive autocomplete suggestions
  const suggestions: string[] =
    value.startsWith("/") && commands.length > 0
      ? commands
          .filter((cmd) => ("/" + cmd).startsWith(value))
          .slice(0, 5)
      : [];

  function handleSubmit(text: string) {
    if (disabled || text.trim().length === 0) return;
    setSubmitted(true);
    onSubmit(text.trim());
    setValue("");
    setSubmitted(false);
  }

  const promptColor = disabled ? theme.dim : theme.user;

  return (
    <Box flexDirection="column">
      {/* Autocomplete suggestions */}
      {suggestions.length > 0 && (
        <Box flexDirection="column" marginBottom={0}>
          {suggestions.map((cmd) => (
            <Text key={cmd} color={theme.accent}>
              /{cmd}
            </Text>
          ))}
        </Box>
      )}

      {/* Input row */}
      <Box>
        <Text color={promptColor} bold>
          {"▶ "}
        </Text>
        {disabled ? (
          <Text color={theme.dim}>{value || "(waiting...)"}</Text>
        ) : (
          <TextInput
            value={value}
            onChange={setValue}
            onSubmit={handleSubmit}
            placeholder="Type a message…"
          />
        )}
      </Box>
    </Box>
  );
}

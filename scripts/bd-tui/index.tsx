#!/usr/bin/env bun
import React, { useState, useEffect, useMemo } from "react";
import { render, Box, Text, useInput, useApp } from "ink";
import TextInput from "ink-text-input";
import { z } from "zod";
import { $ } from "bun";

// Check for TTY support before proceeding
if (!process.stdin.isTTY) {
  console.error("Error: bd-tui requires an interactive terminal (TTY).");
  console.error("Run this command directly in your terminal, not through pipes or scripts.");
  process.exit(1);
}

// Schema for beads issues
const IssueSchema = z.object({
  id: z.string(),
  title: z.string(),
  description: z.string().optional(),
  status: z.enum(["open", "in_progress", "blocked", "deferred", "closed"]),
  priority: z.number().min(0).max(4),
  issue_type: z.string(),
  labels: z.array(z.string()).default([]),
  created_at: z.string(),
  updated_at: z.string().optional(),
  closed_at: z.string().optional(),
  assignee: z.string().optional(),
});

type Issue = z.infer<typeof IssueSchema>;

const STATUS_ORDER: Issue["status"][] = [
  "in_progress",
  "open",
  "blocked",
  "deferred",
  "closed",
];

const STATUS_COLORS: Record<Issue["status"], string> = {
  in_progress: "cyan",
  open: "green",
  blocked: "red",
  deferred: "gray",
  closed: "gray",
};

const STATUS_ICONS: Record<Issue["status"], string> = {
  in_progress: "●",
  open: "○",
  blocked: "✖",
  deferred: "◌",
  closed: "✓",
};

const PRIORITY_COLORS: Record<number, string> = {
  0: "red",
  1: "yellow",
  2: "white",
  3: "gray",
  4: "gray",
};

interface FetchResult {
  issues: Issue[];
  error: string | null;
}

async function fetchIssues(): Promise<FetchResult> {
  try {
    const result = await $`bd list --json`.quiet();
    const raw = JSON.parse(result.stdout.toString());
    return { issues: z.array(IssueSchema).parse(raw), error: null };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    // Extract just the stderr if it's a ShellError
    const stderrMatch = message.match(/stderr: "([^"]+)"/);
    const cleanError = stderrMatch?.[1] ?? message;
    return { issues: [], error: cleanError };
  }
}

function getUniqueLabels(issues: Issue[]): string[] {
  const labelSet = new Set<string>();
  for (const issue of issues) {
    for (const label of issue.labels) {
      labelSet.add(label);
    }
  }
  return Array.from(labelSet).sort();
}

interface IssueRowProps {
  issue: Issue;
  isSelected: boolean;
  isExpanded: boolean;
}

function IssueRow({ issue, isSelected, isExpanded }: IssueRowProps) {
  const statusColor = STATUS_COLORS[issue.status];
  const priorityColor = PRIORITY_COLORS[issue.priority];
  const icon = STATUS_ICONS[issue.status];

  return (
    <Box flexDirection="column">
      <Box>
        <Text color={isSelected ? "blue" : undefined} bold={isSelected}>
          {isSelected ? "▶ " : "  "}
        </Text>
        <Text color={statusColor}>{icon} </Text>
        <Text color={priorityColor}>P{issue.priority} </Text>
        <Text color="gray">[{issue.id}] </Text>
        <Text color={isSelected ? "white" : undefined} bold={isSelected}>
          {issue.title.slice(0, 60)}
          {issue.title.length > 60 ? "..." : ""}
        </Text>
        {issue.labels.length > 0 && (
          <Text color="magenta"> ({issue.labels.join(", ")})</Text>
        )}
      </Box>
      {isExpanded && issue.description && (
        <Box marginLeft={4} marginTop={0} marginBottom={1}>
          <Text color="gray" wrap="wrap">
            {issue.description.slice(0, 200)}
            {issue.description.length > 200 ? "..." : ""}
          </Text>
        </Box>
      )}
    </Box>
  );
}

interface StatusGroupProps {
  status: Issue["status"];
  issues: Issue[];
  selectedId: string | null;
  expandedId: string | null;
  collapsed: boolean;
}

function StatusGroup({
  status,
  issues,
  selectedId,
  expandedId,
  collapsed,
}: StatusGroupProps) {
  if (issues.length === 0) return null;

  const statusColor = STATUS_COLORS[status];
  const icon = STATUS_ICONS[status];

  return (
    <Box flexDirection="column" marginBottom={1}>
      <Box>
        <Text color={statusColor} bold>
          {icon} {status.toUpperCase().replace("_", " ")} ({issues.length})
          {collapsed ? " [collapsed]" : ""}
        </Text>
      </Box>
      {!collapsed && (
        <Box flexDirection="column" marginLeft={2}>
          {issues.map((issue) => (
            <IssueRow
              key={issue.id}
              issue={issue}
              isSelected={issue.id === selectedId}
              isExpanded={issue.id === expandedId}
            />
          ))}
        </Box>
      )}
    </Box>
  );
}

interface HelpBarProps {
  mode: "normal" | "search" | "label";
}

function HelpBar({ mode }: HelpBarProps) {
  if (mode === "search") {
    return (
      <Box borderStyle="single" borderColor="gray" paddingX={1}>
        <Text color="gray">
          Type to search • <Text color="yellow">Enter</Text> confirm •{" "}
          <Text color="yellow">Esc</Text> cancel
        </Text>
      </Box>
    );
  }

  if (mode === "label") {
    return (
      <Box borderStyle="single" borderColor="gray" paddingX={1}>
        <Text color="gray">
          <Text color="yellow">↑/↓</Text> select •{" "}
          <Text color="yellow">Enter</Text> filter •{" "}
          <Text color="yellow">a</Text> show all •{" "}
          <Text color="yellow">Esc</Text> cancel
        </Text>
      </Box>
    );
  }

  return (
    <Box borderStyle="single" borderColor="gray" paddingX={1}>
      <Text color="gray">
        <Text color="yellow">↑/↓/j/k</Text> navigate •{" "}
        <Text color="yellow">Enter</Text> expand •{" "}
        <Text color="yellow">/</Text> search •{" "}
        <Text color="yellow">l</Text> filter label •{" "}
        <Text color="yellow">c</Text> toggle closed •{" "}
        <Text color="yellow">r</Text> refresh •{" "}
        <Text color="yellow">q</Text> quit
      </Text>
    </Box>
  );
}

interface LabelPickerProps {
  labels: string[];
  selectedIndex: number;
  currentLabel: string | null;
}

function LabelPicker({ labels, selectedIndex, currentLabel }: LabelPickerProps) {
  return (
    <Box
      flexDirection="column"
      borderStyle="single"
      borderColor="magenta"
      paddingX={1}
      marginBottom={1}
    >
      <Text color="magenta" bold>
        Select Label (Branch):
      </Text>
      <Box flexDirection="column" marginTop={1}>
        <Box>
          <Text color={selectedIndex === -1 ? "blue" : "gray"} bold={selectedIndex === -1}>
            {selectedIndex === -1 ? "▶ " : "  "}
          </Text>
          <Text color={currentLabel === null ? "green" : "white"}>
            (all labels)
          </Text>
        </Box>
        {labels.map((label, idx) => (
          <Box key={label}>
            <Text color={selectedIndex === idx ? "blue" : "gray"} bold={selectedIndex === idx}>
              {selectedIndex === idx ? "▶ " : "  "}
            </Text>
            <Text color={currentLabel === label ? "green" : "white"}>
              {label}
            </Text>
          </Box>
        ))}
      </Box>
    </Box>
  );
}

function App() {
  const { exit } = useApp();
  const [issues, setIssues] = useState<Issue[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [activeSearch, setActiveSearch] = useState("");
  const [selectedLabel, setSelectedLabel] = useState<string | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [showClosed, setShowClosed] = useState(false);
  const [mode, setMode] = useState<"normal" | "search" | "label">("normal");
  const [labelPickerIndex, setLabelPickerIndex] = useState(-1);

  const labels = useMemo(() => getUniqueLabels(issues), [issues]);

  const filteredIssues = useMemo(() => {
    let result = issues;

    // Filter by label
    if (selectedLabel) {
      result = result.filter((i) => i.labels.includes(selectedLabel));
    }

    // Filter by search
    if (activeSearch) {
      const query = activeSearch.toLowerCase();
      result = result.filter(
        (i) =>
          i.title.toLowerCase().includes(query) ||
          i.id.toLowerCase().includes(query) ||
          i.description?.toLowerCase().includes(query)
      );
    }

    // Filter closed
    if (!showClosed) {
      result = result.filter((i) => i.status !== "closed");
    }

    return result;
  }, [issues, selectedLabel, activeSearch, showClosed]);

  const groupedIssues = useMemo(() => {
    const groups: Record<Issue["status"], Issue[]> = {
      in_progress: [],
      open: [],
      blocked: [],
      deferred: [],
      closed: [],
    };

    for (const issue of filteredIssues) {
      groups[issue.status].push(issue);
    }

    // Sort each group by priority
    for (const status of STATUS_ORDER) {
      groups[status].sort((a, b) => a.priority - b.priority);
    }

    return groups;
  }, [filteredIssues]);

  const flatList = useMemo(() => {
    const result: Issue[] = [];
    for (const status of STATUS_ORDER) {
      if (status === "closed" && !showClosed) continue;
      result.push(...groupedIssues[status]);
    }
    return result;
  }, [groupedIssues, showClosed]);

  useEffect(() => {
    fetchIssues().then((result) => {
      setIssues(result.issues);
      setError(result.error);
      setLoading(false);
      if (result.issues.length > 0) {
        // Select first non-closed issue
        const first = result.issues.find((i) => i.status !== "closed");
        if (first) setSelectedId(first.id);
      }
    });
  }, []);

  const refresh = async () => {
    setLoading(true);
    setError(null);
    const result = await fetchIssues();
    setIssues(result.issues);
    setError(result.error);
    setLoading(false);
  };

  useInput((input, key) => {
    if (mode === "search") {
      if (key.escape) {
        setMode("normal");
        setSearchQuery("");
      } else if (key.return) {
        setActiveSearch(searchQuery);
        setMode("normal");
      }
      return;
    }

    if (mode === "label") {
      if (key.escape) {
        setMode("normal");
      } else if (key.return) {
        if (labelPickerIndex === -1) {
          setSelectedLabel(null);
        } else {
          setSelectedLabel(labels[labelPickerIndex] ?? null);
        }
        setMode("normal");
      } else if (key.upArrow || input === "k") {
        setLabelPickerIndex((prev) => Math.max(-1, prev - 1));
      } else if (key.downArrow || input === "j") {
        setLabelPickerIndex((prev) => Math.min(labels.length - 1, prev + 1));
      } else if (input === "a") {
        setSelectedLabel(null);
        setMode("normal");
      }
      return;
    }

    // Normal mode
    if (input === "q") {
      exit();
    } else if (input === "/") {
      setMode("search");
      setSearchQuery(activeSearch);
    } else if (input === "l") {
      setMode("label");
      setLabelPickerIndex(selectedLabel ? labels.indexOf(selectedLabel) : -1);
    } else if (input === "c") {
      setShowClosed((prev) => !prev);
    } else if (input === "r") {
      refresh();
    } else if (key.return) {
      setExpandedId((prev) => (prev === selectedId ? null : selectedId));
    } else if (key.upArrow || input === "k") {
      const currentIdx = flatList.findIndex((i) => i.id === selectedId);
      if (currentIdx > 0) {
        setSelectedId(flatList[currentIdx - 1]?.id ?? null);
      }
    } else if (key.downArrow || input === "j") {
      const currentIdx = flatList.findIndex((i) => i.id === selectedId);
      if (currentIdx < flatList.length - 1) {
        setSelectedId(flatList[currentIdx + 1]?.id ?? null);
      }
    }
  });

  if (loading) {
    return (
      <Box flexDirection="column" padding={1}>
        <Text color="cyan">Loading issues...</Text>
      </Box>
    );
  }

  if (error && issues.length === 0) {
    return (
      <Box flexDirection="column" padding={1}>
        <Text color="red" bold>
          Error loading issues:
        </Text>
        <Text color="red">{error}</Text>
        <Box marginTop={1}>
          <Text color="gray">
            Press <Text color="yellow">r</Text> to retry or{" "}
            <Text color="yellow">q</Text> to quit
          </Text>
        </Box>
      </Box>
    );
  }

  return (
    <Box flexDirection="column" padding={1}>
      {/* Header */}
      <Box marginBottom={1}>
        <Text color="cyan" bold>
          ━━━ Beads Issue Tracker ━━━
        </Text>
        {error && (
          <Text color="red"> (Error: {error.slice(0, 50)}...)</Text>
        )}
      </Box>

      {/* Filter status bar */}
      <Box marginBottom={1}>
        <Text color="gray">
          Showing {filteredIssues.length} of {issues.length} issues
          {selectedLabel && (
            <Text color="magenta"> • Label: {selectedLabel}</Text>
          )}
          {activeSearch && <Text color="yellow"> • Search: "{activeSearch}"</Text>}
          {showClosed && <Text color="gray"> • Including closed</Text>}
        </Text>
      </Box>

      {/* Search input */}
      {mode === "search" && (
        <Box marginBottom={1}>
          <Text color="yellow">Search: </Text>
          <TextInput
            value={searchQuery}
            onChange={setSearchQuery}
            showCursor
          />
        </Box>
      )}

      {/* Label picker */}
      {mode === "label" && (
        <LabelPicker
          labels={labels}
          selectedIndex={labelPickerIndex}
          currentLabel={selectedLabel}
        />
      )}

      {/* Issue groups */}
      <Box flexDirection="column" flexGrow={1}>
        {STATUS_ORDER.filter((status) => status !== "closed" || showClosed).map(
          (status) => (
            <StatusGroup
              key={`status-group-${status}`}
              status={status}
              issues={groupedIssues[status]}
              selectedId={selectedId}
              expandedId={expandedId}
              collapsed={false}
            />
          )
        )}
      </Box>

      {/* Help bar */}
      <HelpBar mode={mode} />
    </Box>
  );
}

render(<App />);

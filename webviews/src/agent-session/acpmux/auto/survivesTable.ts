// RFD 0080 "What survives what": the table the Computer panel shows, as data. Each cell is a value
// (what happens) and an optional note key (the RFD's short reason, in the person's words, no vendor
// or machine-type names). Only a "kept" cell is a promise; every other value says what is not.
import type { StringKey } from "../i18n";

export const SURVIVES_EVENTS = [
  "pause_wake",
  "resize_up",
  "resize_down",
  "move",
  "cloud_lost",
  "agent_deleted",
] as const;
export type SurvivesEvent = (typeof SURVIVES_EVENTS)[number];

export const SURVIVES_COLUMNS = ["project_files", "other_files", "processes", "chat"] as const;
export type SurvivesColumn = (typeof SURVIVES_COLUMNS)[number];

export const SURVIVES_VALUES = ["kept", "not_carried", "lost", "restarted", "kept_to_snapshot"] as const;
export type SurvivesValue = (typeof SURVIVES_VALUES)[number];

export type SurvivesCell = { value: SurvivesValue; note?: StringKey };
export type SurvivesRow = { event: SurvivesEvent; cells: Record<SurvivesColumn, SurvivesCell> };

const kept: SurvivesCell = { value: "kept" };

export const SURVIVES_ROWS: readonly SurvivesRow[] = [
  {
    event: "pause_wake",
    cells: {
      project_files: kept,
      other_files: kept,
      processes: { value: "kept", note: "computerPanel.survives.pause_wake.processes" },
      chat: kept,
    },
  },
  {
    event: "resize_up",
    cells: {
      project_files: kept,
      other_files: kept,
      processes: { value: "kept", note: "computerPanel.survives.resize_up.processes" },
      chat: kept,
    },
  },
  {
    event: "resize_down",
    cells: {
      project_files: { value: "kept", note: "computerPanel.survives.resize_down.project_files" },
      other_files: { value: "not_carried" },
      processes: { value: "lost", note: "computerPanel.survives.resize_down.processes" },
      chat: kept,
    },
  },
  {
    event: "move",
    cells: {
      project_files: { value: "kept", note: "computerPanel.survives.move.project_files" },
      other_files: { value: "not_carried" },
      processes: { value: "restarted", note: "computerPanel.survives.move.processes" },
      chat: kept,
    },
  },
  {
    event: "cloud_lost",
    cells: {
      project_files: { value: "kept_to_snapshot", note: "computerPanel.survives.cloud_lost.project_files" },
      other_files: { value: "kept_to_snapshot" },
      processes: { value: "lost" },
      chat: { value: "lost", note: "computerPanel.survives.cloud_lost.chat" },
    },
  },
  {
    event: "agent_deleted",
    cells: {
      project_files: { value: "lost", note: "computerPanel.survives.agent_deleted.trash" },
      other_files: { value: "lost" },
      processes: { value: "lost" },
      chat: { value: "lost", note: "computerPanel.survives.agent_deleted.trash" },
    },
  },
];

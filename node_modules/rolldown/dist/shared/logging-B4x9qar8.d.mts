//#region src/log/logging.d.ts
type LogLevel = "info" | "debug" | "warn";
type LogLevelOption = LogLevel | "silent";
type LogLevelWithError = LogLevel | "error";
interface RollupLog {
  binding?: string;
  cause?: unknown;
  code?: string;
  exporter?: string;
  frame?: string;
  hook?: string;
  id?: string;
  ids?: string[];
  loc?: {
    column: number;
    file?: string;
    line: number;
  };
  message: string;
  meta?: any;
  names?: string[];
  plugin?: string;
  pluginCode?: unknown;
  pos?: number;
  reexporter?: string;
  stack?: string;
  url?: string;
}
type RollupLogWithString = RollupLog | string;
/** @category Plugin APIs */
interface RollupError extends RollupLog {
  name?: string;
  stack?: string;
  watchFiles?: string[];
}
type LogOrStringHandler = (level: LogLevelWithError, log: RollupLogWithString) => void;
//#endregion
export { RollupLog as a, RollupError as i, LogLevelOption as n, RollupLogWithString as o, LogOrStringHandler as r, LogLevel as t };
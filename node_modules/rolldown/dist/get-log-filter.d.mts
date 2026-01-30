import { a as RollupLog } from "./shared/logging-B4x9qar8.mjs";

//#region src/get-log-filter.d.ts
type GetLogFilter = (filters: string[]) => (log: RollupLog) => boolean;
declare const getLogFilter: GetLogFilter;
//#endregion
export { GetLogFilter, type RollupLog, getLogFilter as default };
// What every Chief Usage design draws from: the loaded summary, the grouping it was asked for and
// the page's strings. The page header (window, grouping, Refresh) is the page's, not the design's.
import type { Strings } from "../../shared/i18n";
import type { UsageBy, UsageSummary } from "../types";

export interface DesignProps {
  summary: UsageSummary;
  by: UsageBy;
  strings: Strings;
}

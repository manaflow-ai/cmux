import type { ReactNode } from "react";
import { AccentRowEditor } from "./AccentRowEditor";
import { ChoiceOrNumberEditor } from "./ChoiceOrNumberEditor";
import { ChoiceOrUrlEditor } from "./ChoiceOrUrlEditor";
import { ChoiceSetEditor } from "./ChoiceSetEditor";
import { ColorEditor } from "./ColorEditor";
import { DomainListEditor } from "./DomainListEditor";
import { ChatRootsEditor } from "./ChatRootsEditor";
import { FolderListEditor } from "./FolderListEditor";
import { HostListEditor } from "./HostListEditor";
import { MenuEditor } from "./MenuEditor";
import { NumberEditor } from "./NumberEditor";
import { DurationEditor, isDuration } from "./DurationEditor";
import { NumberListEditor } from "./NumberListEditor";
import { OrderedChoicesEditor } from "./OrderedChoicesEditor";
import { SegmentedEditor } from "./SegmentedEditor";
import { SoundEditor } from "./SoundEditor";
import { StringMapEditor } from "./StringMapEditor";
import { TextEditor } from "./TextEditor";
import { ThemeRowEditor } from "./ThemeRowEditor";
import { TimeRangeEditor } from "./TimeRangeEditor";
import { ToggleEditor } from "./ToggleEditor";
import { SearchTemplateEditor } from "./SearchTemplateEditor";
import { UrlEditor } from "./UrlEditor";
import type { SchemaRow } from "../schema";
import { text } from "../strings";
import type { EditorProps } from "./types";

const ACCENT_KEY = "appearance.accent";

/** The longest label a segment may hold, and the most all of a row's segments may hold, in
 * characters of the shown (localized) titles. Longer labels wrapped inside their segments ("Keep
 * Sessions / Running", Lucas 2026-11-11), so such a row is a menu, as ChatGPT's settings are. */
const SEGMENT_LABEL_MAX = 12;
const SEGMENTS_TOTAL_MAX = 28;

/** Whether a choice row draws segments: up to three short choices and a non-null default. */
export function fitsSegments(row: SchemaRow): boolean {
  const choices = row.choices ?? [];
  if (choices.length === 0 || choices.length > 3 || row.default === null) return false;
  const lengths = choices.map((choice) => text(choice.title).length);
  return Math.max(...lengths) <= SEGMENT_LABEL_MAX && lengths.reduce((sum, n) => sum + n, 0) <= SEGMENTS_TOTAL_MAX;
}

/** The editor for a row's kind. Every kind in the schema has one (editors.test.tsx). */
export function Editor(props: EditorProps): ReactNode {
  const { row } = props;
  switch (row.kind) {
    case "toggle":
      return <ToggleEditor {...props} />;
    case "choice":
      // The accent is a swatch popup like the Theme section's, wherever it shows.
      if (row.key === ACCENT_KEY) return <AccentRowEditor {...props} />;
      return fitsSegments(row) ? <SegmentedEditor {...props} /> : <MenuEditor {...props} />;
    case "choice_or_number":
      return <ChoiceOrNumberEditor {...props} />;
    case "choice_or_url":
      return <ChoiceOrUrlEditor {...props} />;
    case "number":
      // A time row with a wide range is a menu of durations; a slider would park its value at the start.
      return isDuration(row) ? <DurationEditor {...props} /> : <NumberEditor {...props} />;
    case "color":
      return <ColorEditor {...props} />;
    case "theme":
      // The Theme section's picker, wherever a theme row shows (search results).
      return <ThemeRowEditor {...props} />;
    case "font_family":
      return <DomainListEditor {...props} />;
    case "sound":
      return <SoundEditor {...props} />;
    case "text":
      return <TextEditor {...props} />;
    case "url":
      return row.validation === "domain:search_template" ? (
        <SearchTemplateEditor {...props} />
      ) : (
        <UrlEditor {...props} />
      );
    case "host_list":
      return <HostListEditor {...props} />;
    case "folder_list":
      return row.key === "agents.chats.roots" ? <ChatRootsEditor {...props} /> : <FolderListEditor {...props} />;
    case "time_range":
      return <TimeRangeEditor {...props} />;
    case "string_list":
      // A list of fixed choices in an order the user picks (sidebar.workspaceRow.secondLineOrder),
      // any subset of fixed choices (browser.toolbarButtons), else free-text tokens
      // (browser.urlsToAlwaysOpenExternally).
      if (!row.choices) return <HostListEditor {...props} />;
      return row.ordered === false ? <ChoiceSetEditor {...props} /> : <OrderedChoicesEditor {...props} />;
    case "number_list":
      return <NumberListEditor {...props} />;
    case "string_map":
      // A site per line with its engine (browser.siteEngines); appearance.themeEdits never shows as a row.
      return <StringMapEditor {...props} />;
  }
}

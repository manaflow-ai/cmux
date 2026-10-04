import type { ReactNode } from "react";
import { ChoiceOrNumberEditor } from "./ChoiceOrNumberEditor";
import { ColorEditor } from "./ColorEditor";
import { DomainListEditor } from "./DomainListEditor";
import { HostListEditor } from "./HostListEditor";
import { MenuEditor } from "./MenuEditor";
import { NumberEditor } from "./NumberEditor";
import { SegmentedEditor } from "./SegmentedEditor";
import { SoundEditor } from "./SoundEditor";
import { TimeRangeEditor } from "./TimeRangeEditor";
import { ToggleEditor } from "./ToggleEditor";
import { UrlEditor } from "./UrlEditor";
import type { EditorProps } from "./types";

/** The editor for a row's kind. Every kind in the schema has one (editors.test.tsx). */
export function Editor(props: EditorProps): ReactNode {
  const { row } = props;
  switch (row.kind) {
    case "toggle":
      return <ToggleEditor {...props} />;
    case "choice":
      return (row.choices?.length ?? 0) <= 3 && row.default !== null ? (
        <SegmentedEditor {...props} />
      ) : (
        <MenuEditor {...props} />
      );
    case "choice_or_number":
      return <ChoiceOrNumberEditor {...props} />;
    case "number":
      return <NumberEditor {...props} />;
    case "color":
      return <ColorEditor {...props} />;
    case "theme":
    case "font_family":
      return <DomainListEditor {...props} />;
    case "sound":
      return <SoundEditor {...props} />;
    case "url":
      return <UrlEditor {...props} />;
    case "host_list":
      return <HostListEditor {...props} />;
    case "folder_list":
      // picker.pinned (R89): the React UIs lead builds this editor; until
      // then the row shows its title and help with no control.
      return null;
    case "time_range":
      return <TimeRangeEditor {...props} />;
  }
}

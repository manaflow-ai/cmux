// l10n-allow-file: gallery fixtures, not shipped UI.
// The edited-files card's settings (agentPane.editedFiles.show, maxRows, scope) in Settings >
// General > Agent Chat: the defaults, and changed values as cmux.json would set them.
import { settingsPageEntry } from "../../../gallery/format";

export default settingsPageEntry({
  id: "agent-pane.edited-files-settings",
  title: "Edited files card settings",
  area: "Settings",
  height: 760,
  covers: ["page:cmux.settings"],
  variants: {
    defaults: {
      note: "Always, 5 rows, each turn: the defaults.",
      section: "general",
      focus: "agentPane.editedFiles.show",
    },
    changed: {
      note: "Collapsed, 12 rows, the whole chat.",
      section: "general",
      focus: "agentPane.editedFiles.show",
      options: {
        values: {
          "agentPane.editedFiles.show": "collapsed",
          "agentPane.editedFiles.maxRows": 12,
          "agentPane.editedFiles.scope": "session",
        },
      },
    },
  },
});

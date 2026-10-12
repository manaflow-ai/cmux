// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../gallery/format";
import { TaskCheckbox, type TaskCheckboxProps } from "./TaskCheckbox";

type Props = TaskCheckboxProps & { taskList?: boolean; label?: string };

function TaskCheckboxGallery({ checked, className, taskList, label = "Task list item" }: Props) {
  const checkbox = <TaskCheckbox checked={checked} className={className} />;
  if (!taskList) return checkbox;
  return (
    <ul style={{ listStyle: "none", margin: 0, padding: 0 }}>
      <li style={{ alignItems: "center", display: "flex", gap: 8 }}>
        {checkbox}
        <span>{label}</span>
      </li>
    </ul>
  );
}

export default componentEntry<Props>({
  id: "ui.task-checkbox",
  title: "Task checkbox",
  area: "Pages",
  covers: ["ui/TaskCheckbox.tsx#TaskCheckbox"],
  load: async () => TaskCheckboxGallery,
  styles: () => import("../markdown-task-checkbox.css"),
  variants: {
    checked: { note: "Checked task checkbox with a crisp check mark.", props: { checked: true } },
    unchecked: { note: "Unchecked task checkbox with a quiet theme border.", props: { checked: false } },
    "read-only": { note: "Read-only checkbox semantics from the shared primitive.", props: { checked: true } },
    "task-list": {
      note: "Checkbox aligned with text in a task-list row.",
      props: { checked: true, taskList: true },
    },
  },
});

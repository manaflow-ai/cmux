# Process sharing experiment

Task Manager already reports one row per operating-system process. A process can serve more than one
cmux surface, such as the shared Chromium renderer in the normal fixture. The experiment makes that
relationship legible without changing process ownership or termination rules.

The `process-sharing` experiment has two arms.

- `off` is the shipped default. It preserves the current table, labels, selection, and Kill Process
  behavior byte-for-byte.
- `shared` keeps the same rows and actions, while prefixing a task label that names multiple surfaces
  with `Shared:`. The row carries `data-shared-process="true"` so the gallery and screenshot harness can
  capture the state without adding a permanent badge to the default UI.

The Labs setting `experiments.process_sharing` is off by default. It is the host-level opt-in for this
experiment. Browser galleries can compare arms directly through the existing `cmux.experiments` override.

## Gallery states

`pages.task-manager` includes the existing empty, first-sample, normal, many-row, selected, remote, and
long-name states. Its experiment entry makes the `off` and `shared` arms available in the gallery compare
view over the same normal fixture. Capture both arms at the same width to compare the task column and
verify that selection and the kill affordance remain unchanged.

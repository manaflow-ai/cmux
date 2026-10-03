# Notice: code copied from a private reference repository

Parts of this directory were copied from a private Manaflow reference
repository and then changed here. The copied code is
mainly in `conversation/` and `changes/`, plus the transcript, turn and
edited-files card code that came with them. Copy commits: bf60795ae57,
0ee808b0d41, 32f3ea4677e, dbccdf79dc6, fabc08bb57e, 164bb7260e0, 8a44d9210e3,
684abfd7838, 2680d650442.

License record (spec decision S7, 2026-10-01):

- The reference repository has no LICENSE file. Lawrence Chen (GitHub
  `lawrencecchen`) is the author of all 74 of its commits (2026-10-01, last
  commit 7aae264b083). It contains no third-party source in the copied
  directories.
- Its author licenses the copied code to this repository under the cmux
  project license: GPL-3.0-or-later (see the LICENSE file at the repository
  root). Copyright: Manaflow, Inc. and Lawrence Chen.
- cmux does not depend on the reference repository: there is no package
  dependency and no submodule. Third-party libraries that the copied code uses
  (for example the Apache-2.0 diff and tree libraries) keep their own licenses
  through `webviews/package.json`.

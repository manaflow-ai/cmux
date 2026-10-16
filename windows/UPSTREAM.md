# Windows implementation provenance

The initial Windows implementation is adapted from Nikku's open upstream
[PR #5049](https://github.com/manaflow-ai/cmux/pull/5049), commit
`69a959f123e975a9acb24bdcc17647d2ca1f2a2e`, from
[`imthegoodboy/cmux-window`](https://github.com/imthegoodboy/cmux-window).

Original author: Nikku <nikku696969@gmail.com>. Preserve this attribution and
include `Co-authored-by: Nikku <nikku696969@gmail.com>` in commits that incorporate
or adapt this implementation. Only the `windows/` subtree was imported; upstream
workflow and release changes were not imported.

The Windows UI uses Electron, xterm.js and Windows ConPTY. It does not execute
Apple's SwiftUI runtime. Visual matching is tracked separately from functional
support; a working terminal does not establish Ghostty rendering parity.

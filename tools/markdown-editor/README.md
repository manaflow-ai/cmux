# Markdown Editor Bundle

This builds the bundled CodeMirror 6 editor used by Markdown panels.

```bash
cd tools/markdown-editor
npm install
npm run build
```

The build output is checked in at `Resources/markdown-editor/editor.bundle.js`
so cmux does not need npm or network access at app build time.

// KaTeX's stylesheet, imported with KaTeX itself (Math.tsx) so a chat without math never loads
// it. The dev server adds it as it loads; the pane's bundle makes it a chunk that adds a <style>
// with the fonts inlined (scripts/agent-pane/katexStylePlugin.mjs).
import "katex/dist/katex.min.css";

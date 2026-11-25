// The rest of the agent pane's stylesheet (vite.config.guest-page.mjs): the transcript's rows, code
// and diffs. main.tsx loads it beside the transcript's chunk; the bundler puts this module's CSS in its
// own file and resolves the import once that file has loaded, so no row draws unstyled.
import "virtual:cmux-guest/transcript.css";

// l10n-allow-file: the tour prompt goes to the agent; it is not UI.
// What Take the tour sends (tourModel.ts says what the agent does with it).

/// The fence a tour reply comes in.
export const TOUR_FENCE = "cmux-tour";
/// The tour prompt's first line: what the person's sent bubble shows of it (UserBubble.tsx).
export const TOUR_ASK = "Give me a short tour of this repository.";

/// The prompt Take the tour sends.
export const TOUR_PROMPT = [
  TOUR_ASK,
  "",
  "Read only: change, create or delete no file except the one cache file `<common-dir>/cmux-tour/<HEAD>.md` (and its folder) below. Run no install, build or test.",
  "1. Run `git rev-parse HEAD` and `git rev-parse --git-common-dir`. If `<common-dir>/cmux-tour/<HEAD>.md` exists, reply with its contents exactly and stop.",
  "2. Otherwise look at the README, the manifests and the top-level layout (a few minutes at most). Reply with one ```" +
    TOUR_FENCE +
    " fenced block holding one JSON object and nothing else:",
  '{"head": HEAD\'s sha, "summary": what the project is in one or two sentences, "modules": up to 8 of {"path": "./path/from/the/root", "about": one short line}, "run": up to 4 of {"command": a shell command, "about": one short line}, "tasks": exactly 3 good first tasks of {"title": at most 8 words, "prompt": a self-contained instruction another agent can start from}}',
  "3. Save that same fenced block to `<common-dir>/cmux-tour/<HEAD>.md`, so the next tour of this commit is instant.",
  'Not a git repository: skip steps 1 and 3 and use "head": null.',
].join("\n");

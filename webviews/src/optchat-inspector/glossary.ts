// Plain explanations for every OptChat term the page shows (hover or focus a dotted word).
export const GLOSSARY = {
  turn: "One answer by Chief: a fresh model session that reads the system prompt, the view and the new messages, then works and replies.",
  view: "What the model reads every turn instead of the whole chat: the entire chat as one line per tree node, oldest first, at most 128 KB. Recent messages get their own line; older ones share a line.",
  node: "One summary in the memory tree. Its name id+n means it covers n messages starting at message id. A one-message node is the message itself when it is short (under 512 bytes), else a summary of it.",
  level:
    "How coarse a node is. A level L node covers 2^L messages. Level 0 is single messages; each level up joins two neighbors into one summary.",
  zoom: "The agent's tool zoom(id, n): it opens line id+n into the two lines of n/2 messages it was made from. zoom(id, 1) gives message id in full. Click any line to do the same.",
  date: "The agent's tool date(id): the date and time message id was written.",
  settle:
    "No turn starts until every view line is a real summary. Settling is the wait for the compactor to write the summaries the view needs.",
  fold: "When the view grows past its budget, two neighboring old lines are replaced by their parent node (one line covering both). The oldest lines for their size go first. A folded line never splits again.",
  compactor:
    "Background model calls that write each node's summary (at most 512 bytes). Short messages need no call: they are their own node.",
  mark: "Cache marks: at about 50k, 80k and 100k characters into the view, each moved back to the end of a line. In the cached layout the view up to the first mark goes into the system prompt.",
  grid: "Cuts every 4,096 characters, at a line end. After the first mark the view is sent as one block per grid piece, so an unchanged start keeps the same blocks next turn.",
  marker:
    "Our cache breakpoint: Chief puts one cache_control on the last stable view block. The harness adds its own breakpoints on the system prompt and the last message.",
  cache:
    "First request of the turn: tokens read from the prompt cache (cheap and fast), tokens written into it (a prefix seen for the first time), and tokens sent uncached.",
  unchanged:
    "Bytes at the start of this view that are identical to the previous turn's view: the part a prompt cache can reuse.",
  placeholder:
    '"(not summarized yet: zoom it)": a line whose summary is not built yet. A turn never starts while one is in the view.',
  exact:
    "The page rebuilt this prompt from the trace and the memory, and the trace's hashes match: these are the bytes the turn sent.",
  layout:
    "Cached: the system prompt holds the view's first 50k, then view blocks with one marker, then the messages (Claude harnesses). Blocks: view pieces then messages (other harnesses).",
} as const;

export type Term = keyof typeof GLOSSARY;

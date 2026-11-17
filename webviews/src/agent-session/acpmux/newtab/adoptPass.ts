// Whether the page is inside an adopt event's own synchronous pass (adoption.ts useSessionAdoption:
// a prewarmed spare page taking a chat, `flushSync(onAdopt)`). That pass is the task before the
// adopted chat's first frame, so what it draws is only what that frame shows: the transcript mounts
// the rows in view there and the rest in a render after it (VirtualTranscript `adoptPass`).

let depth = 0;

/// True while an adopt event's synchronous pass renders.
export function inAdoptPass(): boolean {
  return depth > 0;
}

/// Runs `pass` (the adopt's flushSync) marked as the adopt pass.
export function runAdoptPass(pass: () => void): void {
  depth += 1;
  try {
    pass();
  } finally {
    depth -= 1;
  }
}

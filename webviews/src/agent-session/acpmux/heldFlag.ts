// The `try`s the composer needs, kept out of its components: the React Compiler does not compile a
// function with a `try` that has no `catch` or holds a condition, and leaves the whole component
// uncompiled (every render then re-creates every child's props).

/// Sets `flag.current` to `value`, runs `run`, then sets it back to false.
export function holdFlag(flag: { current: boolean }, value: boolean, run: () => void): void {
  flag.current = value;
  try {
    run();
  } finally {
    flag.current = false;
  }
}

/// Points `ref` (a callback ref or a ref object a component was given) at `value`. Kept out of
/// components for the same reason: the compiler treats a prop or a hook's result as read-only, and a
/// component that writes `.current` on one stays uncompiled.
export function setRef<T>(ref: React.Ref<T> | undefined, value: T | null): void {
  if (typeof ref === "function") ref(value);
  else if (ref) (ref as React.RefObject<T | null>).current = value;
}

/// Runs `resume`; `failed` when it answers false or throws.
export async function resumeOrFail(resume: () => Promise<void | boolean>, failed: () => void): Promise<void> {
  try {
    if ((await resume()) === false) failed();
  } catch {
    failed();
  }
}

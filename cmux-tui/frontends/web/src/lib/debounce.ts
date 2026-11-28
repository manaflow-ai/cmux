export interface Debounced<T extends unknown[]> {
  (...args: T): void;
  cancel(): void;
}

export function debounce<T extends unknown[]>(callback: (...args: T) => void, delayMs: number): Debounced<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const debounced = (...args: T) => {
    if (timer !== undefined) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = undefined;
      callback(...args);
    }, delayMs);
  };
  debounced.cancel = () => {
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
  };
  return debounced;
}

// A pointer press as WebKit delivers it to a button, for the popover-trigger tests: pointerdown,
// then mousedown, whose default moves focus off the focused element (WebKit never focuses a
// clicked button), then mouseup and click.
type TestWindow = Window & typeof globalThis;

export async function webKitPress(
  win: TestWindow,
  act: (run: () => Promise<void>) => Promise<void>,
  target: Element,
): Promise<void> {
  const Pointer = (win as { PointerEvent?: typeof MouseEvent }).PointerEvent ?? win.MouseEvent;
  await act(async () => {
    target.dispatchEvent(new Pointer("pointerdown", { bubbles: true, cancelable: true }));
  });
  await act(async () => {
    const down = new win.MouseEvent("mousedown", { bubbles: true, cancelable: true });
    target.dispatchEvent(down);
    const focused = win.document.activeElement;
    if (!down.defaultPrevented && focused instanceof win.HTMLElement) focused.blur();
  });
  await act(async () => {
    target.dispatchEvent(new win.MouseEvent("mouseup", { bubbles: true, cancelable: true }));
    target.dispatchEvent(new win.MouseEvent("click", { bubbles: true, cancelable: true }));
  });
}

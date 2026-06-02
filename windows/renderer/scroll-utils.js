export function attachHorizontalWheelScroll(element) {
  if (!element) return () => {};
  const onWheel = (event) => {
    if (event.ctrlKey || element.scrollWidth <= element.clientWidth) return;
    const delta = event.deltaX || event.deltaY;
    if (!delta) return;
    event.preventDefault();
    element.scrollLeft += delta;
  };
  element.addEventListener("wheel", onWheel, { passive: false });
  return () => element.removeEventListener("wheel", onWheel);
}

export function scrollChildIntoView(container, child, options = {}) {
  if (!container || !child) return false;
  const containerRect = container.getBoundingClientRect();
  const childRect = child.getBoundingClientRect();
  const inset = Number(options.inset) || 0;
  let delta = 0;
  if (childRect.left < containerRect.left + inset) {
    delta = childRect.left - containerRect.left - inset;
  } else if (childRect.right > containerRect.right - inset) {
    delta = childRect.right - containerRect.right + inset;
  }
  if (!delta) return false;
  container.scrollTo({
    left: container.scrollLeft + delta,
    behavior: options.smooth ? "smooth" : "auto"
  });
  return true;
}

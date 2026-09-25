export type FooterCollapseItem = {
  canHideLabel: boolean;
  compactWidth: number;
  enabled: boolean;
  expandedWidth: number;
  hasMeasuredCompactWidth: boolean;
  id: string;
};

export type FooterCollapseItemState = {
  hideControl: boolean;
  hideLabel: boolean;
};

export type FooterCollapseState = Record<string, FooterCollapseItemState>;

export function initialFooterCollapseState(
  items: ReadonlyArray<Pick<FooterCollapseItem, "id">>,
): FooterCollapseState {
  const state: FooterCollapseState = {};
  for (const item of items) {
    state[item.id] = { hideControl: false, hideLabel: false };
  }
  return state;
}

export function computeFooterCollapse(input: {
  availableWidth: number;
  gap: number;
  items: ReadonlyArray<FooterCollapseItem>;
  previousState: FooterCollapseState;
}): FooterCollapseState {
  const enabledItems = input.items.filter((item) => item.enabled);
  const nextState = initialFooterCollapseState(input.items);
  if (enabledItems.length === 0 || input.availableWidth <= 0) {
    return nextState;
  }

  const totalExpandedWidth = enabledItems.reduce((total, item) => total + item.expandedWidth, 0) +
    input.gap * Math.max(0, enabledItems.length - 1);
  if (totalExpandedWidth <= 0) {
    return nextState;
  }

  let requiredWidth = totalExpandedWidth;
  for (const item of enabledItems) {
    if (!item.canHideLabel || input.availableWidth >= requiredWidth) {
      continue;
    }
    nextState[item.id].hideLabel = true;
    requiredWidth -= item.expandedWidth - item.compactWidth;
  }

  if (hasFooterCollapseStateChanged(nextState, input.previousState, "hideLabel")) {
    return nextState;
  }

  let visibleCount = enabledItems.length;
  for (const item of enabledItems) {
    const state = nextState[item.id];
    const width = state.hideLabel ? item.compactWidth : item.expandedWidth;
    if ((state.hideLabel && !item.hasMeasuredCompactWidth) || input.availableWidth < requiredWidth) {
      state.hideControl = true;
      requiredWidth -= width + (visibleCount > 1 ? input.gap : 0);
      visibleCount -= 1;
    }
  }

  return nextState;
}

export function footerCollapseStatesEqual(a: FooterCollapseState, b: FooterCollapseState): boolean {
  const aKeys = Object.keys(a);
  const bKeys = Object.keys(b);
  if (aKeys.length !== bKeys.length) {
    return false;
  }
  for (const key of aKeys) {
    if (a[key]?.hideControl !== b[key]?.hideControl || a[key]?.hideLabel !== b[key]?.hideLabel) {
      return false;
    }
  }
  return true;
}

function hasFooterCollapseStateChanged(
  a: FooterCollapseState,
  b: FooterCollapseState,
  property: keyof FooterCollapseItemState,
): boolean {
  const keys = Object.keys(a);
  if (keys.length !== Object.keys(b).length) {
    return true;
  }
  return keys.some((key) => a[key]?.[property] !== b[key]?.[property]);
}

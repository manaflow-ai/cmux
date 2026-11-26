import { expect, test } from "bun:test";
import {
  computeFooterCollapse,
  initialFooterCollapseState,
  type FooterCollapseItem,
} from "./footerCollapse";

const items: FooterCollapseItem[] = [
  {
    canHideLabel: false,
    compactWidth: 88,
    enabled: true,
    expandedWidth: 88,
    hasMeasuredCompactWidth: true,
    id: "model-provider",
  },
  {
    canHideLabel: true,
    compactWidth: 36,
    enabled: true,
    expandedWidth: 84,
    hasMeasuredCompactWidth: true,
    id: "intelligence",
  },
  {
    canHideLabel: true,
    compactWidth: 30,
    enabled: true,
    expandedWidth: 92,
    hasMeasuredCompactWidth: true,
    id: "ide-context",
  },
];

test("footer collapse keeps controls expanded when they fit", () => {
  expect(computeFooterCollapse({
    availableWidth: 280,
    gap: 4,
    items,
    previousState: initialFooterCollapseState(items),
  })).toEqual({
    "model-provider": { hideControl: false, hideLabel: false },
    intelligence: { hideControl: false, hideLabel: false },
    "ide-context": { hideControl: false, hideLabel: false },
  });
});

test("footer collapse hides labels before controls", () => {
  const previousState = initialFooterCollapseState(items);
  const labelPass = computeFooterCollapse({
    availableWidth: 230,
    gap: 4,
    items,
    previousState,
  });
  expect(labelPass).toEqual({
    "model-provider": { hideControl: false, hideLabel: false },
    intelligence: { hideControl: false, hideLabel: true },
    "ide-context": { hideControl: false, hideLabel: false },
  });

  expect(computeFooterCollapse({
    availableWidth: 230,
    gap: 4,
    items,
    previousState: labelPass,
  })).toEqual(labelPass);
});

test("footer collapse hides controls in order after compact measurement", () => {
  const previousState = computeFooterCollapse({
    availableWidth: 150,
    gap: 4,
    items,
    previousState: initialFooterCollapseState(items),
  });
  expect(computeFooterCollapse({
    availableWidth: 150,
    gap: 4,
    items,
    previousState,
  })).toEqual({
    "model-provider": { hideControl: true, hideLabel: false },
    intelligence: { hideControl: false, hideLabel: true },
    "ide-context": { hideControl: false, hideLabel: true },
  });
});

test("footer collapse waits for compact measurement before deciding final controls", () => {
  const unmeasured: FooterCollapseItem[] = [
    {
      canHideLabel: true,
      compactWidth: 100,
      enabled: true,
      expandedWidth: 100,
      hasMeasuredCompactWidth: false,
      id: "intelligence",
    },
  ];
  const labelPass = computeFooterCollapse({
    availableWidth: 80,
    gap: 4,
    items: unmeasured,
    previousState: initialFooterCollapseState(unmeasured),
  });
  expect(labelPass.intelligence).toEqual({ hideControl: false, hideLabel: true });

  expect(computeFooterCollapse({
    availableWidth: 80,
    gap: 4,
    items: unmeasured,
    previousState: labelPass,
  }).intelligence).toEqual({ hideControl: true, hideLabel: true });
});

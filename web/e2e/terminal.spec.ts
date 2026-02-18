import { test, expect, type Page, type Locator } from "@playwright/test"

// ─── Helpers ───────────────────────────────────────────────────────────────

/** All surface placeholders (one per visible group) */
function surfaces(page: Page) {
  return page.locator("[data-testid^='surface-']")
}

/** The focused group's surface */
function focusedSurface(page: Page) {
  return page.locator("[data-testid^='surface-'][data-focused='true']")
}

/** All group containers */
function groups(page: Page) {
  return page.locator("[data-testid^='group-s']")
}

/** The focused group container */
function focusedGroup(page: Page) {
  return page.locator("[data-group-focused='true']")
}

/** All group tab bars */
function groupTabBars(page: Page) {
  return page.locator("[data-testid^='group-tab-bar-']")
}

/** All tabs across all groups */
function allTabs(page: Page) {
  return page.locator("[data-testid^='tab-s']")
}

/** Tabs in the focused group */
function tabsInFocusedGroup(page: Page) {
  return focusedGroup(page).locator("[data-testid^='tab-s']")
}

/** Active tab in the focused group */
function activeTabInFocusedGroup(page: Page) {
  return focusedGroup(page).locator("[data-testid^='tab-s'][data-active='true']")
}

/** Add tab button in the focused group */
function addTabBtn(page: Page) {
  return focusedGroup(page).locator("[data-testid^='add-tab-button-']")
}

function splitRight(page: Page) {
  return page.getByTestId("btn-split-right")
}

function splitDown(page: Page) {
  return page.getByTestId("btn-split-down")
}

function closeBtn(page: Page) {
  return page.getByTestId("btn-close-pane")
}

function equalizeBtn(page: Page) {
  return page.getByTestId("btn-equalize")
}

function dividers(page: Page) {
  return page.locator("[data-testid^='divider-']")
}

function dragGhost(page: Page) {
  return page.getByTestId("drag-ghost")
}

function dropIndicators(page: Page) {
  return page.locator("[data-testid^='drop-indicator-']")
}

function tabDropIndicator(page: Page) {
  return page.getByTestId("tab-drop-indicator")
}

/** Get the center of an element */
async function center(loc: Locator): Promise<{ x: number; y: number }> {
  const box = await loc.boundingBox()
  return { x: box!.x + box!.width / 2, y: box!.y + box!.height / 2 }
}

/** Perform a drag from (sx,sy) to (tx,ty) with intermediate steps */
async function drag(
  page: Page,
  sx: number,
  sy: number,
  tx: number,
  ty: number,
  opts?: { steps?: number; hold?: boolean },
) {
  const steps = opts?.steps ?? 10
  await page.mouse.move(sx, sy)
  await page.mouse.down()
  await page.mouse.move(tx, ty, { steps })
  if (!opts?.hold) {
    await page.mouse.up()
  }
}

// ─── Tests ─────────────────────────────────────────────────────────────────

test.beforeEach(async ({ page }) => {
  // Use ?shell=local to skip PTY connections — windowing tests don't need real PTY
  await page.goto("/terminal?shell=local")
  await expect(surfaces(page).first()).toBeVisible()
})

test.describe("Initial state", () => {
  test("renders with one group, one tab bar, one tab, one surface, focused", async ({ page }) => {
    await expect(groups(page)).toHaveCount(1)
    await expect(groupTabBars(page)).toHaveCount(1)
    await expect(allTabs(page)).toHaveCount(1)
    await expect(surfaces(page)).toHaveCount(1)
    await expect(focusedSurface(page)).toHaveCount(1)
    await expect(dividers(page)).toHaveCount(0)
  })
})

test.describe("Tab operations within a group", () => {
  test("add tab creates a new tab in the focused group", async ({ page }) => {
    await addTabBtn(page).click()
    // Still one group, one surface
    await expect(groups(page)).toHaveCount(1)
    await expect(surfaces(page)).toHaveCount(1)
    // But now 2 tabs in that group
    await expect(tabsInFocusedGroup(page)).toHaveCount(2)
    await expect(allTabs(page)).toHaveCount(2)
  })

  test("select tab within group switches active tab", async ({ page }) => {
    await addTabBtn(page).click()
    await expect(tabsInFocusedGroup(page)).toHaveCount(2)

    // Click first tab
    const firstTab = tabsInFocusedGroup(page).first()
    await firstTab.click()
    await expect(firstTab).toHaveAttribute("data-active", "true")

    // Click second tab
    const secondTab = tabsInFocusedGroup(page).nth(1)
    await secondTab.click()
    await expect(secondTab).toHaveAttribute("data-active", "true")
    await expect(firstTab).toHaveAttribute("data-active", "false")
  })

  test("close tab within group removes it", async ({ page }) => {
    await addTabBtn(page).click()
    await addTabBtn(page).click()
    await expect(tabsInFocusedGroup(page)).toHaveCount(3)

    // Close the active (third) tab
    const activeTabEl = activeTabInFocusedGroup(page)
    const tabId = await activeTabEl.getAttribute("data-testid")
    const rawId = tabId!.replace("tab-", "")
    await page.getByTestId(`tab-close-${rawId}`).click()

    await expect(tabsInFocusedGroup(page)).toHaveCount(2)
  })

  test("close last tab in only group is a no-op", async ({ page }) => {
    // Only one group with one tab — close should do nothing
    await closeBtn(page).click()
    await expect(groups(page)).toHaveCount(1)
    await expect(surfaces(page)).toHaveCount(1)
    await expect(allTabs(page)).toHaveCount(1)
  })

  test("close last tab in group removes the group when other groups exist", async ({ page }) => {
    // Split to create 2 groups
    await splitRight(page).click()
    await expect(groups(page)).toHaveCount(2)

    // Close (Cmd+W equivalent) — closes active tab, which is the only tab in the focused group
    await closeBtn(page).click()
    await expect(groups(page)).toHaveCount(1)
    await expect(surfaces(page)).toHaveCount(1)
  })
})

test.describe("Split operations", () => {
  test("split right creates horizontal split with new group", async ({ page }) => {
    await splitRight(page).click()
    await expect(groups(page)).toHaveCount(2)
    await expect(surfaces(page)).toHaveCount(2)
    await expect(groupTabBars(page)).toHaveCount(2)
    await expect(dividers(page)).toHaveCount(1)
    const divider = dividers(page).first()
    await expect(divider).toHaveAttribute("data-direction", "horizontal")
  })

  test("split down creates vertical split with new group", async ({ page }) => {
    await splitDown(page).click()
    await expect(groups(page)).toHaveCount(2)
    await expect(surfaces(page)).toHaveCount(2)
    await expect(dividers(page)).toHaveCount(1)
    const divider = dividers(page).first()
    await expect(divider).toHaveAttribute("data-direction", "vertical")
  })

  test("Cmd+D splits right", async ({ page }) => {
    await page.keyboard.press("Meta+d")
    await expect(groups(page)).toHaveCount(2)
    await expect(dividers(page)).toHaveCount(1)
    const divider = dividers(page).first()
    await expect(divider).toHaveAttribute("data-direction", "horizontal")
  })

  test("Cmd+Shift+D splits down", async ({ page }) => {
    await page.keyboard.press("Meta+Shift+d")
    await expect(groups(page)).toHaveCount(2)
    await expect(dividers(page)).toHaveCount(1)
    const divider = dividers(page).first()
    await expect(divider).toHaveAttribute("data-direction", "vertical")
  })

  test("new group from split receives focus", async ({ page }) => {
    const firstSurface = surfaces(page).first()
    const firstId = await firstSurface.getAttribute("data-testid")

    await splitRight(page).click()

    // Focused surface should be the NEW one
    const focused = focusedSurface(page)
    const focusedId = await focused.getAttribute("data-testid")
    expect(focusedId).not.toBe(firstId)
  })

  test("each group has its own tab bar with one tab", async ({ page }) => {
    await splitRight(page).click()
    await expect(groupTabBars(page)).toHaveCount(2)
    // Each group should have exactly 1 tab
    await expect(allTabs(page)).toHaveCount(2)
  })

  test("multiple splits create multiple groups", async ({ page }) => {
    await splitRight(page).click()
    await splitDown(page).click()
    await splitRight(page).click()
    await splitDown(page).click()

    await expect(groups(page)).toHaveCount(5)
    await expect(surfaces(page)).toHaveCount(5)
    await expect(dividers(page)).toHaveCount(4)
  })

  test("deeply nested splits (5 levels)", async ({ page }) => {
    for (let i = 0; i < 5; i++) {
      await splitRight(page).click()
    }
    await expect(groups(page)).toHaveCount(6)
    await expect(surfaces(page)).toHaveCount(6)
    await expect(dividers(page)).toHaveCount(5)
  })
})

test.describe("Close group", () => {
  test("close removes group and its divider", async ({ page }) => {
    await splitRight(page).click()
    await expect(groups(page)).toHaveCount(2)
    await expect(dividers(page)).toHaveCount(1)

    // Focus is on new group, close it
    await closeBtn(page).click()
    await expect(groups(page)).toHaveCount(1)
    await expect(dividers(page)).toHaveCount(0)
  })

  test("close group moves focus to adjacent group", async ({ page }) => {
    await splitRight(page).click()
    await splitRight(page).click()
    // 3 groups, focus on last
    await expect(groups(page)).toHaveCount(3)

    await closeBtn(page).click()
    // Now 2 groups, focus should be on adjacent
    await expect(groups(page)).toHaveCount(2)
    await expect(focusedSurface(page)).toHaveCount(1)
  })
})

test.describe("Focus", () => {
  test("click surface to focus group", async ({ page }) => {
    await splitRight(page).click()
    // Focus is on new right group
    const leftSurface = surfaces(page).first()
    await leftSurface.click()
    // Left surface should now be focused
    await expect(leftSurface).toHaveAttribute("data-focused", "true")
  })

  test("only one group focused at a time", async ({ page }) => {
    await splitRight(page).click()
    await splitDown(page).click()
    // 3 groups total
    await expect(groups(page)).toHaveCount(3)
    await expect(focusedSurface(page)).toHaveCount(1)

    // Click different surfaces
    const allSurfaces = surfaces(page)
    await allSurfaces.nth(0).click()
    await expect(focusedSurface(page)).toHaveCount(1)
    await expect(allSurfaces.nth(0)).toHaveAttribute("data-focused", "true")

    await allSurfaces.nth(1).click()
    await expect(focusedSurface(page)).toHaveCount(1)
    await expect(allSurfaces.nth(1)).toHaveAttribute("data-focused", "true")
    await expect(allSurfaces.nth(0)).toHaveAttribute("data-focused", "false")
  })

  test("Cmd+Ctrl+H moves focus left", async ({ page }) => {
    await splitRight(page).click()
    // Focus is on the right pane
    const rightSurface = surfaces(page).nth(1)
    await expect(rightSurface).toHaveAttribute("data-focused", "true")
    // Move focus left
    await page.keyboard.press("Meta+Control+h")
    await expect(surfaces(page).nth(0)).toHaveAttribute("data-focused", "true")
  })

  test("Cmd+Ctrl+L moves focus right", async ({ page }) => {
    await splitRight(page).click()
    // Focus on right; click left to focus it
    await surfaces(page).nth(0).click()
    await expect(surfaces(page).nth(0)).toHaveAttribute("data-focused", "true")
    // Move focus right
    await page.keyboard.press("Meta+Control+l")
    await expect(surfaces(page).nth(1)).toHaveAttribute("data-focused", "true")
  })

  test("Cmd+Ctrl+J moves focus down", async ({ page }) => {
    await splitDown(page).click()
    // Focus on bottom; click top to focus it
    await surfaces(page).nth(0).click()
    await expect(surfaces(page).nth(0)).toHaveAttribute("data-focused", "true")
    // Move focus down
    await page.keyboard.press("Meta+Control+j")
    await expect(surfaces(page).nth(1)).toHaveAttribute("data-focused", "true")
  })

  test("Cmd+Ctrl+K moves focus up", async ({ page }) => {
    await splitDown(page).click()
    // Focus is on the bottom pane
    await expect(surfaces(page).nth(1)).toHaveAttribute("data-focused", "true")
    // Move focus up
    await page.keyboard.press("Meta+Control+k")
    await expect(surfaces(page).nth(0)).toHaveAttribute("data-focused", "true")
  })
})

test.describe("Equalize", () => {
  test("equalize resets split ratios to 50/50", async ({ page }) => {
    await splitRight(page).click()

    // Drag divider to make it unequal
    const divider = dividers(page).first()
    const splitArea = page.getByTestId("split-area")
    const areaBox = await splitArea.boundingBox()
    const divBox = await divider.boundingBox()

    if (areaBox && divBox) {
      const startX = divBox.x + divBox.width / 2
      const startY = divBox.y + divBox.height / 2
      const targetX = areaBox.x + areaBox.width * 0.3
      await page.mouse.move(startX, startY)
      await page.mouse.down()
      await page.mouse.move(targetX, startY, { steps: 5 })
      await page.mouse.up()
    }

    // Verify left pane is smaller now
    const leftGroup = groups(page).first()
    const leftBox = await leftGroup.boundingBox()
    const rightGroup = groups(page).nth(1)
    const rightBox = await rightGroup.boundingBox()
    if (leftBox && rightBox) {
      expect(leftBox.width).toBeLessThan(rightBox.width)
    }

    // Equalize
    await equalizeBtn(page).click()

    // After equalize, both groups should be roughly equal width
    const newLeftBox = await leftGroup.boundingBox()
    const newRightBox = await rightGroup.boundingBox()
    if (newLeftBox && newRightBox) {
      const diff = Math.abs(newLeftBox.width - newRightBox.width)
      expect(diff).toBeLessThan(20)
    }
  })
})

test.describe("Divider drag resize", () => {
  test("horizontal divider drag changes group widths", async ({ page }) => {
    await splitRight(page).click()

    const divider = dividers(page).first()
    const splitArea = page.getByTestId("split-area")
    const areaBox = await splitArea.boundingBox()
    const divBox = await divider.boundingBox()

    expect(areaBox).not.toBeNull()
    expect(divBox).not.toBeNull()

    const leftGroup = groups(page).first()
    const initialLeftBox = await leftGroup.boundingBox()
    expect(initialLeftBox).not.toBeNull()

    // Drag divider to the right by 100px
    const startX = divBox!.x + divBox!.width / 2
    const startY = divBox!.y + divBox!.height / 2
    await page.mouse.move(startX, startY)
    await page.mouse.down()
    await page.mouse.move(startX + 100, startY, { steps: 5 })
    await page.mouse.up()

    const newLeftBox = await leftGroup.boundingBox()
    expect(newLeftBox).not.toBeNull()
    expect(newLeftBox!.width).toBeGreaterThan(initialLeftBox!.width + 50)
  })

  test("vertical divider drag changes group heights", async ({ page }) => {
    await splitDown(page).click()

    const divider = dividers(page).first()
    const divBox = await divider.boundingBox()
    expect(divBox).not.toBeNull()

    const topGroup = groups(page).first()
    const initialTopBox = await topGroup.boundingBox()
    expect(initialTopBox).not.toBeNull()

    // Drag divider down by 80px
    const startX = divBox!.x + divBox!.width / 2
    const startY = divBox!.y + divBox!.height / 2
    await page.mouse.move(startX, startY)
    await page.mouse.down()
    await page.mouse.move(startX, startY + 80, { steps: 5 })
    await page.mouse.up()

    const newTopBox = await topGroup.boundingBox()
    expect(newTopBox).not.toBeNull()
    expect(newTopBox!.height).toBeGreaterThan(initialTopBox!.height + 40)
  })

  test("divider drag clamped to min 10% ratio", async ({ page }) => {
    await splitRight(page).click()

    const divider = dividers(page).first()
    const splitArea = page.getByTestId("split-area")
    const areaBox = await splitArea.boundingBox()
    const divBox = await divider.boundingBox()

    const startX = divBox!.x + divBox!.width / 2
    const startY = divBox!.y + divBox!.height / 2
    await page.mouse.move(startX, startY)
    await page.mouse.down()
    await page.mouse.move(areaBox!.x + areaBox!.width * 0.02, startY, { steps: 5 })
    await page.mouse.up()

    const leftGroup = groups(page).first()
    const leftBox = await leftGroup.boundingBox()
    const minWidth = areaBox!.width * 0.08
    expect(leftBox!.width).toBeGreaterThanOrEqual(minWidth)
  })

  test("divider drag clamped to max 90% ratio", async ({ page }) => {
    await splitRight(page).click()

    const divider = dividers(page).first()
    const splitArea = page.getByTestId("split-area")
    const areaBox = await splitArea.boundingBox()
    const divBox = await divider.boundingBox()

    const startX = divBox!.x + divBox!.width / 2
    const startY = divBox!.y + divBox!.height / 2
    await page.mouse.move(startX, startY)
    await page.mouse.down()
    await page.mouse.move(areaBox!.x + areaBox!.width * 0.98, startY, { steps: 5 })
    await page.mouse.up()

    const rightGroup = groups(page).nth(1)
    const rightBox = await rightGroup.boundingBox()
    const minWidth = areaBox!.width * 0.08
    expect(rightBox!.width).toBeGreaterThanOrEqual(minWidth)
  })

  test("drag divider in nested split", async ({ page }) => {
    await splitRight(page).click()
    await splitDown(page).click()
    // 3 groups: left | top-right / bottom-right
    await expect(groups(page)).toHaveCount(3)
    await expect(dividers(page)).toHaveCount(2)

    const vertDivider = page.locator(
      "[data-testid^='divider-'][data-direction='vertical']",
    )
    await expect(vertDivider).toHaveCount(1)

    const divBox = await vertDivider.boundingBox()
    expect(divBox).not.toBeNull()

    const topRight = groups(page).nth(1)
    const initialBox = await topRight.boundingBox()

    const startX = divBox!.x + divBox!.width / 2
    const startY = divBox!.y + divBox!.height / 2
    await page.mouse.move(startX, startY)
    await page.mouse.down()
    await page.mouse.move(startX, startY + 60, { steps: 5 })
    await page.mouse.up()

    const newBox = await topRight.boundingBox()
    expect(newBox!.height).toBeGreaterThan(initialBox!.height + 30)
  })
})

test.describe("Edge cases", () => {
  test("rapid split and close operations", async ({ page }) => {
    for (let i = 0; i < 5; i++) {
      await splitRight(page).click()
    }
    await expect(groups(page)).toHaveCount(6)

    for (let i = 0; i < 5; i++) {
      await closeBtn(page).click()
    }
    await expect(groups(page)).toHaveCount(1)
    await expect(dividers(page)).toHaveCount(0)
  })

  test("alternating horizontal and vertical splits", async ({ page }) => {
    await splitRight(page).click()
    await splitDown(page).click()
    await splitRight(page).click()
    await splitDown(page).click()

    await expect(groups(page)).toHaveCount(5)
    await expect(dividers(page)).toHaveCount(4)

    const hDividers = page.locator(
      "[data-testid^='divider-'][data-direction='horizontal']",
    )
    const vDividers = page.locator(
      "[data-testid^='divider-'][data-direction='vertical']",
    )
    await expect(hDividers).toHaveCount(2)
    await expect(vDividers).toHaveCount(2)
  })

  test("single group can't be fully removed", async ({ page }) => {
    // Closing on the only group should be a no-op
    await closeBtn(page).click()
    await expect(groups(page)).toHaveCount(1)
    await expect(surfaces(page)).toHaveCount(1)
  })

  test("groups have non-zero dimensions", async ({ page }) => {
    await splitRight(page).click()
    await splitDown(page).click()

    const allGroups = groups(page)
    const count = await allGroups.count()
    for (let i = 0; i < count; i++) {
      const box = await allGroups.nth(i).boundingBox()
      expect(box).not.toBeNull()
      expect(box!.width).toBeGreaterThan(10)
      expect(box!.height).toBeGreaterThan(10)
    }
  })
})

test.describe("Divider drag to end-of-area and pane regions", () => {
  test("dragging past the end of the split area clamps correctly", async ({ page }) => {
    await splitRight(page).click()

    const divider = dividers(page).first()
    const splitArea = page.getByTestId("split-area")
    const areaBox = await splitArea.boundingBox()
    const divBox = await divider.boundingBox()

    const startX = divBox!.x + divBox!.width / 2
    const startY = divBox!.y + divBox!.height / 2
    await page.mouse.move(startX, startY)
    await page.mouse.down()
    await page.mouse.move(areaBox!.x + areaBox!.width + 100, startY, { steps: 5 })
    await page.mouse.up()

    const rightGroup = groups(page).nth(1)
    const rightBox = await rightGroup.boundingBox()
    expect(rightBox).not.toBeNull()
    expect(rightBox!.width).toBeGreaterThan(0)
  })

  test("dragging past the left edge clamps correctly", async ({ page }) => {
    await splitRight(page).click()

    const divider = dividers(page).first()
    const splitArea = page.getByTestId("split-area")
    const areaBox = await splitArea.boundingBox()
    const divBox = await divider.boundingBox()

    const startX = divBox!.x + divBox!.width / 2
    const startY = divBox!.y + divBox!.height / 2
    await page.mouse.move(startX, startY)
    await page.mouse.down()
    await page.mouse.move(areaBox!.x - 100, startY, { steps: 5 })
    await page.mouse.up()

    const leftGroup = groups(page).first()
    const leftBox = await leftGroup.boundingBox()
    expect(leftBox).not.toBeNull()
    expect(leftBox!.width).toBeGreaterThan(0)
  })

  test("drag vertical divider past top and bottom edges", async ({ page }) => {
    await splitDown(page).click()

    const divider = dividers(page).first()
    const splitArea = page.getByTestId("split-area")
    const areaBox = await splitArea.boundingBox()

    // Drag past bottom
    let divBox = await divider.boundingBox()
    await page.mouse.move(divBox!.x + divBox!.width / 2, divBox!.y + divBox!.height / 2)
    await page.mouse.down()
    await page.mouse.move(
      divBox!.x + divBox!.width / 2,
      areaBox!.y + areaBox!.height + 100,
      { steps: 5 },
    )
    await page.mouse.up()

    const bottomGroup = groups(page).nth(1)
    let bottomBox = await bottomGroup.boundingBox()
    expect(bottomBox!.height).toBeGreaterThan(0)

    // Drag past top
    divBox = await divider.boundingBox()
    await page.mouse.move(divBox!.x + divBox!.width / 2, divBox!.y + divBox!.height / 2)
    await page.mouse.down()
    await page.mouse.move(divBox!.x + divBox!.width / 2, areaBox!.y - 100, { steps: 5 })
    await page.mouse.up()

    const topGroup = groups(page).first()
    const topBox = await topGroup.boundingBox()
    expect(topBox!.height).toBeGreaterThan(0)
  })
})

// ─── Tab Drag and Drop Tests ──────────────────────────────────────────────

test.describe("Tab drag - ghost follows cursor", () => {
  test("dragging a tab shows ghost element", async ({ page }) => {
    // Add a second tab to the group
    await addTabBtn(page).click()
    await expect(tabsInFocusedGroup(page)).toHaveCount(2)

    // Start drag on a tab
    const tab = tabsInFocusedGroup(page).first()
    const tabCenter = await center(tab)

    await page.mouse.move(tabCenter.x, tabCenter.y)
    await page.mouse.down()
    await page.mouse.move(tabCenter.x + 20, tabCenter.y + 20, { steps: 5 })

    await expect(dragGhost(page)).toBeVisible()
    await page.mouse.up()
  })

  test("ghost follows cursor position during drag", async ({ page }) => {
    await addTabBtn(page).click()

    const tab = tabsInFocusedGroup(page).first()
    const tabCenter = await center(tab)

    await page.mouse.move(tabCenter.x, tabCenter.y)
    await page.mouse.down()
    await page.mouse.move(tabCenter.x + 50, tabCenter.y + 100, { steps: 5 })

    const ghost = dragGhost(page)
    await expect(ghost).toBeVisible()

    await page.mouse.move(400, 300, { steps: 3 })
    const ghostBox = await ghost.boundingBox()
    expect(ghostBox).not.toBeNull()
    const ghostCenterX = ghostBox!.x + ghostBox!.width / 2
    const ghostCenterY = ghostBox!.y + ghostBox!.height / 2
    expect(Math.abs(ghostCenterX - 400)).toBeLessThan(30)
    expect(Math.abs(ghostCenterY - 300)).toBeLessThan(30)

    await page.mouse.up()
    await expect(ghost).not.toBeVisible()
  })

  test("ghost disappears on mouse up", async ({ page }) => {
    await addTabBtn(page).click()

    const tab = tabsInFocusedGroup(page).first()
    const tabCenter = await center(tab)

    await page.mouse.move(tabCenter.x, tabCenter.y)
    await page.mouse.down()
    await page.mouse.move(tabCenter.x + 30, tabCenter.y + 30, { steps: 5 })
    await expect(dragGhost(page)).toBeVisible()

    await page.mouse.up()
    await expect(dragGhost(page)).not.toBeVisible()
  })

  test("click without drag does not show ghost", async ({ page }) => {
    await addTabBtn(page).click()
    const tab = tabsInFocusedGroup(page).nth(1)
    const tabCenter = await center(tab)

    await page.mouse.move(tabCenter.x, tabCenter.y)
    await page.mouse.down()
    await page.mouse.up()
    await expect(dragGhost(page)).not.toBeVisible()
  })
})

test.describe("Tab drag - drop on surface creates split", () => {
  test("drop indicator appears when hovering over surface", async ({ page }) => {
    // Split to get 2 groups, add a tab to the focused group
    await splitRight(page).click()
    await addTabBtn(page).click()
    await expect(tabsInFocusedGroup(page)).toHaveCount(2)

    // Drag a tab from focused group to a surface
    const tab = tabsInFocusedGroup(page).first()
    const tabCenter = await center(tab)
    // Drag to the left group's surface
    const leftSurface = surfaces(page).first()
    const surfaceCenter = await center(leftSurface)

    await page.mouse.move(tabCenter.x, tabCenter.y)
    await page.mouse.down()
    await page.mouse.move(surfaceCenter.x, surfaceCenter.y, { steps: 10 })

    await expect(dropIndicators(page)).toHaveCount(1)
    await page.mouse.up()
  })

  test("drop indicator shows correct direction based on cursor position", async ({ page }) => {
    await splitRight(page).click()
    await addTabBtn(page).click()

    const tab = tabsInFocusedGroup(page).first()
    const tabCenter = await center(tab)
    const leftSurface = surfaces(page).first()
    const surfaceBox = await leftSurface.boundingBox()

    // Drag to left edge of surface
    await page.mouse.move(tabCenter.x, tabCenter.y)
    await page.mouse.down()
    await page.mouse.move(
      surfaceBox!.x + surfaceBox!.width * 0.1,
      surfaceBox!.y + surfaceBox!.height * 0.5,
      { steps: 10 },
    )

    await expect(leftSurface).toHaveAttribute("data-drop-zone", "left")

    // Move to right edge
    await page.mouse.move(
      surfaceBox!.x + surfaceBox!.width * 0.9,
      surfaceBox!.y + surfaceBox!.height * 0.5,
      { steps: 5 },
    )
    await expect(leftSurface).toHaveAttribute("data-drop-zone", "right")

    await page.mouse.up()
  })

  test("dropping tab on surface right side creates horizontal split", async ({ page }) => {
    await splitRight(page).click()
    // Focus is on right group, add a tab
    await addTabBtn(page).click()
    await expect(tabsInFocusedGroup(page)).toHaveCount(2)
    await expect(groups(page)).toHaveCount(2)

    // Drag first tab from right group to right side of left surface
    const tab = tabsInFocusedGroup(page).first()
    const tabCenter = await center(tab)
    const leftSurface = surfaces(page).first()
    const surfaceBox = await leftSurface.boundingBox()

    await drag(
      page,
      tabCenter.x,
      tabCenter.y,
      surfaceBox!.x + surfaceBox!.width * 0.9,
      surfaceBox!.y + surfaceBox!.height * 0.5,
    )

    // Should now have 3 groups (left was split)
    await expect(groups(page)).toHaveCount(3)
    // Should have a horizontal divider
    const hDivider = page.locator(
      "[data-testid^='divider-'][data-direction='horizontal']",
    )
    await expect(hDivider).toHaveCount(2) // original + new
  })

  test("dropping tab on surface bottom creates vertical split", async ({ page }) => {
    await splitRight(page).click()
    await addTabBtn(page).click()
    await expect(groups(page)).toHaveCount(2)

    const tab = tabsInFocusedGroup(page).first()
    const tabCenter = await center(tab)
    const leftSurface = surfaces(page).first()
    const surfaceBox = await leftSurface.boundingBox()

    await drag(
      page,
      tabCenter.x,
      tabCenter.y,
      surfaceBox!.x + surfaceBox!.width * 0.5,
      surfaceBox!.y + surfaceBox!.height * 0.9,
    )

    await expect(groups(page)).toHaveCount(3)
    const vDivider = page.locator(
      "[data-testid^='divider-'][data-direction='vertical']",
    )
    await expect(vDivider).toHaveCount(1)
  })
})

test.describe("Tab drag - between group tab bars", () => {
  test("tab bar drop indicator appears when hovering over another group's tab bar", async ({
    page,
  }) => {
    // Create 2 groups
    await splitRight(page).click()
    // Add a tab to the focused (right) group
    await addTabBtn(page).click()
    await expect(tabsInFocusedGroup(page)).toHaveCount(2)

    // Drag a tab from right group toward left group's tab bar
    const tab = tabsInFocusedGroup(page).first()
    const tabCenter = await center(tab)

    // Find the left group's tab bar
    const leftGroupTabBar = groupTabBars(page).first()
    const leftBarCenter = await center(leftGroupTabBar)

    await page.mouse.move(tabCenter.x, tabCenter.y)
    await page.mouse.down()
    await page.mouse.move(leftBarCenter.x, leftBarCenter.y, { steps: 10 })

    await expect(tabDropIndicator(page)).toBeVisible()
    await page.mouse.up()
  })

  test("drag tab from one group to another group's tab bar", async ({ page }) => {
    // Split to create 2 groups
    await splitRight(page).click()
    // Focus is on right group, add a second tab
    await addTabBtn(page).click()
    await expect(tabsInFocusedGroup(page)).toHaveCount(2)

    // Drag second tab from right group to left group's tab bar
    const tab = tabsInFocusedGroup(page).nth(1)
    const tabCenter = await center(tab)
    const leftGroupTabBar = groupTabBars(page).first()
    const leftBarCenter = await center(leftGroupTabBar)

    await drag(
      page,
      tabCenter.x,
      tabCenter.y,
      leftBarCenter.x,
      leftBarCenter.y,
    )

    // Left group should now have 2 tabs, right group should have 1
    // Total tabs across all groups = 3
    await expect(allTabs(page)).toHaveCount(3)
  })

  test("drag last tab from group to another removes the source group", async ({ page }) => {
    // Split to create 2 groups
    await splitRight(page).click()
    await expect(groups(page)).toHaveCount(2)

    // Drag the only tab from right group to left group's tab bar
    const tab = tabsInFocusedGroup(page).first()
    const tabCenter = await center(tab)
    const leftGroupTabBar = groupTabBars(page).first()
    const leftBarCenter = await center(leftGroupTabBar)

    await drag(
      page,
      tabCenter.x,
      tabCenter.y,
      leftBarCenter.x,
      leftBarCenter.y,
    )

    // Source group removed, left group has 2 tabs
    await expect(groups(page)).toHaveCount(1)
    await expect(allTabs(page)).toHaveCount(2)
    await expect(dividers(page)).toHaveCount(0)
  })
})

test.describe("Tab drag - reorder within group", () => {
  test("reorder tab within same group's tab bar", async ({ page }) => {
    // Add tabs to have 3
    await addTabBtn(page).click()
    await addTabBtn(page).click()
    await expect(tabsInFocusedGroup(page)).toHaveCount(3)

    const tab3 = tabsInFocusedGroup(page).nth(2)
    const tab3Center = await center(tab3)
    const tab1 = tabsInFocusedGroup(page).first()
    const tab1Box = await tab1.boundingBox()

    // Drag tab 3 to before tab 1
    await drag(
      page,
      tab3Center.x,
      tab3Center.y,
      tab1Box!.x + 2,
      tab1Box!.y + tab1Box!.height / 2,
    )

    await expect(tabsInFocusedGroup(page)).toHaveCount(3)
  })

  test("drag cancel (drop outside) does nothing", async ({ page }) => {
    await addTabBtn(page).click()
    await expect(tabsInFocusedGroup(page)).toHaveCount(2)

    const tab = tabsInFocusedGroup(page).first()
    const tabCenter = await center(tab)

    // Drag to toolbar area (outside tab bars and surfaces)
    await drag(
      page,
      tabCenter.x,
      tabCenter.y,
      640,
      700,
    )

    await expect(tabsInFocusedGroup(page)).toHaveCount(2)
    await expect(groups(page)).toHaveCount(1)
  })
})

// ─── Renderer-parameterized split focus tests ─────────────────────────────

for (const renderer of ["ghostty", "xterm"] as const) {
  test.describe(`Split focus (${renderer})`, () => {
    test.beforeEach(async ({ page }) => {
      await page.goto(`/terminal?shell=local&renderer=${renderer}`)
      await expect(surfaces(page).first()).toBeVisible()
    })

    test(`Cmd+D splits right and new pane is focused`, async ({ page }) => {
      const origSurfaceId = await surfaces(page).first().getAttribute("data-testid")

      await page.keyboard.press("Meta+d")

      await expect(groups(page)).toHaveCount(2)
      await expect(surfaces(page)).toHaveCount(2)

      // The NEW surface (not the original) should be focused
      const focused = focusedSurface(page)
      await expect(focused).toHaveCount(1)
      const focusedId = await focused.getAttribute("data-testid")
      expect(focusedId).not.toBe(origSurfaceId)

      // The old surface should NOT be focused
      const oldSurface = page.locator(`[data-testid='${origSurfaceId}']`)
      await expect(oldSurface).toHaveAttribute("data-focused", "false")
    })

    test(`Cmd+Shift+D splits down and new pane is focused`, async ({ page }) => {
      const origSurfaceId = await surfaces(page).first().getAttribute("data-testid")

      await page.keyboard.press("Meta+Shift+d")

      await expect(groups(page)).toHaveCount(2)
      await expect(surfaces(page)).toHaveCount(2)

      // The NEW surface (not the original) should be focused
      const focused = focusedSurface(page)
      await expect(focused).toHaveCount(1)
      const focusedId = await focused.getAttribute("data-testid")
      expect(focusedId).not.toBe(origSurfaceId)

      // The old surface should NOT be focused
      const oldSurface = page.locator(`[data-testid='${origSurfaceId}']`)
      await expect(oldSurface).toHaveAttribute("data-focused", "false")
    })

    test(`focus preserved after multiple splits`, async ({ page }) => {
      // Split right twice
      await page.keyboard.press("Meta+d")
      await expect(groups(page)).toHaveCount(2)
      await expect(focusedSurface(page)).toHaveCount(1)

      await page.keyboard.press("Meta+Shift+d")
      await expect(groups(page)).toHaveCount(3)
      await expect(focusedSurface(page)).toHaveCount(1)

      // Only one surface should be focused
      const allSurfs = surfaces(page)
      const count = await allSurfs.count()
      let focusedCount = 0
      for (let i = 0; i < count; i++) {
        const f = await allSurfs.nth(i).getAttribute("data-focused")
        if (f === "true") focusedCount++
      }
      expect(focusedCount).toBe(1)
    })
  })
}

// ─── Spatial navigation (Cmd+Ctrl+HJKL) in 2x2 grid ────────────────────────

test.describe("Spatial navigation in 2x2 grid", () => {
  // Build a 2x2 grid:
  //   A (top-left)  | B (top-right)
  //   ──────────────+──────────────
  //   C (bot-left)  | D (bot-right)
  //
  // Construction order:
  //   Start with pane A, split right → A | B (focus on B)
  //   Click A to focus it, split down → A on top, C on bottom (focus on C)
  //   Click B to focus it, split down → B on top, D on bottom (focus on D)
  //
  // After construction, we identify each pane by its bounding box position.

  /** Get surface positions labeled by quadrant */
  async function getQuadrants(page: Page) {
    const allSurfaces = surfaces(page)
    const count = await allSurfaces.count()
    const items: { id: string; x: number; y: number; el: Locator }[] = []
    for (let i = 0; i < count; i++) {
      const el = allSurfaces.nth(i)
      const box = await el.boundingBox()
      const testId = await el.getAttribute("data-testid")
      items.push({ id: testId!, x: box!.x, y: box!.y, el })
    }
    // Sort by position: top-left first
    items.sort((a, b) => a.y - b.y || a.x - b.x)
    // items[0] = top-left (A), items[1] = top-right (B), items[2] = bot-left (C), items[3] = bot-right (D)
    return { A: items[0], B: items[1], C: items[2], D: items[3] }
  }

  test.beforeEach(async ({ page }) => {
    await page.goto("/terminal?shell=local")
    await expect(surfaces(page).first()).toBeVisible()

    // Build 2x2: split right, then split each column down
    await page.keyboard.press("Meta+d") // A | B, focus on B
    await expect(groups(page)).toHaveCount(2)

    // Focus A (left surface), split down
    await surfaces(page).first().click()
    await page.keyboard.press("Meta+Shift+d") // A/C | B, focus on C
    await expect(groups(page)).toHaveCount(3)

    // Focus B (top-right), split down
    const allSurfs = surfaces(page)
    // B is the one in the top-right: find it by position
    const count = await allSurfs.count()
    const positions: { idx: number; x: number; y: number }[] = []
    for (let i = 0; i < count; i++) {
      const box = await allSurfs.nth(i).boundingBox()
      positions.push({ idx: i, x: box!.x, y: box!.y })
    }
    // Top-right = highest x among those with lowest y
    const minY = Math.min(...positions.map((p) => p.y))
    const topRow = positions.filter((p) => Math.abs(p.y - minY) < 10)
    const topRight = topRow.reduce((a, b) => (a.x > b.x ? a : b))
    await allSurfs.nth(topRight.idx).click()
    await page.keyboard.press("Meta+Shift+d") // A/C | B/D, focus on D
    await expect(groups(page)).toHaveCount(4)
  })

  test("from top-right (B), Cmd+Ctrl+H focuses top-left (A)", async ({ page }) => {
    const q = await getQuadrants(page)
    // Focus B
    await q.B.el.click()
    await expect(q.B.el).toHaveAttribute("data-focused", "true")
    // Press Cmd+Ctrl+H (left)
    await page.keyboard.press("Meta+Control+h")
    await expect(q.A.el).toHaveAttribute("data-focused", "true")
  })

  test("from bottom-right (D), Cmd+Ctrl+H focuses bottom-left (C)", async ({ page }) => {
    const q = await getQuadrants(page)
    await q.D.el.click()
    await expect(q.D.el).toHaveAttribute("data-focused", "true")
    await page.keyboard.press("Meta+Control+h")
    await expect(q.C.el).toHaveAttribute("data-focused", "true")
  })

  test("from top-left (A), Cmd+Ctrl+L focuses top-right (B)", async ({ page }) => {
    const q = await getQuadrants(page)
    await q.A.el.click()
    await expect(q.A.el).toHaveAttribute("data-focused", "true")
    await page.keyboard.press("Meta+Control+l")
    await expect(q.B.el).toHaveAttribute("data-focused", "true")
  })

  test("from bottom-left (C), Cmd+Ctrl+L focuses bottom-right (D)", async ({ page }) => {
    const q = await getQuadrants(page)
    await q.C.el.click()
    await expect(q.C.el).toHaveAttribute("data-focused", "true")
    await page.keyboard.press("Meta+Control+l")
    await expect(q.D.el).toHaveAttribute("data-focused", "true")
  })

  test("from top-left (A), Cmd+Ctrl+J focuses bottom-left (C)", async ({ page }) => {
    const q = await getQuadrants(page)
    await q.A.el.click()
    await expect(q.A.el).toHaveAttribute("data-focused", "true")
    await page.keyboard.press("Meta+Control+j")
    await expect(q.C.el).toHaveAttribute("data-focused", "true")
  })

  test("from top-right (B), Cmd+Ctrl+J focuses bottom-right (D)", async ({ page }) => {
    const q = await getQuadrants(page)
    await q.B.el.click()
    await expect(q.B.el).toHaveAttribute("data-focused", "true")
    await page.keyboard.press("Meta+Control+j")
    await expect(q.D.el).toHaveAttribute("data-focused", "true")
  })

  test("from bottom-left (C), Cmd+Ctrl+K focuses top-left (A)", async ({ page }) => {
    const q = await getQuadrants(page)
    await q.C.el.click()
    await expect(q.C.el).toHaveAttribute("data-focused", "true")
    await page.keyboard.press("Meta+Control+k")
    await expect(q.A.el).toHaveAttribute("data-focused", "true")
  })

  test("from bottom-right (D), Cmd+Ctrl+K focuses top-right (B)", async ({ page }) => {
    const q = await getQuadrants(page)
    await q.D.el.click()
    await expect(q.D.el).toHaveAttribute("data-focused", "true")
    await page.keyboard.press("Meta+Control+k")
    await expect(q.B.el).toHaveAttribute("data-focused", "true")
  })

  test("left-right-left roundtrip returns to same pane (from D)", async ({ page }) => {
    const q = await getQuadrants(page)
    // Start at D (bottom-right)
    await q.D.el.click()
    await expect(q.D.el).toHaveAttribute("data-focused", "true")

    // Go left → should be C (bottom-left)
    await page.keyboard.press("Meta+Control+h")
    await expect(q.C.el).toHaveAttribute("data-focused", "true")

    // Go right → should be D (bottom-right) again
    await page.keyboard.press("Meta+Control+l")
    await expect(q.D.el).toHaveAttribute("data-focused", "true")

    // Go left → should be C again
    await page.keyboard.press("Meta+Control+h")
    await expect(q.C.el).toHaveAttribute("data-focused", "true")
  })

  test("up-down-up roundtrip returns to same pane (from D)", async ({ page }) => {
    const q = await getQuadrants(page)
    // Start at D (bottom-right)
    await q.D.el.click()
    await expect(q.D.el).toHaveAttribute("data-focused", "true")

    // Go up → should be B (top-right)
    await page.keyboard.press("Meta+Control+k")
    await expect(q.B.el).toHaveAttribute("data-focused", "true")

    // Go down → should be D again
    await page.keyboard.press("Meta+Control+j")
    await expect(q.D.el).toHaveAttribute("data-focused", "true")

    // Go up → should be B again
    await page.keyboard.press("Meta+Control+k")
    await expect(q.B.el).toHaveAttribute("data-focused", "true")
  })

  test("no-op at edge: from A, Cmd+Ctrl+H does nothing", async ({ page }) => {
    const q = await getQuadrants(page)
    await q.A.el.click()
    await expect(q.A.el).toHaveAttribute("data-focused", "true")
    await page.keyboard.press("Meta+Control+h")
    // Should stay on A
    await expect(q.A.el).toHaveAttribute("data-focused", "true")
  })

  test("no-op at edge: from D, Cmd+Ctrl+L does nothing", async ({ page }) => {
    const q = await getQuadrants(page)
    await q.D.el.click()
    await expect(q.D.el).toHaveAttribute("data-focused", "true")
    await page.keyboard.press("Meta+Control+l")
    // Should stay on D
    await expect(q.D.el).toHaveAttribute("data-focused", "true")
  })

  test("full circuit: A → right → down → left → up returns to A", async ({ page }) => {
    const q = await getQuadrants(page)
    await q.A.el.click()
    await expect(q.A.el).toHaveAttribute("data-focused", "true")

    await page.keyboard.press("Meta+Control+l") // A → B
    await expect(q.B.el).toHaveAttribute("data-focused", "true")

    await page.keyboard.press("Meta+Control+j") // B → D
    await expect(q.D.el).toHaveAttribute("data-focused", "true")

    await page.keyboard.press("Meta+Control+h") // D → C
    await expect(q.C.el).toHaveAttribute("data-focused", "true")

    await page.keyboard.press("Meta+Control+k") // C → A
    await expect(q.A.el).toHaveAttribute("data-focused", "true")
  })
})


import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  HIDDEN_SCROLLER_ATTRIBUTE,
  markScrolling,
  SCROLLING_ATTRIBUTE,
  SCROLLING_HIDE_MS,
  type ScrollTimers,
} from "../src/scrollers";

function fixture() {
  const dom = new JSDOM("<!doctype html><div></div>");
  const element = dom.window.document.querySelector("div") as unknown as Element;
  const callbacks = new Map<number, () => void>();
  const delays: number[] = [];
  let next = 0;
  const timers: ScrollTimers = {
    set(callback, ms) {
      delays.push(ms);
      callbacks.set(++next, callback);
      return next;
    },
    clear(handle) {
      callbacks.delete(handle as number);
    },
  };
  return { dom, element, callbacks, delays, timers };
}

test("scrolling a hidden scrollbar schedules no idle callback", () => {
  const { dom, element, callbacks, delays, timers } = fixture();
  try {
    element.setAttribute(HIDDEN_SCROLLER_ATTRIBUTE, "");
    markScrolling(element, timers);
    markScrolling(element, timers);
    expect(delays).toEqual([]);
    expect(callbacks.size).toBe(0);
    expect(element.hasAttribute(SCROLLING_ATTRIBUTE)).toBe(false);
  } finally {
    dom.window.close();
  }
});

test("ordinary scrollbars still reveal and hide after the last scroll", () => {
  const { dom, element, callbacks, delays, timers } = fixture();
  try {
    markScrolling(element, timers);
    markScrolling(element, timers);
    expect(element.hasAttribute(SCROLLING_ATTRIBUTE)).toBe(true);
    expect(delays).toEqual([SCROLLING_HIDE_MS, SCROLLING_HIDE_MS]);
    expect(callbacks.size).toBe(1);
    [...callbacks.values()][0]!();
    expect(element.hasAttribute(SCROLLING_ATTRIBUTE)).toBe(false);
  } finally {
    dom.window.close();
  }
});

test("opting out clears an existing scrollbar timer and mark", () => {
  const { dom, element, callbacks, delays, timers } = fixture();
  try {
    markScrolling(element, timers);
    element.setAttribute(HIDDEN_SCROLLER_ATTRIBUTE, "");
    markScrolling(element, timers);
    expect(callbacks.size).toBe(0);
    expect(delays).toEqual([SCROLLING_HIDE_MS]);
    expect(element.hasAttribute(SCROLLING_ATTRIBUTE)).toBe(false);
    element.removeAttribute(HIDDEN_SCROLLER_ATTRIBUTE);
    markScrolling(element, timers);
    expect(callbacks.size).toBe(1);
    expect(element.hasAttribute(SCROLLING_ATTRIBUTE)).toBe(true);
  } finally {
    dom.window.close();
  }
});

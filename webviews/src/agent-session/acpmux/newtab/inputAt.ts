// The time of the page's click or key that asks the host for something, as the host reads it: Unix
// milliseconds of the platform event (`performance.timeOrigin + event.timeStamp`). The host answers
// the request a turn after that event's own dispatch, so it takes the input's age from this stamp
// (`AgentPaneRequest.uptime(ofPageInputAt:)`), as Chrome carries an input's time with the work it
// causes across processes (`EventMetrics`, cc/metrics/event_metrics.h).
export function inputAt(event: { timeStamp: number }, origin: number = performance.timeOrigin): number {
  return origin + event.timeStamp;
}

/// `tab.jump`'s params: where to go and, when a click or Return picked it, that input's time.
export function jumpParams(target: string, id: string, at?: number): { target: string; id: string; inputAt?: number } {
  return at === undefined ? { target, id } : { target, id, inputAt: at };
}

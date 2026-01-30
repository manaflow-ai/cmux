import { Metric, ReportHandler } from '../types.js';
export declare const bindReporter: (callback: ReportHandler, metric: Metric, po: PerformanceObserver | undefined, observeAllUpdates?: boolean | undefined) => () => void;

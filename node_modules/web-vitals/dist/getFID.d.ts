import { ReportHandler } from './types.js';
interface FIDPolyfillCallback {
    (value: number, event: Event): void;
}
interface FIDPolyfill {
    onFirstInputDelay: (onReport: FIDPolyfillCallback) => void;
}
declare global {
    interface Window {
        perfMetrics: FIDPolyfill;
    }
}
export declare const getFID: (onReport: ReportHandler) => void;
export {};

export interface Metric {
    name: 'CLS' | 'FCP' | 'FID' | 'LCP' | 'TTFB';
    value: number;
    delta: number;
    id: string;
    isFinal: boolean;
    entries: PerformanceEntry[];
}
export interface ReportHandler {
    (metric: Metric): void;
}

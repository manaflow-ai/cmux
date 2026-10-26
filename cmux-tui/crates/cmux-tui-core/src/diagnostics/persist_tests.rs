use std::time::Duration;

use cmux_trace::metrics::{MetricsFile, log_linear_index};

use super::*;
use crate::diagnostics::REQUEST_CLASSES;

fn scratch_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir()
        .join(format!("cmux-diagnostics-persist-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

#[test]
fn diagnostics_persist_heap_buckets_map_back_to_themselves() {
    for bucket in (0..4).chain(8..256) {
        let lower = heap_bucket_lower_bound(bucket);
        assert_eq!(LogLinearHistogram::bucket_index(lower), bucket, "bucket {bucket}");
        assert_eq!(log_linear_index(lower), bucket, "the file's index of bucket {bucket}");
    }
}

#[test]
fn diagnostics_persist_a_snapshot_reads_the_same_numbers_from_the_file() {
    let histogram = LogLinearHistogram::new();
    for micros in [0, 3, 90, 1_500, 1_500, 22_000, 900_000] {
        histogram.record(micros);
    }
    let before = histogram.snapshot_with_p95();
    let metrics = DaemonMetrics::new(daemon_header());
    assert!(metrics.bind(&histogram, "daemon.request.query"));
    assert_eq!(histogram.snapshot_with_p95(), before, "server-stats reads the moved counts");
    histogram.record(1_500);
    let index = metrics.store().index_of("daemon.request.query").expect("in the catalog");
    let file = metrics.store().read(index).expect("in the catalog");
    assert_eq!(file.count, 8, "a record after the move goes into the store");
    assert_eq!(file.buckets[log_linear_index(1_500)], 3);
    assert_eq!(histogram.snapshot().count, 8);
    assert_eq!(histogram.snapshot().max, 900_000);
}

#[test]
fn diagnostics_persist_an_over_maximum_sample_reports_the_max_as_its_bound() {
    let histogram = LogLinearHistogram::new();
    let metrics = DaemonMetrics::new(daemon_header());
    assert!(metrics.bind(&histogram, "daemon.dispatch.queue_us"));
    histogram.record(90_000_000);
    let snapshot = histogram.percentiles();
    assert_eq!((snapshot.count, snapshot.p50, snapshot.max), (1, 90_000_000, 90_000_000));
}

#[test]
fn diagnostics_persist_binds_once_and_only_catalog_names() {
    let histogram = LogLinearHistogram::new();
    let metrics = DaemonMetrics::new(daemon_header());
    assert!(!metrics.bind(&histogram, "daemon.request.unknown"));
    assert!(metrics.bind(&histogram, "daemon.lock.registry.wait_us"));
    assert!(!metrics.bind(&histogram, "daemon.lock.registry.hold_us"), "a second bind");
}

#[test]
fn diagnostics_persist_the_catalog_names_every_request_class() {
    let names: Vec<&str> = DAEMON_CATALOG.iter().map(|spec| spec.name).collect();
    for class in REQUEST_CLASSES {
        assert!(names.contains(&format!("daemon.request.{class}").as_str()), "{class}");
    }
    let mut unique = names.clone();
    unique.sort_unstable();
    unique.dedup();
    assert_eq!(unique.len(), names.len(), "a name is listed twice");
    assert!(names.iter().all(|name| name.len() < cmux_trace::metrics::NAME_BYTES));
}

#[cfg(unix)]
#[test]
fn diagnostics_persist_a_daemon_writes_its_histograms_into_its_file() {
    let dir = scratch_dir("mux");
    let mux = crate::Mux::new("diagnostics-persist", crate::SurfaceOptions::default());
    mux.request_stats().record_latency(3, Duration::from_micros(700));
    let (metrics, open) = mux.start_metrics_file(Some(&dir));
    let path = open.expect("a directory was given").wait().expect("maps the file");
    assert_eq!(path, metrics_dir(&dir).join(format!("metrics-daemon-{}.bin", std::process::id())));
    assert!(metrics.store().is_file_backed());
    mux.request_stats().record_latency(3, Duration::from_micros(1_200));
    mux.request_stats().record_dispatch_queue(Duration::from_micros(40));
    let stats = mux.request_stats().snapshot();
    assert_eq!(stats.request_latency_us.query.count, 2, "server-stats reads the file's counts");

    let (_, again) = mux.start_metrics_file(Some(&dir));
    assert!(again.is_none(), "a second start maps no file over the first");

    let file = MetricsFile::open(&path).expect("maps the daemon's file");
    let delta = file.fold();
    let query = delta.histogram("daemon.request.query").expect("query latency");
    assert_eq!((query.count, query.sum), (2, 1_900));
    let dispatch = delta.histogram("daemon.dispatch.queue_us").expect("the dispatch queue");
    assert_eq!(dispatch.count, 1);
    assert!(file.fold().is_empty(), "a second fold reads nothing");
    assert_eq!(mux.request_stats().snapshot(), stats, "a fold leaves server-stats alone");
    let _ = std::fs::remove_dir_all(&dir);
}

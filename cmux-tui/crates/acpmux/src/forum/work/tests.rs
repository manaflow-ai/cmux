use super::*;
use std::sync::Arc;

fn warning(host: &str) -> String {
    format!(
        "WARN glaeda-gh on {host}: 12 job(s) on runner label cmux-fleet-linux-x64 queued with no runner past 30 min on 1 watched head(s), e.g. org/repo#1. Nothing starts it until a runner is available"
    )
}

#[test]
fn forum_work_hosts_converge_and_restart_preserves_the_receipt() {
    let dir = tempfile::tempdir().unwrap();
    let forum = Arc::new(Forum::open(dir.path()).unwrap());
    let workers: Vec<_> = (0..32)
        .map(|n| {
            let forum = forum.clone();
            std::thread::spawn(move || {
                forum
                    .work_post(
                        "coord",
                        ingest("glaeda-gh", &warning(&format!("host-{n}")), 100).unwrap(),
                        json!({"declared": true}),
                        100,
                    )
                    .unwrap()
            })
        })
        .collect();
    let receipts: Vec<_> = workers.into_iter().map(|w| w.join().unwrap()).collect();
    assert_eq!(receipts.iter().filter(|r| r["duplicate"] == false).count(), 1);
    assert!(receipts.iter().all(|r| r["postId"] == receipts[0]["postId"]));
    assert!(forum.rules().is_empty());
    assert!(forum.undelivered("coord", true).is_empty());
    drop(forum);
    let forum = Forum::open(dir.path()).unwrap();
    let threads = forum.work_threads("coord", None, None);
    assert_eq!(threads["threads"].as_array().unwrap().len(), 1);
    assert_eq!(threads["threads"][0]["latest"]["sources"].as_object().unwrap().len(), 32);
    let again = forum
        .work_post("coord", ingest("glaeda-gh", &warning("host-0"), 100).unwrap(), Value::Null, 100)
        .unwrap();
    assert_eq!(again["postId"], receipts[0]["postId"]);
    assert_eq!(again["duplicate"], true);
    assert_eq!(forum.work_digest("coord", 101)[0].source_count, 32);
    assert_eq!(forum.work_threads("someone-else", None, None)["threads"], json!([]));
}

#[test]
fn forum_work_digest_is_bounded_and_only_answered_delivery_advances_it() {
    let forum = Forum::memory();
    for n in 0..25 {
        let mut input = ingest("glaeda-gh", &warning("host"), 0).unwrap();
        input.thread = format!("label-{n}");
        forum.work_post("coord", input, Value::Null, 0).unwrap();
    }
    let first = forum.work_digest("coord", 1);
    assert_eq!(first.len(), 20);
    assert_eq!(
        forum.work_digest("coord", 2).len(),
        20,
        "a failed turn must not consume the digest"
    );
    forum.work_delivered("coord", first.into_iter().map(|p| p.id).collect(), 2).unwrap();
    assert!(forum.work_digest("coord", DIGEST_MS).is_empty());
    assert_eq!(forum.work_digest("coord", DIGEST_MS + 2).len(), 5);
}

#[test]
fn forum_work_lease_fences_competing_and_expired_claims() {
    let forum = Forum::memory();
    let input = ingest("glaeda-gh", &warning("host"), 0).unwrap();
    let (channel, thread) = (input.channel.clone(), input.thread.clone());
    forum.work_post("coord", input, Value::Null, 0).unwrap();
    let first = forum.work_claim("coord", &channel, &thread, "a", None, 30, 0).unwrap();
    assert_eq!(first.epoch, 1);
    assert!(forum.work_claim("coord", &channel, &thread, "b", None, 30, 1).is_err());
    assert!(forum.work_claim("coord", &channel, &thread, "a", None, 30, 1).is_err());
    assert_eq!(forum.work_claim("coord", &channel, &thread, "a", Some(1), 30, 1).unwrap().epoch, 1);
    assert_eq!(
        forum.work_claim("coord", &channel, &thread, "b", None, 30, 30_002).unwrap().epoch,
        2
    );
    assert!(forum.work_claim("coord", &channel, &thread, "a", Some(1), 30, 30_003).is_err());
}

#[test]
fn forum_work_disk_recovery_is_not_runner_recovery_and_partial_digests_are_refused() {
    let text = "disk-hygiene on host-a: healthy again (unowned-fetch cleared)";
    assert!(ingest("glaeda-gh", text, 0).is_none());
    let input = ingest("disk-hygiene", text, 0).unwrap();
    assert_eq!(input.channel, "ops/disk-hygiene");
    assert_eq!(input.thread, "host-a");
    assert_eq!(input.kind, Kind::Receipt);
    assert!(ingest("other", &warning("host"), 0).is_none());
    assert!(ingest("glaeda-gh", &format!("{}\nand 2 more", warning("host")), 0).is_none());
    assert!(ingest("glaeda-gh", &format!("Quoted: {}", warning("host")), 0).is_none());
}

#[test]
fn forum_work_failed_write_accepts_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let forum = Forum::open(dir.path()).unwrap();
    std::fs::create_dir(dir.path().join("posts.jsonl")).unwrap();
    assert!(
        forum
            .work_post("coord", ingest("glaeda-gh", &warning("host"), 0).unwrap(), Value::Null, 0)
            .is_err()
    );
    assert_eq!(forum.work_threads("coord", None, None)["threads"], json!([]));
}

#[test]
fn forum_work_baseline_replay_measures_notices_without_claiming_live_delivery() {
    // Coordinator transcript receipt, 2026-11-20 06:20–07:20Z: 33 runner WARNs
    // across eight labels and four disk recoveries. Same harness for both routes.
    let labels = [
        "ubuntu-24",
        "cmux-gcp-lane-build-x64",
        "cmux-fleet-linux-x64",
        "blacksmith-8vcpu-ubuntu-2404",
        "blacksmith-16vcpu-ubuntu-2404",
        "blacksmith-2vcpu-ubuntu-2404",
        "blacksmith-32vcpu-ubuntu-2404",
        "cmux-freestyle-linux-x64",
    ];
    let forum = Forum::memory();
    let counts = [4, 2, 5, 8, 7, 5, 1, 1];
    assert_eq!(counts.iter().sum::<usize>(), 33);
    for (label, count) in labels.into_iter().zip(counts) {
        for n in 0..count {
            let text = warning(&format!("host-{n}")).replace("cmux-fleet-linux-x64", label);
            forum
                .work_post("coord", ingest("glaeda-gh", &text, 0).unwrap(), Value::Null, 0)
                .unwrap();
        }
    }
    for n in 0..4 {
        let text = format!("disk-hygiene on disk-{n}: healthy again (unowned-fetch cleared)");
        forum
            .work_post("coord", ingest("disk-hygiene", &text, 0).unwrap(), Value::Null, 0)
            .unwrap();
    }
    assert_eq!(forum.work_threads("coord", None, None)["threads"].as_array().unwrap().len(), 12);
    assert_eq!(forum.work_digest("coord", 1).len(), 12);
    // 37 former per-notice DMs -> zero per-notice DMs, one next-turn digest in this replay.
    // This assertion is a store replay, not a deployed notices/hour measurement.
}

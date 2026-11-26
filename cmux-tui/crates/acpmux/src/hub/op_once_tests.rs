use super::*;
use std::sync::atomic::{AtomicU64, Ordering};

async fn counted(once: &OpOnce, runs: &AtomicU64, params: Value) -> Result<Value, RpcError> {
    once.run("m", &params, || async {
        let n = runs.fetch_add(1, Ordering::SeqCst) + 1;
        Ok(json!({"run": n}))
    })
    .await
}

#[tokio::test]
async fn a_repeat_answers_the_first_result_and_runs_nothing() {
    let (once, runs) = (OpOnce::default(), AtomicU64::new(0));
    let params = json!({"sessionId": "s", "archived": true, "opId": "a"});
    let first = counted(&once, &runs, params.clone()).await.unwrap();
    for _ in 0..5 {
        assert_eq!(counted(&once, &runs, params.clone()).await.unwrap(), first);
    }
    // Another trace in `_meta` is the same op.
    let traced = json!({"sessionId": "s", "archived": true, "opId": "a", "_meta": {"t": 1}});
    assert_eq!(counted(&once, &runs, traced).await.unwrap(), first);
    assert_eq!(runs.load(Ordering::SeqCst), 1);
    assert_eq!(once.repeats(), 6);
}

#[tokio::test]
async fn no_op_id_runs_every_time() {
    let (once, runs) = (OpOnce::default(), AtomicU64::new(0));
    for _ in 0..3 {
        counted(&once, &runs, json!({"sessionId": "s", "archived": true})).await.unwrap();
    }
    counted(&once, &runs, json!({"sessionId": "s", "opId": null})).await.unwrap();
    assert_eq!(runs.load(Ordering::SeqCst), 4);
}

#[tokio::test]
async fn the_same_id_with_other_params_is_refused() {
    let (once, runs) = (OpOnce::default(), AtomicU64::new(0));
    counted(&once, &runs, json!({"sessionId": "s", "archived": true, "opId": "a"})).await.unwrap();
    let err = counted(&once, &runs, json!({"sessionId": "s", "archived": false, "opId": "a"}))
        .await
        .unwrap_err();
    assert_eq!(err.data.as_ref().unwrap()["reason"], "op_id.reused");
    // The id is the method's own: another method's same id is another op.
    once.run("other", &json!({"opId": "a"}), || async { Ok(json!(1)) }).await.unwrap();
    assert_eq!(runs.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn an_error_is_not_kept() {
    let once = OpOnce::default();
    let params = json!({"opId": "a"});
    let err = once.run("m", &params, || async { Err(RpcError::invalid_params("no")) }).await;
    assert!(err.is_err());
    assert_eq!(once.run("m", &params, || async { Ok(json!(2)) }).await.unwrap(), json!(2));
}

#[tokio::test]
async fn a_bad_op_id_is_refused() {
    let once = OpOnce::default();
    for bad in [json!(""), json!(7), json!("x".repeat(OP_ID_MOST + 1))] {
        let err =
            once.run("m", &json!({"opId": bad}), || async { Ok(json!(1)) }).await.unwrap_err();
        assert_eq!(err.data.as_ref().unwrap()["reason"], "op_id.invalid");
    }
}

/// The table holds the most recent ids and no more, however many ops and repeats come.
#[tokio::test]
async fn the_table_is_bounded_and_keeps_the_recent() {
    let (once, runs) = (OpOnce::default(), AtomicU64::new(0));
    let total = OP_ONCE_MOST * 10;
    for n in 0..total {
        counted(&once, &runs, json!({"opId": format!("op-{n}")})).await.unwrap();
        // A repeat of a recent id, as a retry: it touches the id again.
        counted(&once, &runs, json!({"opId": format!("op-{}", n / 2)})).await.unwrap();
        let recent = once.recent.lock().unwrap();
        assert!(recent.slots.len() <= OP_ONCE_MOST);
        assert!(recent.order.len() <= OP_ONCE_MOST * 4 + 1);
    }
    let before = runs.load(Ordering::SeqCst);
    counted(&once, &runs, json!({"opId": format!("op-{}", total - 1)})).await.unwrap();
    assert_eq!(runs.load(Ordering::SeqCst), before, "the newest id is kept");
    counted(&once, &runs, json!({"opId": "op-0"})).await.unwrap();
    assert_eq!(runs.load(Ordering::SeqCst), before + 1, "the oldest id fell out and runs again");
}

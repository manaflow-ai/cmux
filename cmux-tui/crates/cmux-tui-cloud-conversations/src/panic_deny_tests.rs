//! Client and peer JSON that is not an object no longer
//! panics the daemon.

use std::sync::Arc;

use serde_json::{Value, json};

use crate::panic_free::JsonFields as _;
use crate::testing::FakeBackend;
use crate::{CloudConversations, CloudError};

const CONV: &str = "conv_0123456789ABCDEFGHJKMNPQRS";

#[test]
fn an_attachment_declaration_that_is_not_an_object_is_a_bad_request() {
    let backend = Arc::new(FakeBackend::default());
    let service = CloudConversations::new(backend.clone());
    for declaration in [json!([1, 2]), json!("text"), json!(7), json!(true)] {
        let error = service
            .attachment_intent(CONV, &declaration)
            .expect_err("a non-object declaration is refused");
        assert!(matches!(error, CloudError::BadRequest(_)), "{declaration}: {error:?}");
    }
    assert!(backend.posted().is_empty(), "nothing was sent");
}

#[test]
fn json_fields_read_null_for_missing_keys_and_non_objects() {
    let frame = json!({"t": "op", "principal": {"user": "user_1"}});
    assert_eq!(frame.field("t"), "op");
    assert_eq!(frame.field("principal").field("user"), "user_1");
    assert!(frame.field("principal").field("agent").is_null());
    assert!(json!([1]).field("t").is_null());
    assert!(json!("op").field("t").is_null());
}

#[test]
fn json_fields_insert_into_objects_and_null_only() {
    let mut object = json!({"a": 1});
    object.insert("b", json!(2));
    assert_eq!(object, json!({"a": 1, "b": 2}));

    let mut null = Value::Null;
    null.insert("a", json!(1));
    assert_eq!(null, json!({"a": 1}));

    let mut array = json!([1]);
    array.insert("a", json!(1));
    assert_eq!(array, json!([1]));
}

use super::*;

#[test]
fn a_bundle_carries_every_surfaces_draft_and_drops_what_composer_set_would_refuse() {
    let mut c = Composers::default();
    let phone = Surface { id: "phone".into(), name: "iPhone".into(), kind: Some("ios".into()) };
    let mac = Surface { id: "mac".into(), name: "Mac".into(), kind: None };
    for (order, (s, text)) in [(&mac, "first"), (&phone, "second")].into_iter().enumerate() {
        let draft = Draft {
            surface: s.clone(),
            text: text.into(),
            images: Vec::new(),
            updated_at: 7,
            order: order as u64 + 1,
        };
        c.drafts.insert(s.id.clone(), draft);
    }
    c.sent.push_back(("p-1".into(), phone.clone()));
    let mut bundled = c.bundled();
    // Another daemon wrote it: a hidden character, a blank draft and a missing id are dropped.
    bundled["drafts"].as_array_mut().unwrap().extend([
        json!({"surface": {"id": "x\u{202E}", "name": "spoof"}, "text": "t", "order": 9}),
        json!({"surface": {"id": "blank", "name": "Blank"}, "text": "  ", "order": 9}),
    ]);
    bundled["sent"].as_array_mut().unwrap().push(json!({"surface": {"id": "mac", "name": "Mac"}}));

    let mut back = Composers::default();
    back.restore(&bundled);
    let mut ids: Vec<_> = back.drafts.keys().cloned().collect();
    ids.sort();
    assert_eq!(ids, ["mac", "phone"]);
    assert_eq!(back.drafts["phone"].surface, phone);
    assert_eq!(back.drafts["mac"].text, "first");
    assert_eq!(back.typed, 2, "the next draft typed here orders after the carried ones");
    assert_eq!(back.sent_by("p-1"), Some(&phone));
    assert_eq!(back.sent.len(), 1);
}

#[test]
fn a_bundles_draft_order_only_ranks_the_drafts_it_carries() {
    let draft = |id: &str, order: u64| json!({"surface": {"id": id, "name": id}, "text": "t", "order": order});
    let bundled = json!({"drafts": [draft("late", u64::MAX), draft("early", 3)]});
    let mut back = Composers { typed: 5, ..Composers::default() };
    back.restore(&bundled);
    assert_eq!(back.drafts["early"].order, 6, "numbered on from this chat's own count");
    assert_eq!(back.drafts["late"].order, 7, "in the order the other machine typed them");
    assert_eq!(back.typed, 7, "the next keystroke has a number left to take");
}

#[test]
fn composer_set_refuses_an_image_it_cannot_keep_or_does_not_hold() {
    let reason = |e: RpcError| e.data.unwrap()["reason"].as_str().unwrap().to_owned();
    assert!(draft_images(None, &[]).unwrap().is_empty(), "an old client names none");
    assert!(draft_images(Some(&Value::Null), &[]).unwrap().is_empty());
    let not_a_list = draft_images(Some(&json!({"id": "x"})), &[]).unwrap_err();
    assert_eq!(reason(not_a_list), "composer.image.invalid");
    let bad = json!([{"type": "image", "mimeType": "image/png", "data": "%%%"}]);
    assert_eq!(reason(draft_images(Some(&bad), &[]).unwrap_err()), "composer.image.invalid");
    let unknown = json!([{"id": "a".repeat(64)}]);
    assert_eq!(reason(draft_images(Some(&unknown), &[]).unwrap_err()), "composer.image.unknown");
    let path = json!([{"id": "../secret"}]);
    assert_eq!(reason(draft_images(Some(&path), &[]).unwrap_err()), "composer.image.invalid");
    let many = json!(vec![json!({"id": "a".repeat(64)}); MAX_DRAFT_IMAGES + 1]);
    assert_eq!(reason(draft_images(Some(&many), &[]).unwrap_err()), "composer.image.invalid");
}

#[test]
fn a_bundled_drafts_images_keep_only_what_a_record_names() {
    let id = "b".repeat(64);
    let mut c = Composers::default();
    let mac = Surface { id: "mac".into(), name: "Mac".into(), kind: None };
    let image =
        json!({"id": id, "mimeType": "image/png", "name": "shot.png", "width": 1, "height": 1});
    let draft = Draft {
        surface: mac.clone(),
        text: String::new(),
        images: vec![image.clone()],
        updated_at: 7,
        order: 1,
    };
    c.drafts.insert(mac.id.clone(), draft);
    assert_eq!(c.image_ids(), std::slice::from_ref(&id), "a move bundles the draft's image");
    let bundled = c.bundled();
    assert_eq!(bundled["drafts"][0]["images"], json!([image]));
    let stray = json!({"id": id, "mimeType": "x".repeat(500), "extra": "dropped", "width": -1});
    assert_eq!(carried_image(&stray), Some(json!({"id": id, "mimeType": "image/png"})));
    assert_eq!(carried_image(&json!({"id": "../../etc/passwd"})), None);
    // A draft of only images whose bytes did not arrive is no draft.
    let mut back = Composers::default();
    back.restore(&bundled);
    assert!(back.drafts.is_empty(), "{:?}", back.drafts);
}

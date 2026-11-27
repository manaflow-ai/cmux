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

/// An image block of `bytes`, keyed `key`, as the page sends one.
fn keyed_block(bytes: &[u8], key: &str) -> Value {
    use base64::Engine as _;
    let data = base64::engine::general_purpose::STANDARD.encode(bytes);
    json!({"type": "image", "mimeType": "image/png", "data": data, "key": key})
}

fn png(seed: u8) -> Vec<u8> {
    let mut bytes = vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    bytes.extend([seed; 16]);
    bytes
}

fn keys_of(images: &[Value]) -> Vec<&str> {
    images.iter().filter_map(image_key).collect()
}

fn base(keys: &[&str]) -> Vec<String> {
    keys.iter().map(|k| (*k).to_owned()).collect()
}

#[test]
fn a_write_that_saw_base_keeps_another_panes_images_and_removes_only_its_own() {
    // Pane A wrote a1, pane B wrote b1 into the same draft (they share its id).
    let a1 = draft_images(Some(&json!([keyed_block(&png(1), "a1")])), &[]).unwrap();
    let b1 = draft_images(Some(&json!([keyed_block(&png(2), "b1")])), &[]).unwrap();
    let both = merged(&a1, b1.clone(), Some(&base(&[])));
    assert_eq!(keys_of(&both), ["a1", "b1"], "B's write keeps A's image");
    // A removes a1: it saw a1 and b1, and writes nothing.
    let after = merged(&both, Vec::new(), Some(&base(&["a1", "b1"])));
    assert_eq!(keys_of(&after), Vec::<&str>::new(), "a key in base and not written goes");
    // A removes a1 having seen only a1: B's b1 stays.
    let after = merged(&both, Vec::new(), Some(&base(&["a1"])));
    assert_eq!(keys_of(&after), ["b1"], "another pane's image stays");
    // An older client's keyless image is no one's to remove by key; no base replaces.
    let legacy = vec![json!({"id": "c".repeat(64), "mimeType": "image/png"})];
    assert_eq!(merged(&legacy, b1.clone(), Some(&base(&["b1"]))).len(), 2);
    assert_eq!(keys_of(&merged(&both, b1, None)), ["b1"], "without base the write is the list");
}

#[test]
fn equal_bytes_under_two_keys_are_two_images() {
    let bytes = png(3);
    let a = draft_images(Some(&json!([keyed_block(&bytes, "a")])), &[]).unwrap();
    let b = draft_images(Some(&json!([keyed_block(&bytes, "b")])), &[]).unwrap();
    assert_eq!(image_id(&a[0]), image_id(&b[0]), "one hash, kept once");
    let both = merged(&a, b, Some(&base(&[])));
    assert_eq!(keys_of(&both), ["a", "b"]);
    // B names its image by id, as a later write does: the held record's key is not taken.
    let again = json!([{"id": image_id(&both[0]).unwrap(), "key": "b"}]);
    let again = draft_images(Some(&again), &both).unwrap();
    assert_eq!(keys_of(&again), ["b"]);
    // B removes its copy; A's of the same bytes stays.
    let after = merged(&both, Vec::new(), Some(&base(&["b"])));
    assert_eq!(keys_of(&after), ["a"]);
    let mut c = Composers::default();
    let mac = Surface { id: "d-1".into(), name: "Mac".into(), kind: Some("app".into()) };
    let draft = Draft { surface: mac, text: String::new(), images: both, updated_at: 1, order: 1 };
    c.drafts.insert("d-1".into(), draft);
    assert_eq!(c.take_sent("d-1", &base(&["a"])), None, "b is still waiting");
    assert_eq!(keys_of(&c.drafts["d-1"].images), ["b"]);
}

#[test]
fn a_sent_prompt_takes_only_its_named_keys_of_its_named_draft() {
    let bytes = png(4);
    let images =
        draft_images(Some(&json!([keyed_block(&bytes, "a"), keyed_block(&png(5), "b")])), &[])
            .unwrap();
    let mut c = Composers::default();
    for id in ["d-1", "d-2"] {
        let surface = Surface { id: id.into(), name: "Mac".into(), kind: Some("app".into()) };
        let draft =
            Draft { surface, text: String::new(), images: images.clone(), updated_at: 1, order: 1 };
        c.drafts.insert(id.into(), draft);
    }
    assert_eq!(c.take_sent("d-1", &base(&["a"])), None);
    assert_eq!(keys_of(&c.drafts["d-1"].images), ["b"], "only the sent key goes");
    assert_eq!(keys_of(&c.drafts["d-2"].images), ["a", "b"], "another draft is untouched");
    assert!(c.take_sent("d-1", &base(&["b"])).is_some(), "an emptied draft stops composing");
    assert!(!c.drafts.contains_key("d-1"));
    assert_eq!(c.take_sent("gone", &base(&["a"])), None);
    let meta = json!({"id": "d-2", "keys": ["a"]});
    assert_eq!(sent_draft(Some(&meta)).unwrap(), Some(("d-2".into(), base(&["a"]))));
    assert_eq!(sent_draft(None).unwrap(), None);
    for bad in [json!({"id": "d"}), json!({"id": "d", "keys": [3]}), json!({"keys": []})] {
        assert!(sent_draft(Some(&bad)).is_err(), "{bad}");
    }
    let long = json!({"id": "d", "keys": ["k".repeat(MAX_DRAFT_KEY_CHARS + 1)]});
    assert!(sent_draft(Some(&long)).is_err());
    let hidden_key = json!([{"type": "image", "mimeType": "image/png", "data": "iVBORw0KGgo=", "key": "a\u{202E}"}]);
    assert!(draft_images(Some(&hidden_key), &[]).is_err());
}

#[test]
fn a_bundle_keeps_each_images_key_and_the_drafts_id() {
    let bytes = png(6);
    let images =
        draft_images(Some(&json!([keyed_block(&bytes, "a"), keyed_block(&bytes, "b")])), &[])
            .unwrap();
    let mut c = Composers::default();
    let id = "5f0c6a1e-0000-4000-8000-000000000001";
    let surface = Surface { id: id.into(), name: "Mac".into(), kind: Some("app".into()) };
    let draft =
        Draft { surface: surface.clone(), text: String::new(), images, updated_at: 1, order: 1 };
    c.drafts.insert(id.into(), draft);
    let mut back = Composers::default();
    back.restore(&c.bundled());
    assert_eq!(back.drafts[id].surface, surface, "the draft's id travels as its surface's");
    assert_eq!(keys_of(&back.drafts[id].images), ["a", "b"]);
    assert_eq!(
        carried_image(&json!({"id": "a".repeat(64), "key": "k\u{0}"})).unwrap().get("key"),
        None
    );
}

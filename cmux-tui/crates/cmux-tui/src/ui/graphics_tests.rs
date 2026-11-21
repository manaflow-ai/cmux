use base64::Engine as _;
use ghostty_vt::{Callbacks, KittyPlacement, KittyPlacementKey, Terminal};

use super::*;

#[test]
fn zero_pixel_resize_preserves_known_cell_metrics() {
    let detected = cell_pixels_from_terminal_size(120, 40, 0, 0);
    assert_eq!(detected, None);
    assert_eq!(resolve_cell_pixels(Some((11, 23)), detected), (11, 23));
}

#[test]
fn missing_initial_metrics_use_synthetic_fallback() {
    assert_eq!(resolve_cell_pixels(None, None), FALLBACK_CELL_PIXELS);
}

#[cfg(not(unix))]
#[test]
fn terminal_probe_does_not_write_queries_without_a_reply_reader() {
    let mut output = Vec::new();

    write_terminal_probe_queries(&mut output, true);

    assert!(output.is_empty(), "unread terminal queries were written: {output:?}");
}

#[test]
fn newly_detected_metrics_replace_known_metrics() {
    assert_eq!(resolve_cell_pixels(Some((8, 16)), Some((11, 23))), (11, 23));
}

#[test]
fn terminal_probe_finishes_after_kitty_and_da1_in_either_order() {
    assert!(terminal_probe_complete(b"\x1b_Gi=31;OK\x1b\\\x1b[?62;c"));
    assert!(terminal_probe_complete(b"\x1b[?62;c\x1b_Gi=31;OK\x1b\\"));
    assert!(terminal_probe_complete(b"\x1b_Gi=31;EINVAL\x1b\\\x1b[?62;c"));
}

#[test]
fn terminal_probe_finishes_at_da1_ordering_marker() {
    assert!(terminal_probe_complete(b"\x1b[?62;c"));
    assert!(!terminal_probe_complete(b"\x1b_Gi=31;OK\x1b\\"));
}

#[test]
fn terminal_probe_strips_replies_and_replays_user_input() {
    use crossterm::event::{Event, KeyCode, MouseButton, MouseEventKind};

    let parsed = parse_terminal_probe(
        b"a\x1b[4;800;1200t\x1b[I\x1b_Gi=31;OK\x1b\\\
              \x1b[200~pasted\x1b[201~\x1b[?62;c\x1b[<0;3;4Mb",
    );
    assert_eq!(parsed.window_pixels, Some((1200, 800)));
    assert_eq!(parsed.kitty_supported, Some(true));
    assert!(parsed.primary_device_attributes);
    assert_eq!(cell_pixels_from_window_size(120, 40, 1200, 800), Some((10, 20)),);

    let events = parse_pending_input(&parsed.pending_input);
    assert!(matches!(
        events.as_slice(),
        [
            Event::Key(first),
            Event::FocusGained,
            Event::Paste(paste),
            Event::Mouse(mouse),
            Event::Key(last),
        ] if first.code == KeyCode::Char('a')
            && paste == "pasted"
            && mouse.kind == MouseEventKind::Down(MouseButton::Left)
            && mouse.column == 2
            && mouse.row == 3
            && last.code == KeyCode::Char('b')
    ));
}

/// W5-Q (bench round 4 screen #4): a host's OSC 10/11 color reply that
/// arrives with the startup probe replies is no input. It once became
/// Alt+] and typed text in the first pane. A key typed after it stays.
#[cfg(unix)]
#[test]
fn w5q_startup_input_drops_host_color_replies() {
    use crossterm::event::{Event, KeyCode};

    let bytes = b"\x1b]10;rgb:fdfd/ffff/f1f1\x1b\\\x1b]11;rgb:2727/2828/2222\x07\x1b[?62;22ca";
    let parsed = parse_terminal_probe(bytes);
    assert!(parsed.primary_device_attributes);
    let input = split_pending_input(&parsed.pending_input);
    assert!(input.incomplete.is_empty(), "left over: {:?}", input.incomplete);
    assert!(
        matches!(input.events.as_slice(), [Event::Key(key)] if key.code == KeyCode::Char('a')),
        "a color reply became input: {:?}",
        input.events
    );

    // The reply's end came after the probe: the rest still is no input.
    let mut pending = split_pending_input(b"\x1b]11;rgb:2727/28");
    pending.append(b"28/2222\x1b\\b");
    assert!(pending.incomplete.is_empty(), "left over: {:?}", pending.incomplete);
    assert!(
        matches!(pending.events.as_slice(), [Event::Key(key)] if key.code == KeyCode::Char('b')),
        "a split color reply became input: {:?}",
        pending.events
    );
}

/// W5-Q review (PR B finding 3): Alt+] typed while the client probes
/// the host is Alt+], and the keys after it in the same read stay. The
/// startup reader once took the key after `ESC ]` with it, and a lone
/// `ESC ]` became Esc and `]`.
#[cfg(unix)]
#[test]
fn w5q_startup_input_keeps_alt_right_bracket_and_the_keys_after_it() {
    use crossterm::event::{Event, KeyCode, KeyModifiers};

    let keys = |events: &[Event]| -> Vec<(KeyCode, KeyModifiers)> {
        events
            .iter()
            .filter_map(|event| event.as_key_event().map(|key| (key.code, key.modifiers)))
            .collect()
    };
    let alt = (KeyCode::Char(']'), KeyModifiers::ALT);
    let input = split_pending_input(b"\x1b]a");
    assert!(input.incomplete.is_empty(), "left over: {:?}", input.incomplete);
    assert_eq!(keys(&input.events), [alt, (KeyCode::Char('a'), KeyModifiers::NONE)]);

    let input = split_pending_input(b"\x1b]\x1b[A");
    assert_eq!(keys(&input.events), [alt, (KeyCode::Up, KeyModifiers::NONE)]);

    // Nothing came after a lone `ESC ]` before the startup wait ended.
    assert_eq!(keys(&parse_incomplete_input_lossy(b"\x1b]")), [alt]);
    assert_eq!(
        keys(&parse_incomplete_input_lossy(b"\x1b]1")),
        [alt, (KeyCode::Char('1'), KeyModifiers::NONE)]
    );
    // The start of a color reply whose end never came is still no input.
    assert!(parse_incomplete_input_lossy(b"\x1b]11;rgb:27").is_empty());
}

#[test]
fn terminal_probe_preserves_fragmented_escape_input_without_dropping_bytes() {
    use crossterm::event::{Event, KeyCode};

    let events = parse_pending_input(b"\x1b[");
    assert!(events.is_empty(), "an incomplete CSI became synthetic key events: {events:?}");

    let mut pending = split_pending_input(b"\x1b[");
    pending.append(b"A");
    assert!(matches!(
        pending.events.as_slice(),
        [Event::Key(up)] if up.code == KeyCode::Up
    ));
    assert!(pending.incomplete.is_empty());
}

#[test]
fn terminal_probe_preserves_enhanced_csi_u_metadata() {
    use crossterm::event::{Event, KeyCode, KeyModifiers};

    let events = parse_pending_input(b"\x1b[38:49:49;4;49u");

    assert!(matches!(
        events.as_slice(),
        [Event::EnhancedKey(key)]
            if key.key_event.code == KeyCode::Char('&')
                && key.key_event.modifiers == KeyModifiers::SHIFT | KeyModifiers::ALT
                && key.shifted_key == Some('1')
                && key.base_layout_key == Some('1')
                && key.text == "1"
    ));
}

#[test]
fn terminal_probe_bounds_an_unfinished_startup_paste() {
    const EXPECTED_MAX_INCOMPLETE_BYTES: usize = 4 * 1024;

    let mut pending = split_pending_input(b"\x1b[200~");
    pending.append(&vec![b'x'; EXPECTED_MAX_INCOMPLETE_BYTES + 1]);

    assert!(
        pending.incomplete.len() <= EXPECTED_MAX_INCOMPLETE_BYTES,
        "an unfinished startup sequence retained {} bytes",
        pending.incomplete.len()
    );
}

#[test]
fn existing_base64_graphic_payload_is_borrowed() {
    let encoded: Arc<str> = Arc::from("AAAAAA==");
    let data = GraphicData::Base64(encoded.clone());

    let Cow::Borrowed(borrowed) = data.base64() else {
        panic!("existing base64 payload was copied");
    };
    assert_eq!(borrowed, encoded.as_ref());
    assert_eq!(borrowed.as_ptr(), encoded.as_ptr());
}

/// Remote browser frame data is supposed to be base64. Anything else
/// (an ESC ST that ends the APC early, then raw controls) is never
/// written to the terminal.
#[test]
fn sec_audit_non_base64_frame_data_is_never_transmitted() {
    let hostile: Arc<str> = Arc::from("AAAA\x1b\\\x1b]0;owned\x07\x1b[2J");
    let image = GraphicImage {
        key: GraphicImageKey { namespace: 0, surface: 1, image_id: 7 },
        generation: 1,
        width: 2,
        height: 2,
        format: GraphicFormat::Png,
        data: GraphicData::Base64(hostile),
    };
    let bytes = transmit_image(7, &image);
    let text = String::from_utf8_lossy(&bytes);
    assert!(!text.contains("owned") && !text.contains("\x1b[2J"), "{text:?}");
}

#[test]
fn processing_fence_uses_reserved_query_id() {
    let id = processing_fence_id(7);
    assert!(id >= PROCESSING_FENCE_ID_BASE);
    assert_eq!(
        String::from_utf8(processing_fence(id)).unwrap(),
        format!("\x1b_Gi={id},s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\")
    );
}

fn image(
    surface: SurfaceId,
    image_id: u32,
    generation: u64,
    format: GraphicFormat,
    data: &[u8],
) -> Arc<GraphicImage> {
    Arc::new(GraphicImage {
        key: GraphicImageKey { namespace: 0, surface, image_id },
        generation,
        width: 2,
        height: 2,
        format,
        data: GraphicData::Bytes(Arc::from(data)),
    })
}

fn placement(
    image: Arc<GraphicImage>,
    placement_id: u32,
    ordinal: u32,
    rect: Rect,
) -> GraphicPlacement {
    GraphicPlacement {
        key: GraphicPlacementKey { image: image.key, placement_id, ordinal },
        image,
        rect,
        pointer_frame_seq: None,
        columns: Some(u32::from(rect.width)),
        rows: Some(u32::from(rect.height)),
        source: None,
        x_offset: 0,
        y_offset: 0,
        z: 0,
    }
}

fn joined(batches: &[Vec<u8>]) -> String {
    String::from_utf8(batches.concat()).unwrap()
}

fn decoded_terminal_placement(
    width: u32,
    height: u32,
    sizing: &str,
) -> (KittyImage, KittyPlacement) {
    let mut terminal = Terminal::new(20, 8, 100, Callbacks::default()).unwrap();
    terminal.resize(20, 8, 10, 20).unwrap();
    let pixels = vec![255; usize::try_from(width * height * 3).unwrap()];
    let payload = base64::engine::general_purpose::STANDARD.encode(pixels);
    terminal.vt_write(
        format!("\x1b_Ga=T,t=d,f=24,i=201,p=1,s={width},v={height}{sizing},q=2;{payload}\x1b\\")
            .as_bytes(),
    );

    let snapshot = terminal.kitty_graphics_snapshot().unwrap();
    assert_eq!(snapshot.placements.len(), 1);
    (snapshot.image(201).unwrap().clone(), snapshot.placements[0].clone())
}

fn translate_terminal_placement(
    image: &KittyImage,
    placement: &KittyPlacement,
    pane: Rect,
) -> GraphicPlacement {
    kitty_graphic_placement(pane, 0, (10, 20), kitty_graphic_image(0, 9, image), placement).unwrap()
}

fn translated_terminal_placement(
    width: u32,
    height: u32,
    sizing: &str,
    pane: Rect,
) -> GraphicPlacement {
    let (image, placement) = decoded_terminal_placement(width, height, sizing);
    translate_terminal_placement(&image, &placement, pane)
}

fn emitted_placement(value: GraphicPlacement) -> String {
    let mut state = GraphicsState::default();
    let output = joined(&state.frame_batches(&[value]));
    let start = output.find("\x1b_Ga=p").expect("placement command");
    let command = &output[start..];
    let end = command.find("\x1b\\").expect("placement terminator") + 2;
    command[..end].to_string()
}

fn rounded_ratio(value: u32, numerator: u32, denominator: u32) -> u32 {
    u32::try_from(
        (u128::from(value) * u128::from(numerator) + u128::from(denominator) / 2)
            / u128::from(denominator),
    )
    .unwrap()
}

fn rendered_pixel_size(value: &GraphicPlacement) -> (u32, u32) {
    let source = value.source.unwrap_or(GraphicSourceRect {
        x: 0,
        y: 0,
        width: value.image.width,
        height: value.image.height,
    });
    match (value.columns, value.rows) {
        (None, None) => (source.width, source.height),
        (Some(columns), None) => {
            let width = columns * 10;
            (width, rounded_ratio(width, source.height, source.width))
        }
        (None, Some(rows)) => {
            let height = rows * 20;
            (rounded_ratio(height, source.width, source.height), height)
        }
        (Some(columns), Some(rows)) => (columns * 10, rows * 20),
    }
}

fn assert_pixel_geometry(
    value: &GraphicPlacement,
    pane: Rect,
    source: GraphicSourceRect,
    sizing: (Option<u32>, Option<u32>),
    pixels: (u32, u32),
) {
    assert_eq!(value.source, Some(source));
    assert_eq!((value.columns, value.rows), sizing);
    assert_eq!(rendered_pixel_size(value), pixels);
    let left = u32::from(value.rect.x - pane.x) * 10 + value.x_offset;
    let top = u32::from(value.rect.y - pane.y) * 20 + value.y_offset;
    assert!(left + pixels.0 <= u32::from(pane.width) * 10);
    assert!(top + pixels.1 <= u32::from(pane.height) * 20);
}

#[test]
fn raw_rgb_and_rgba_payloads_are_chunked_with_dimensions() {
    let rgb = image(1, 1, 1, GraphicFormat::Rgb, &vec![255; 3_075]);
    let rgba = image(2, 2, 1, GraphicFormat::Rgba, &[255; 16]);
    let rgb_key = rgb.key;
    let rgba_key = rgba.key;
    let mut state = GraphicsState::default();
    let output = joined(&state.frame_batches(&[
        placement(rgb, 0, 0, Rect { x: 0, y: 0, width: 2, height: 2 }),
        placement(rgba, 0, 0, Rect { x: 3, y: 0, width: 2, height: 2 }),
    ]));
    assert!(
        output.contains(&format!("a=t,t=d,f=24,i={},s=2,v=2,q=2,m=1;", state.image_ids[&rgb_key]))
    );
    assert!(output.contains("\x1b_Gq=2,m=0;"));
    assert!(
        output.contains(&format!("a=t,t=d,f=32,i={},s=2,v=2,q=2,m=0;", state.image_ids[&rgba_key]))
    );
}

#[test]
fn dynamic_ids_do_not_alias_distant_surfaces_or_anonymous_placements() {
    let first = image(1, 7, 1, GraphicFormat::Rgb, &[255; 12]);
    let distant = image(2_000_000_001, 7, 1, GraphicFormat::Rgb, &[0; 12]);
    let mut state = GraphicsState::default();
    let output = joined(&state.frame_batches(&[
        placement(first.clone(), 0, 0, Rect { x: 0, y: 0, width: 1, height: 1 }),
        placement(first, 0, 1, Rect { x: 1, y: 0, width: 1, height: 1 }),
        placement(distant, 0, 0, Rect { x: 2, y: 0, width: 1, height: 1 }),
    ]));
    assert_eq!(state.image_ids.len(), 2);
    assert_eq!(state.placement_ids.len(), 3);
    assert_eq!(output.matches("a=t,t=d").count(), 2, "one transmit per image");
    assert_eq!(output.matches("a=p").count(), 3);
    assert_eq!(state.image_ids.values().copied().collect::<HashSet<_>>().len(), 2);
    assert_eq!(state.placement_ids.values().copied().collect::<HashSet<_>>().len(), 3);
}

#[test]
fn large_scene_id_allocation_performs_linear_work() {
    const IMAGE_COUNT: u32 = 256;
    let placements = (1..=IMAGE_COUNT)
        .rev()
        .map(|image_id| {
            placement(
                image(19, image_id, 1, GraphicFormat::Rgb, &[255; 12]),
                image_id,
                0,
                Rect {
                    x: u16::try_from(image_id % 80).unwrap(),
                    y: u16::try_from(image_id / 80).unwrap(),
                    width: 1,
                    height: 1,
                },
            )
        })
        .collect::<Vec<_>>();
    let mut state = GraphicsState::default();

    state.frame_batches(&placements);

    assert_eq!(
        state.operation_counts.image_id_allocation_checks, IMAGE_COUNT as usize,
        "image allocation must perform one used-ID check per image: {:?}",
        state.operation_counts
    );
    assert_eq!(
        state.operation_counts.placement_id_allocation_checks, IMAGE_COUNT as usize,
        "placement allocation must perform one used-ID check per placement: {:?}",
        state.operation_counts
    );
}

#[test]
fn stale_image_cleanup_uses_one_linear_retain_pass() {
    const SURVIVOR_COUNT: u32 = 128;
    let initial = (1..=SURVIVOR_COUNT * 2)
        .map(|image_id| {
            placement(
                image(20, image_id, 1, GraphicFormat::Rgb, &[255; 12]),
                image_id,
                0,
                Rect {
                    x: u16::try_from(image_id % 80).unwrap(),
                    y: u16::try_from(image_id / 80).unwrap(),
                    width: 1,
                    height: 1,
                },
            )
        })
        .collect::<Vec<_>>();
    let survivors = initial[..SURVIVOR_COUNT as usize].to_vec();
    let mut state = GraphicsState::default();
    state.frame_batches(&initial);
    state.reset_operation_counts();

    state.frame_batches(&survivors);

    assert_eq!(
        state.operation_counts.stale_image_retain_passes, 1,
        "stale-image cleanup repeated a retain pass: {:?}",
        state.operation_counts
    );
    assert_eq!(
        state.operation_counts.stale_image_retain_visits, SURVIVOR_COUNT as usize,
        "stale-image cleanup must visit each survivor once: {:?}",
        state.operation_counts
    );
}

#[test]
fn late_lower_inner_image_id_preserves_outer_ids_and_equal_z_compositing() {
    let mut lower = placement(
        image(21, 7, 1, GraphicFormat::Rgb, &[7; 12]),
        1,
        0,
        Rect { x: 40, y: 20, width: 1, height: 1 },
    );
    let mut higher = placement(
        image(21, 90, 1, GraphicFormat::Rgb, &[90; 12]),
        1,
        0,
        Rect { x: 0, y: 0, width: 1, height: 1 },
    );
    lower.z = 8;
    higher.z = -8;
    let lower_key = lower.image.key;
    let higher_key = higher.image.key;
    let mut state = GraphicsState::default();

    state.frame_batches(std::slice::from_ref(&higher));
    let old_higher_id = state.image_ids[&higher_key];
    let update = joined(&state.frame_batches(&[higher.clone(), lower.clone()]));

    assert!(
        state.image_ids[&lower_key] < state.image_ids[&higher_key],
        "outer IDs must preserve inner image-ID order even when allocation first saw another z: {:?}",
        state.image_ids
    );
    assert_eq!(state.image_ids[&higher_key], old_higher_id);
    assert!(!update.contains("a=d,d=I"), "{update:?}");
    assert_eq!(update.matches("a=t,t=d").count(), 1, "{update:?}");
    assert_eq!(update.matches("a=p").count(), 1, "{update:?}");

    lower.z = 0;
    higher.z = 0;
    state.frame_batches(&[higher, lower]);
    assert!(
        state.image_ids[&lower_key] < state.image_ids[&higher_key],
        "equal-z outer IDs must ignore input order and y position: {:?}",
        state.image_ids
    );
}

#[test]
fn descending_image_insertion_keeps_existing_ids_and_linear_transmission() {
    const IMAGE_COUNT: u32 = 256;
    let mut state = GraphicsState::default();
    let mut placements = Vec::new();
    let mut transmissions = 0;
    let mut deletions = 0;

    for image_id in (1..=IMAGE_COUNT).rev() {
        placements.push(placement(
            image(22, image_id, 1, GraphicFormat::Rgb, &[255; 12]),
            image_id,
            0,
            Rect {
                x: u16::try_from(image_id % 80).unwrap(),
                y: u16::try_from(image_id / 80).unwrap(),
                width: 1,
                height: 1,
            },
        ));
        let output = joined(&state.frame_batches(&placements));
        transmissions += output.matches("a=t,t=d").count();
        deletions += output.matches("a=d,d=I").count();
    }

    assert_eq!(
        transmissions, IMAGE_COUNT as usize,
        "inserting one lower image retransmitted existing pixel payloads"
    );
    assert_eq!(deletions, 0, "stable image IDs must not delete existing host images");
    let mut ordered = state.image_ids.iter().collect::<Vec<_>>();
    ordered.sort_unstable_by_key(|(key, _)| **key);
    assert!(
        ordered.windows(2).all(|pair| pair[0].1 < pair[1].1),
        "outer image IDs must preserve inner image ordering: {:?}",
        state.image_ids
    );
}

#[test]
fn relabel_finds_inserted_image_in_compositing_order_across_surfaces() {
    let inserted = GraphicImageKey { namespace: 9, surface: 9, image_id: 1 };
    let existing = GraphicImageKey { namespace: 0, surface: 1, image_id: 2 };
    let mut state = GraphicsState::default();
    state.image_ids.insert(existing, 1);
    state.used_image_ids.insert(1);
    let mut batches = Vec::new();

    state.prepare_image_ids(&[inserted, existing], &mut batches);

    assert!(state.image_ids[&inserted] < state.image_ids[&existing]);
}

#[test]
fn reconnect_namespace_prevents_surface_and_generation_reuse_from_aliasing() {
    let rect = Rect { x: 0, y: 0, width: 2, height: 2 };
    let first = GraphicPlacement::browser(10, 7, rect, 1, 20, 20, "AAAA".to_string());
    let reconnected = GraphicPlacement::browser(11, 7, rect, 1, 20, 20, "BBBB".to_string());
    assert_ne!(first.image.key, reconnected.image.key);

    let mut state = GraphicsState::default();
    state.frame_batches(&[first]);
    let output = joined(&state.frame_batches(&[reconnected]));
    assert!(output.contains("a=d,d=I"));
    assert!(output.contains("a=t,t=d"));
    assert_eq!(state.image_ids.len(), 1);
}

#[test]
fn placement_preserves_crop_offsets_and_z() {
    let image = image(4, 9, 1, GraphicFormat::Rgba, &[255; 16]);
    let image_key = image.key;
    let mut value = placement(image, 12, 0, Rect { x: 4, y: 6, width: 2, height: 3 });
    value.source = Some(GraphicSourceRect { x: 1, y: 2, width: 3, height: 4 });
    value.x_offset = 5;
    value.y_offset = 6;
    value.z = -7;
    let mut state = GraphicsState::default();
    let output = joined(&state.frame_batches(&[value]));
    assert!(output.contains(&format!(
        "\x1b7\x1b[7;5H\x1b_Ga=p,i={},p=1,x=1,y=2,w=3,h=4,X=5,Y=6,c=2,r=3,z=-7,C=1,q=2;\x1b\\\x1b8",
        state.image_ids[&image_key]
    )));
}

#[test]
fn retransmit_deletes_old_generation_before_replacing_pixels() {
    let key_image = image(5, 1, 1, GraphicFormat::Rgb, &[255; 12]);
    let mut state = GraphicsState::default();
    state.frame_batches(&[placement(key_image, 1, 0, Rect { x: 0, y: 0, width: 1, height: 1 })]);
    let replacement = image(5, 1, 2, GraphicFormat::Rgb, &[0; 12]);
    let output = joined(&state.frame_batches(&[placement(
        replacement,
        1,
        0,
        Rect { x: 0, y: 0, width: 1, height: 1 },
    )]));
    let delete = output.find("a=d,d=I").unwrap();
    let transmit = output.find("a=t,t=d").unwrap();
    assert!(delete < transmit);
}

#[test]
fn unchanged_frame_does_not_replace_existing_placement() {
    let image = image(5, 2, 1, GraphicFormat::Rgb, &[255; 12]);
    let value = placement(image, 1, 0, Rect { x: 2, y: 3, width: 1, height: 1 });
    let mut state = GraphicsState::default();
    state.frame_batches(std::slice::from_ref(&value));

    let output = joined(&state.frame_batches(&[value]));
    assert!(!output.contains("a=p"), "{output:?}");
    assert!(output.is_empty(), "{output:?}");
}

#[test]
fn host_scene_invalidation_restores_an_unchanged_image_after_clear() {
    let image = image(5, 20, 1, GraphicFormat::Rgb, &[255; 12]);
    let value = placement(image, 1, 0, Rect { x: 2, y: 3, width: 2, height: 2 });
    let mut state = GraphicsState::default();
    let mut host = Terminal::new(20, 8, 100, Callbacks::default()).unwrap();
    host.resize(20, 8, 10, 20).unwrap();

    for batch in state.frame_batches(std::slice::from_ref(&value)) {
        host.vt_write(&batch);
    }
    assert_eq!(host.kitty_graphics_snapshot().unwrap().placements.len(), 1);

    host.vt_write(b"\x1b[2J");
    assert!(host.kitty_graphics_snapshot().unwrap().is_empty());

    state.invalidate_host_scene();
    for batch in state.frame_batches(&[value]) {
        host.vt_write(&batch);
    }
    let restored = host.kitty_graphics_snapshot().unwrap();
    assert_eq!(restored.images.len(), 1);
    assert_eq!(restored.placements.len(), 1);
}

#[test]
fn changed_geometry_deletes_old_placement_before_replacing_it() {
    let image = image(5, 3, 1, GraphicFormat::Rgb, &[255; 12]);
    let initial = placement(image.clone(), 1, 0, Rect { x: 2, y: 3, width: 1, height: 1 });
    let moved = placement(image, 1, 0, Rect { x: 4, y: 5, width: 2, height: 1 });
    let mut state = GraphicsState::default();
    state.frame_batches(&[initial]);

    let output = joined(&state.frame_batches(&[moved]));
    let delete = output.find("a=d,d=i").expect("old placement deletion");
    let replace = output.find("a=p").expect("replacement placement");
    assert!(delete < replace, "{output:?}");
}

#[test]
fn image_retransmit_restores_every_placement_after_image_deletion() {
    let first = image(5, 4, 1, GraphicFormat::Rgb, &[255; 12]);
    let mut state = GraphicsState::default();
    state.frame_batches(&[
        placement(first.clone(), 1, 0, Rect { x: 0, y: 0, width: 1, height: 1 }),
        placement(first, 2, 0, Rect { x: 2, y: 0, width: 1, height: 1 }),
    ]);

    let replacement = image(5, 4, 2, GraphicFormat::Rgb, &[0; 12]);
    let output = joined(&state.frame_batches(&[
        placement(replacement.clone(), 1, 0, Rect { x: 0, y: 0, width: 1, height: 1 }),
        placement(replacement, 2, 0, Rect { x: 2, y: 0, width: 1, height: 1 }),
    ]));
    let delete = output.find("a=d,d=I").expect("old image deletion");
    let transmit = output.find("a=t,t=d").expect("replacement transmission");
    let first_place = output.find("a=p").expect("first restored placement");
    assert!(delete < transmit && transmit < first_place, "{output:?}");
    assert_eq!(output.matches("a=p").count(), 2, "{output:?}");
}

#[test]
fn stale_placement_is_deleted_without_dropping_shared_image_then_image_is_freed() {
    let shared = image(6, 1, 1, GraphicFormat::Rgb, &[255; 12]);
    let one = placement(shared.clone(), 0, 0, Rect { x: 0, y: 0, width: 1, height: 1 });
    let two = placement(shared, 0, 1, Rect { x: 1, y: 0, width: 1, height: 1 });
    let mut state = GraphicsState::default();
    state.frame_batches(&[one.clone(), two]);

    let placement_cleanup = joined(&state.frame_batches(&[one]));
    assert!(placement_cleanup.contains("a=d,d=i"));
    assert!(!placement_cleanup.contains("d=I"));
    assert_eq!(state.transmitted.len(), 1);

    let image_cleanup = joined(&state.frame_batches(&[]));
    assert!(image_cleanup.contains("a=d,d=I"));
    assert!(state.transmitted.is_empty());
    assert!(state.image_ids.is_empty());
    assert!(state.placement_ids.is_empty());
}

#[test]
fn terminal_placement_clips_to_pane_and_adjusts_source_pixels() {
    let inner_image = KittyImage {
        id: 3,
        number: 0,
        generation: 1,
        width: 100,
        height: 80,
        format: KittyImageFormat::Rgba,
        data: Arc::from(vec![0; 100 * 80 * 4]),
    };
    let inner = KittyPlacement {
        key: KittyPlacementKey { image_id: 3, placement_id: 0, ordinal: 1 },
        image_id: 3,
        placement_id: 0,
        is_internal: true,
        x_offset: 4,
        y_offset: 5,
        source_x: 10,
        source_y: 20,
        source_width: 80,
        source_height: 40,
        columns: 0,
        rows: 0,
        grid_cols: 9,
        grid_rows: 3,
        pixel_width: 80,
        pixel_height: 40,
        viewport_col: -2,
        viewport_row: -1,
        viewport_visible: true,
        anchor: None,
        z: 3,
    };
    let outer = kitty_graphic_placement(
        Rect { x: 10, y: 5, width: 5, height: 2 },
        0,
        (10, 20),
        kitty_graphic_image(0, 9, &inner_image),
        &inner,
    )
    .unwrap();
    assert_eq!(outer.rect, Rect { x: 10, y: 5, width: 5, height: 2 });
    assert_eq!(outer.source, Some(GraphicSourceRect { x: 26, y: 35, width: 50, height: 25 }));
    assert_eq!((outer.columns, outer.rows), (None, None));
    assert_eq!((outer.x_offset, outer.y_offset), (0, 0));
    assert_eq!(outer.z, 3);
}

#[test]
fn terminal_offsets_at_right_and_bottom_edges_are_contained_inside_pane() {
    let inner_image = KittyImage {
        id: 4,
        number: 0,
        generation: 1,
        width: 100,
        height: 100,
        format: KittyImageFormat::Rgba,
        data: Arc::from(vec![0; 100 * 100 * 4]),
    };
    let inner = KittyPlacement {
        key: KittyPlacementKey { image_id: 4, placement_id: 2, ordinal: 0 },
        image_id: 4,
        placement_id: 2,
        is_internal: false,
        x_offset: 4,
        y_offset: 5,
        source_x: 0,
        source_y: 0,
        source_width: 100,
        source_height: 100,
        columns: 2,
        rows: 2,
        grid_cols: 2,
        grid_rows: 2,
        pixel_width: 20,
        pixel_height: 40,
        viewport_col: 3,
        viewport_row: 2,
        viewport_visible: true,
        anchor: None,
        z: 0,
    };
    let pane = Rect { x: 10, y: 5, width: 5, height: 4 };
    let outer =
        kitty_graphic_placement(pane, 0, (10, 20), kitty_graphic_image(0, 9, &inner_image), &inner)
            .unwrap();
    assert_eq!(outer.rect, Rect { x: 13, y: 7, width: 2, height: 2 });
    assert_eq!(outer.source, Some(GraphicSourceRect { x: 0, y: 0, width: 50, height: 50 }));
    assert_eq!((outer.x_offset, outer.y_offset), (4, 5));
    let pixels = rendered_pixel_size(&outer);
    assert!(
        u32::from(outer.rect.x - pane.x) * 10 + outer.x_offset + pixels.0
            <= u32::from(pane.width) * 10
    );
    assert!(
        u32::from(outer.rect.y - pane.y) * 20 + outer.y_offset + pixels.1
            <= u32::from(pane.height) * 20
    );
}

#[test]
fn terminal_native_size_omits_outer_columns_and_rows() {
    let command = emitted_placement(translated_terminal_placement(
        3,
        2,
        "",
        Rect { x: 0, y: 0, width: 20, height: 8 },
    ));
    assert!(!command.contains(",c="), "{command:?}");
    assert!(!command.contains(",r="), "{command:?}");
}

#[test]
fn terminal_column_only_size_omits_outer_rows() {
    let command = emitted_placement(translated_terminal_placement(
        20,
        10,
        ",c=2",
        Rect { x: 0, y: 0, width: 20, height: 8 },
    ));
    assert!(command.contains(",c=2"), "{command:?}");
    assert!(!command.contains(",r="), "{command:?}");
}

#[test]
fn terminal_row_only_size_omits_outer_columns() {
    let command = emitted_placement(translated_terminal_placement(
        10,
        40,
        ",r=2",
        Rect { x: 0, y: 0, width: 20, height: 8 },
    ));
    assert!(!command.contains(",c="), "{command:?}");
    assert!(command.contains(",r=2"), "{command:?}");
}

#[test]
fn terminal_explicit_cell_size_emits_both_outer_axes() {
    let command = emitted_placement(translated_terminal_placement(
        20,
        40,
        ",c=2,r=2",
        Rect { x: 0, y: 0, width: 20, height: 8 },
    ));
    assert!(command.contains(",c=2,r=2"), "{command:?}");
}

#[test]
fn terminal_clipping_resolves_both_axes_and_crops_source_inside_pane() {
    let outer = translated_terminal_placement(
        20,
        40,
        ",X=4,Y=5,c=2,r=2",
        Rect { x: 0, y: 0, width: 2, height: 2 },
    );
    assert_eq!(outer.rect, Rect { x: 0, y: 0, width: 2, height: 2 });
    assert_eq!(outer.source, Some(GraphicSourceRect { x: 0, y: 0, width: 10, height: 20 }));
    assert_eq!((outer.x_offset, outer.y_offset), (4, 5));

    let command = emitted_placement(outer);
    assert!(command.contains("x=0,y=0,w=10,h=20,X=4,Y=5,c=1,r=1"), "{command:?}");
}

#[test]
fn native_clipping_uses_rendered_pixels_on_every_edge() {
    let horizontal_pane = Rect { x: 10, y: 5, width: 1, height: 1 };
    let (horizontal_image, horizontal) = decoded_terminal_placement(15, 10, ",X=4");

    let right = translate_terminal_placement(&horizontal_image, &horizontal, horizontal_pane);
    assert_eq!((right.x_offset, right.y_offset), (4, 0));
    assert_pixel_geometry(
        &right,
        horizontal_pane,
        GraphicSourceRect { x: 0, y: 0, width: 6, height: 10 },
        (None, None),
        (6, 10),
    );

    let mut left_placement = horizontal;
    left_placement.viewport_col = -1;
    let left = translate_terminal_placement(&horizontal_image, &left_placement, horizontal_pane);
    assert_eq!((left.x_offset, left.y_offset), (0, 0));
    assert_pixel_geometry(
        &left,
        horizontal_pane,
        GraphicSourceRect { x: 6, y: 0, width: 9, height: 10 },
        (None, None),
        (9, 10),
    );

    let vertical_pane = Rect { x: 10, y: 5, width: 2, height: 1 };
    let (vertical_image, vertical) = decoded_terminal_placement(15, 10, ",Y=15");
    let bottom = translate_terminal_placement(&vertical_image, &vertical, vertical_pane);
    assert_eq!((bottom.x_offset, bottom.y_offset), (0, 15));
    assert_pixel_geometry(
        &bottom,
        vertical_pane,
        GraphicSourceRect { x: 0, y: 0, width: 15, height: 5 },
        (None, None),
        (15, 5),
    );

    let mut top_placement = vertical;
    top_placement.viewport_row = -1;
    let top = translate_terminal_placement(&vertical_image, &top_placement, vertical_pane);
    assert_eq!((top.x_offset, top.y_offset), (0, 0));
    assert_pixel_geometry(
        &top,
        vertical_pane,
        GraphicSourceRect { x: 0, y: 5, width: 15, height: 5 },
        (None, None),
        (15, 5),
    );
}

#[test]
fn column_only_clipping_preserves_inferred_rows_on_every_edge() {
    let horizontal_pane = Rect { x: 10, y: 5, width: 2, height: 1 };
    let (horizontal_image, horizontal) = decoded_terminal_placement(20, 10, ",X=4,c=2");

    let right = translate_terminal_placement(&horizontal_image, &horizontal, horizontal_pane);
    assert_eq!((right.x_offset, right.y_offset), (4, 0));
    assert_pixel_geometry(
        &right,
        horizontal_pane,
        GraphicSourceRect { x: 0, y: 0, width: 10, height: 10 },
        (Some(1), None),
        (10, 10),
    );

    let mut left_placement = horizontal;
    left_placement.viewport_col = -1;
    let left = translate_terminal_placement(&horizontal_image, &left_placement, horizontal_pane);
    assert_eq!((left.x_offset, left.y_offset), (0, 0));
    assert_pixel_geometry(
        &left,
        horizontal_pane,
        GraphicSourceRect { x: 6, y: 0, width: 10, height: 10 },
        (Some(1), None),
        (10, 10),
    );

    let vertical_pane = Rect { x: 10, y: 5, width: 2, height: 1 };
    let (vertical_image, vertical) = decoded_terminal_placement(20, 10, ",Y=15,c=2");
    let bottom = translate_terminal_placement(&vertical_image, &vertical, vertical_pane);
    assert_eq!((bottom.x_offset, bottom.y_offset), (0, 15));
    assert_pixel_geometry(
        &bottom,
        vertical_pane,
        GraphicSourceRect { x: 0, y: 0, width: 20, height: 5 },
        (Some(2), None),
        (20, 5),
    );

    let mut top_placement = vertical;
    top_placement.viewport_row = -1;
    let top = translate_terminal_placement(&vertical_image, &top_placement, vertical_pane);
    assert_eq!((top.x_offset, top.y_offset), (0, 0));
    assert_pixel_geometry(
        &top,
        vertical_pane,
        GraphicSourceRect { x: 0, y: 5, width: 20, height: 5 },
        (Some(2), None),
        (20, 5),
    );
}

#[test]
fn row_only_clipping_preserves_inferred_columns_on_every_edge() {
    let horizontal_pane = Rect { x: 10, y: 5, width: 1, height: 2 };
    let (horizontal_image, horizontal) = decoded_terminal_placement(10, 40, ",X=5,r=2");

    let right = translate_terminal_placement(&horizontal_image, &horizontal, horizontal_pane);
    assert_eq!((right.x_offset, right.y_offset), (5, 0));
    assert_pixel_geometry(
        &right,
        horizontal_pane,
        GraphicSourceRect { x: 0, y: 0, width: 5, height: 40 },
        (None, Some(2)),
        (5, 40),
    );

    let mut left_placement = horizontal;
    left_placement.viewport_col = -1;
    let left = translate_terminal_placement(&horizontal_image, &left_placement, horizontal_pane);
    assert_eq!((left.x_offset, left.y_offset), (0, 0));
    assert_pixel_geometry(
        &left,
        horizontal_pane,
        GraphicSourceRect { x: 5, y: 0, width: 5, height: 40 },
        (None, Some(2)),
        (5, 40),
    );

    let vertical_pane = Rect { x: 10, y: 5, width: 1, height: 2 };
    let (vertical_image, vertical) = decoded_terminal_placement(10, 40, ",Y=5,r=2");
    let bottom = translate_terminal_placement(&vertical_image, &vertical, vertical_pane);
    assert_eq!((bottom.x_offset, bottom.y_offset), (0, 5));
    assert_pixel_geometry(
        &bottom,
        vertical_pane,
        GraphicSourceRect { x: 0, y: 0, width: 10, height: 20 },
        (None, Some(1)),
        (10, 20),
    );

    let mut top_placement = vertical;
    top_placement.viewport_row = -1;
    let top = translate_terminal_placement(&vertical_image, &top_placement, vertical_pane);
    assert_eq!((top.x_offset, top.y_offset), (0, 0));
    assert_pixel_geometry(
        &top,
        vertical_pane,
        GraphicSourceRect { x: 0, y: 15, width: 10, height: 20 },
        (None, Some(1)),
        (10, 20),
    );
}

#[test]
fn browser_png_and_terminal_raw_images_share_one_scene() {
    let browser = GraphicPlacement::browser(
        0,
        1,
        Rect { x: 0, y: 0, width: 10, height: 5 },
        4,
        100,
        50,
        "AAAA".to_string(),
    );
    let terminal = placement(
        image(2, 3, 5, GraphicFormat::Rgba, &[255; 16]),
        0,
        0,
        Rect { x: 10, y: 0, width: 2, height: 2 },
    );
    let mut state = GraphicsState::default();
    let output = joined(&state.frame_batches(&[browser, terminal]));
    assert!(output.contains("f=100"));
    assert!(output.contains("f=32"));
    assert_eq!(state.image_ids.len(), 2);
}

use base64::Engine as _;

use super::*;
use crate::Callbacks;

/// One `size`x`size` RGBA image with id `id`, placed at the cursor.
fn placed_image(id: u32, size: u32) -> Vec<u8> {
    let pixels = vec![0x5a_u8; (size * size * 4) as usize];
    let data = base64::engine::general_purpose::STANDARD.encode(pixels);
    format!("\x1b_Ga=T,t=d,f=32,i={id},p=1,s={size},v={size},c=2,r=1,q=2;{data}\x1b\\").into_bytes()
}

fn terminal() -> Terminal {
    Terminal::new(40, 10, 100, Callbacks::default()).unwrap()
}

#[test]
fn a_terminal_without_images_has_generation_zero_and_an_empty_replay() {
    let term = terminal();
    assert_eq!(term.kitty_image_generation().unwrap(), 0);
    let (_, stats) = term.encode_kitty_replay(u64::MAX).unwrap();
    assert!(stats.is_empty(), "{stats:?}");
}

#[test]
fn the_replay_recreates_the_image_and_its_placement_in_a_viewer() {
    let mut host = terminal();
    host.vt_write(b"before\r\n");
    host.vt_write(&placed_image(7, 2));
    let generation = host.kitty_image_generation().unwrap();
    assert!(generation > 0);
    let (stream, stats) = host.encode_kitty_replay(u64::MAX).unwrap();
    assert_eq!((stats.images, stats.placements, stats.skipped_images), (1, 1, 0), "{stats:?}");
    assert_eq!(stats.image_bytes, 2 * 2 * 4);
    assert_eq!(stats.bytes, stream.len() as u64);
    // Encoding reads only.
    assert_eq!(host.kitty_image_generation().unwrap(), generation);
    // The same cut encodes the same stream.
    assert_eq!(host.encode_kitty_replay(u64::MAX).unwrap().0, stream);

    let mut viewer = terminal();
    viewer.vt_write(b"before\r\n");
    viewer.apply_kitty_replay(&stream).unwrap();
    let shown = viewer.kitty_graphics_snapshot().unwrap();
    assert_eq!(shown.images.iter().map(|image| image.id).collect::<Vec<_>>(), vec![7]);
    assert_eq!(shown.images[0].data.len(), 2 * 2 * 4);
    assert_eq!(shown.placements.len(), 1);
}

#[test]
fn the_byte_cap_skips_images_and_reports_them() {
    let mut host = terminal();
    host.vt_write(&placed_image(1, 4));
    host.vt_write(b"\r\n");
    host.vt_write(&placed_image(2, 4));
    // One 4x4 RGBA image fits (64 bytes), the older one does not.
    let (_, stats) = host.encode_kitty_replay(64).unwrap();
    assert_eq!((stats.images, stats.skipped_images), (1, 1), "{stats:?}");
    assert_eq!(stats.image_bytes, 64);
    let (_, none) = host.encode_kitty_replay(0).unwrap();
    assert_eq!((none.images, none.skipped_images, none.placements), (0, 2, 0), "{none:?}");
}

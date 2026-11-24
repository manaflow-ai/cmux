use super::*;

fn bytes(mood: Mood, seed: u64) -> Vec<u8> {
    render(mood, seed, 160, 100).to_srgb8(seed)
}

/// The same mood and seed give the same picture, byte for byte, every time.
#[test]
fn a_seed_always_draws_the_same_picture() {
    for mood in Mood::ALL {
        assert_eq!(bytes(mood, 42), bytes(mood, 42), "{mood:?}");
        let a = encode_png(&render(mood, 42, 96, 60), 42).unwrap();
        let b = encode_png(&render(mood, 42, 96, 60), 42).unwrap();
        assert_eq!(a, b, "{mood:?} png");
    }
}

/// Another seed gives another picture, and every mood looks different from the others.
#[test]
fn seeds_and_moods_vary_the_picture() {
    for mood in Mood::ALL {
        assert_ne!(bytes(mood, 1), bytes(mood, 2), "{mood:?}");
    }
    let all: Vec<_> = Mood::ALL.into_iter().map(|m| bytes(m, 9)).collect();
    for (i, a) in all.iter().enumerate() {
        for b in all.iter().skip(i + 1) {
            assert_ne!(a, b);
        }
    }
}

fn mean_rgb(canvas: &Canvas) -> (f32, f32, f32) {
    let (mut r, mut g, mut b) = (0.0, 0.0, 0.0);
    let n = (canvas.width * canvas.height) as f32;
    for y in 0..canvas.height {
        for x in 0..canvas.width {
            let c = canvas.at(x, y);
            r += c.r;
            g += c.g;
            b += c.b;
        }
    }
    (r / n, g / n, b / n)
}

/// Each mood keeps its colours: blue sky, aqua lagoon, dark aurora, green meadow.
#[test]
fn each_mood_keeps_its_palette() {
    let (r, g, b) = mean_rgb(&render(Mood::Sky, 3, 160, 100));
    assert!(b > r && b > 0.3, "sky {r} {g} {b}");
    let (r, g, b) = mean_rgb(&render(Mood::Lagoon, 3, 160, 100));
    assert!(g > r && b > r, "lagoon {r} {g} {b}");
    let c = render(Mood::Aurora, 3, 160, 100);
    let top = c.at(80, 2);
    assert!(top.luminance() < 0.1, "aurora top {top:?}");
    let low = render(Mood::Meadow, 3, 160, 100).at(10, 90);
    assert!(low.g > low.r && low.g > low.b, "meadow ground {low:?}");
}

/// Every pixel is a finite colour and the picture is neither blank nor blown out.
#[test]
fn the_picture_is_finite_and_exposed() {
    for mood in Mood::ALL {
        let c = render(mood, 11, 120, 75);
        for y in 0..c.height {
            for x in 0..c.width {
                let p = c.at(x, y);
                assert!(p.r.is_finite() && p.g.is_finite() && p.b.is_finite(), "{mood:?} {x},{y}");
            }
        }
        let (r, g, b) = mean_rgb(&c);
        let mean = (r + g + b) / 3.0;
        assert!((0.02..0.9).contains(&mean), "{mood:?} mean {mean}");
    }
}

#[test]
fn ids_parse_back_to_their_mood() {
    for mood in Mood::ALL {
        assert_eq!(Mood::parse(mood.id()), Some(mood));
        assert_eq!(Mood::parse(mood.id().trim_start_matches("aero-")), Some(mood));
    }
    assert_eq!(Mood::parse("aero-volcano"), None);
    assert_eq!(SHIPPED.map(|(m, _)| m), Mood::ALL);
}

#[test]
fn a_zero_size_is_one_pixel() {
    let c = render(Mood::Sky, 1, 0, 0);
    assert_eq!((c.width, c.height), (1, 1));
}

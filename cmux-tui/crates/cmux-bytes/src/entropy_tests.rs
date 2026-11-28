use super::*;

#[test]
fn random_reads_near_eight_and_text_low() {
    let mut x = 0x2545F4914F6CDD1Du64;
    let random: Vec<u8> = (0..1 << 20)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x as u8
        })
        .collect();
    assert!(bits_per_byte(&random, 8192) > 7.8, "{}", bits_per_byte(&random, 8192));
    let text = b"fn main() { println!(\"hello\"); }\n".repeat(1000);
    assert!(bits_per_byte(&text, 8192) < 5.5);
}

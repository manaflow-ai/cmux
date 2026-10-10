use super::*;

#[test]
fn graphics_status_events_preserve_structured_localization_data() {
    assert_eq!(
        subscribed_event_json(&MuxEvent::GraphicsStatus(
            GraphicsStatus::KittyImageBudgetUpdateFailed {
                retry_exhausted: true,
                summary: Arc::<str>::from("surface 7: offline"),
            },
        )),
        json!({
            "event": "graphics-status",
            "kind": "kitty-image-budget-update-failed",
            "retry_exhausted": true,
            "summary": "surface 7: offline",
        })
    );
    assert_eq!(
        subscribed_event_json(&MuxEvent::GraphicsStatus(
            GraphicsStatus::CellPixelUpdateRetriesExhausted {
                attempts: 5,
                remaining: 2,
                cell_pixels: (8, 16),
            },
        )),
        json!({
            "event": "graphics-status",
            "kind": "cell-pixel-update-retries-exhausted",
            "attempts": 5,
            "remaining": 2,
            "cell_width": 8,
            "cell_height": 16,
        })
    );
}

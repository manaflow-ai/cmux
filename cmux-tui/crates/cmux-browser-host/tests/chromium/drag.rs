//! `input.drag` on a real Chromium (parity 05 `drop`). A module of the
//! `chromium` test target (helpers from its root).

use super::*;

/// A draggable source and a drop zone; the drop records the page's own
/// drag data and whether the drop event was trusted.
const DRAG_PAGE: &str = "<div id=s draggable=true ondragstart=\"event.dataTransfer.setData('text/plain', 'payload')\" \
    style=\"position:absolute;left:20px;top:20px;width:80px;height:40px;background:#ccc\">drag</div>\
    <div id=d ondragover=\"event.preventDefault()\" \
    ondrop=\"event.preventDefault(); this.textContent = 'dropped:' + event.dataTransfer.getData('text/plain') + ':' + event.isTrusted\" \
    style=\"position:absolute;left:300px;top:20px;width:120px;height:80px;background:#eee\">drop</div>";

/// driver-protocol.md `input.drag`: HTML5 drag and drop fires on the page
/// (dragstart, then drop with the source's data, trusted). Chromium hands
/// the drag to the driver (CDP drag interception), so its data never goes
/// to the system's drag pasteboard.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn a_drag_drops_the_sources_data_on_the_target() {
    let port = serve();
    let chromium = HeadlessChromium::launch(&HeadlessOptions::new(files::chrome().into()))
        .expect("launch Chromium");
    let driver = CdpDriver::attach_browser(chromium.connection().clone(), AGENT, Arc::new(|_| {}))
        .expect("attach to Chromium");
    let call = |method: &str, params: Value| -> Value {
        driver.call(method, &params).unwrap_or_else(|error| panic!("{method}: {error}"))
    };
    let target = call("tabs.open", json!({}))["targetId"].as_str().unwrap().to_owned();
    call(
        "tab.navigate",
        json!({"targetId": target, "url": format!("http://127.0.0.1:{port}/second"), "waitUntil": "load"}),
    );
    call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source": "(html) => { document.body.innerHTML = html; }", "args": [DRAG_PAGE]}),
    );
    call(
        "input.drag",
        json!({"targetId": target, "path": [{"x": 60, "y": 40}, {"x": 360, "y": 60}], "button": "left", "modifiers": []}),
    );
    let dropped = call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source": "() => document.getElementById('d').textContent"}),
    );
    assert_eq!(dropped, json!("dropped:payload:true"));
    // The tab's mouse is up again: a click after the drag is a plain click.
    let clicked = call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source": "() => { window.downs = 0; document.addEventListener('mousedown', () => window.downs++); return 0; }"}),
    );
    assert_eq!(clicked, json!(0));
    for kind in ["down", "up"] {
        call(
            "input.mouse",
            json!({"targetId": target, "type": kind, "x": 360, "y": 60, "button": "left"}),
        );
    }
    let downs = call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source": "() => window.downs"}),
    );
    assert_eq!(downs, json!(1), "the mouse must not stay pressed after a drag");
}

package cmuxmux

import "encoding/json"

func parseEvent(raw map[string]any) Event {
	name, _ := raw["event"].(string)
	mustDecode := func(out any) bool {
		encoded, err := json.Marshal(raw)
		if err != nil {
			return false
		}
		return json.Unmarshal(encoded, out) == nil
	}
	switch name {
	case "tree-changed":
		return TreeChangedEvent{}
	case "empty":
		return EmptyEvent{}
	case "surface-output", "surface-exited", "title-changed", "bell":
		var event SurfaceEvent
		if mustDecode(&event) {
			return event
		}
	case "surface-resized":
		var event SurfaceResizedEvent
		if mustDecode(&event) {
			return event
		}
	case "vt-state":
		var event VtStateEvent
		if mustDecode(&event) {
			return event
		}
	case "output":
		var event OutputEvent
		if mustDecode(&event) {
			return event
		}
	case "resized":
		var event ResizedEvent
		if mustDecode(&event) {
			return event
		}
	case "detached":
		var event DetachedEvent
		if mustDecode(&event) {
			return event
		}
	}
	return UnknownEvent{Name: name, Raw: raw}
}

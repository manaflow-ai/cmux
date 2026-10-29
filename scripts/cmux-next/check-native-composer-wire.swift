// Compile this with Overlay/Generated/*.swift and NativePopupModel+Validation.swift.
// Input is emitted by NATIVE_COMPOSER_WIRE_FIXTURES=<path> bun test test/native-composer-popup.test.tsx.
import Foundation

@main struct NativeComposerWireCheck {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let objects = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        precondition(objects.count >= 4, "Expected models from every mounted consumer")
        var sliderCount = 0
        for object in objects {
            guard let model = NativePopupModel.decode(object) else {
                fatalError("Actual generated native decoder rejected composer model: \(object)")
            }
            // Sections render headings only; nested choices would be invisible in the host.
            precondition(model.rows.allSatisfy { $0.children == nil && $0.kind != .choice })
            var invalid = object
            invalid["rows"] = [["id": "invalid", "kind": "choice", "label": "No options"]]
            precondition(NativePopupModel.decode(invalid) == nil)
            for row in model.rows where row.kind == .slider {
                sliderCount += 1
                guard let slider = row.slider else { fatalError("Slider metadata was dropped") }
                precondition(slider.stops.count == Int(row.maximum ?? -1) + 1)
                precondition(slider.stops.allSatisfy { !$0.value.isEmpty && !$0.label.isEmpty })
                precondition(slider.selectedValue == nil || slider.stops.contains { $0.value == slider.selectedValue })
                precondition(slider.defaultValue == nil || slider.stops.contains { $0.value == slider.defaultValue })
                precondition(slider.recommendedValue == nil || slider.stops.contains { $0.value == slider.recommendedValue })
                precondition(slider.minimumLabel != nil && slider.maximumLabel != nil && slider.accessibilityLabel != nil)
            }
        }
        precondition(sliderCount > 0, "Expected an emitted effort slider")
        print("Native composer generated decoder accepted \(objects.count) mounted models")
    }
}

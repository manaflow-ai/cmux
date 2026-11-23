// swift-testing declares a cross-import overlay for CoreGraphics; a test that imports both looks for
// this module. On a Mac it adds attachment support; here it only has to exist.
@_exported import CoreGraphics

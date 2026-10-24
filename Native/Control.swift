import AppKit
import AVFoundation
import SwiftUI

final class InputInjector {
    var bounds = CGRect.zero
    private var keys: Set<UInt16> = []
    private var buttons: Set<Int> = []
    private var lastPoint = CGPoint.zero
    private var lastClick: (Int, CGPoint, TimeInterval, Int64)?
    func apply(_ input: RemoteInput) {
        guard AXIsProcessTrusted(), input.x.isFinite, input.y.isFinite else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = CGEventFlags(rawValue: input.flags)
        var event: CGEvent?
        switch input.kind {
        case "move", "down", "up":
            guard bounds.width > 0, bounds.height > 0, (0...1).contains(input.x), (0...1).contains(input.y), (0...2).contains(input.button) else { return }
            let point = CGPoint(x: bounds.minX + input.x * bounds.width, y: bounds.minY + input.y * bounds.height)
            lastPoint = point
            let button: CGMouseButton = input.button == 0 ? .left : input.button == 1 ? .right : .center
            var type: CGEventType = .mouseMoved
            if input.kind == "down" { type = button == .left ? .leftMouseDown : button == .right ? .rightMouseDown : .otherMouseDown; buttons.insert(input.button) }
            else if input.kind == "up" { type = button == .left ? .leftMouseUp : button == .right ? .rightMouseUp : .otherMouseUp; buttons.remove(input.button) }
            else if buttons.contains(0) { type = .leftMouseDragged }
            else if buttons.contains(1) { type = .rightMouseDragged }
            event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            if input.kind == "down" {
                let now = ProcessInfo.processInfo.systemUptime
                let previous = lastClick
                let count: Int64 = previous.map { $0.0 == input.button && now - $0.2 < NSEvent.doubleClickInterval && hypot(point.x - $0.1.x, point.y - $0.1.y) < 5 ? $0.3 + 1 : 1 } ?? 1
                lastClick = (input.button, point, now, count)
                event?.setIntegerValueField(.mouseEventClickState, value: count)
            } else if input.kind == "up", let previous = lastClick { event?.setIntegerValueField(.mouseEventClickState, value: previous.3) }
        case "keyDown", "keyUp", "flags":
            guard input.code < 128 else { return }
            let down = input.kind == "keyDown" || (input.kind == "flags" && input.button == 1)
            if down { keys.insert(input.code) } else { keys.remove(input.code) }
            event = CGEvent(keyboardEventSource: source, virtualKey: input.code, keyDown: down)
        case "scroll":
            event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(max(-2000, min(2000, input.y))), wheel2: Int32(max(-2000, min(2000, input.x))), wheel3: 0)
        default: return
        }
        event?.flags = flags; event?.post(tap: .cghidEventTap)
    }
    func releaseAll() {
        for key in keys { CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap) }
        for button in buttons {
            CGEvent(mouseEventSource: nil, mouseType: button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp, mouseCursorPosition: lastPoint, mouseButton: button == 0 ? .left : button == 1 ? .right : .center)?.post(tap: .cghidEventTap)
        }
        keys.removeAll(); buttons.removeAll()
    }
}

/// Decoding happens off-main; at most one decoded surface waits for presentation.
final class VideoPresenter {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var scheduled = false
    private var enabled = false
    weak var canvas: NativeVideoView?
    var onPresented: (() -> Void)?
    func present(_ pixels: CVPixelBuffer) {
        lock.lock(); guard enabled else { lock.unlock(); return }; latest = pixels
        let schedule = !scheduled; scheduled = true; lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let pixels = self.latest; self.latest = nil; self.scheduled = false; self.lock.unlock()
            if let pixels { self.canvas?.present(pixels); self.onPresented?() }
        }
    }
    func begin() { lock.lock(); latest = nil; enabled = true; lock.unlock() }
    func clear(keepImage: Bool = false) { lock.lock(); latest = nil; enabled = false; lock.unlock(); if !keepImage { DispatchQueue.main.async { [weak self] in self?.canvas?.clearDisplay() } } }
}

final class NativeVideoView: NSView {
    let display = AVSampleBufferDisplayLayer()
    var sendInput: ((RemoteInput) -> Void)?
    var releaseInput: (() -> Void)?
    var releaseShortcut: (() -> Void)?
    var desktopScale: DesktopScale = .fit { didSet { needsLayout = true } }
    var inputEnabled = true { didSet { updateCursor(); if inputEnabled && !oldValue { window?.makeFirstResponder(self) } } }
    var hideLocalCursor = true { didSet { updateCursor() } }
    private var cursorHidden = false
    private var pointerInside = false
    private var viewport: CGRect { DisplayGeometry.viewport(source: pixelsSize, bounds: bounds, scale: desktopScale, backing: window?.backingScaleFactor ?? 2) }
    private var pixelsSize = CGSize(width: 16, height: 9)
    private var focusObserver: NSObjectProtocol?
    private var tracking: NSTrackingArea?
    private var modifierCodes: Set<UInt16> = []
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        display.videoGravity = .resize; layer?.masksToBounds = true; layer?.addSublayer(display)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() { super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true); display.frame = viewport; CATransaction.commit() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        if let window { focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.releaseInput?(); self?.modifierCodes.removeAll(); self?.showCursor() } }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        self.tracking = tracking; addTrackingArea(tracking)
    }
    func present(_ pixels: CVPixelBuffer) {
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        if pixelsSize != size { pixelsSize = size; needsLayout = true; layoutSubtreeIfNeeded() }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format) == noErr, let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary], let attachment = attachments.first { attachment[kCMSampleAttachmentKey_DisplayImmediately] = true }
        if #available(macOS 14.0, *), !RuntimeCompatibility.legacyAPIs {
            if display.sampleBufferRenderer.status == .failed { display.sampleBufferRenderer.flush() }
            if display.sampleBufferRenderer.isReadyForMoreMediaData { display.sampleBufferRenderer.enqueue(sample) }
        } else {
            if display.status == .failed { display.flush() }
            if display.isReadyForMoreMediaData { display.enqueue(sample) }
        }
    }
    func clearDisplay() {
        if #available(macOS 14.0, *), !RuntimeCompatibility.legacyAPIs {
            display.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        } else {
            display.flushAndRemoveImage()
        }
    }
    private func mouse(_ event: NSEvent, kind: String) {
        guard inputEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        let rect = viewport
        pointerInside = rect.contains(point); updateCursor()
        guard rect.width > 0, rect.height > 0 else { return }
        if !rect.contains(point), kind == "down" || (kind == "move" && NSEvent.pressedMouseButtons == 0) { return }
        sendInput?(RemoteInput(kind: kind, x: max(0, min(1, (point.x - rect.minX) / rect.width)), y: max(0, min(1, (point.y - rect.minY) / rect.height)), button: min(2, event.buttonNumber), flags: UInt64(event.modifierFlags.rawValue)))
    }
    private func showCursor() { if cursorHidden { NSCursor.unhide(); cursorHidden = false } }
    private func updateCursor() {
        let shouldHide = hideLocalCursor && inputEnabled && pointerInside && window?.isKeyWindow == true
        if shouldHide && !cursorHidden { NSCursor.hide(); cursorHidden = true }
        else if !shouldHide { showCursor() }
    }
    override func mouseEntered(with event: NSEvent) { pointerInside = viewport.contains(convert(event.locationInWindow, from: nil)); updateCursor() }
    override func mouseExited(with event: NSEvent) { pointerInside = false; showCursor() }
    override func mouseMoved(with event: NSEvent) { mouse(event, kind: "move") }
    override func mouseDragged(with event: NSEvent) { mouse(event, kind: "move") }
    override func rightMouseDragged(with event: NSEvent) { mouse(event, kind: "move") }
    override func otherMouseDragged(with event: NSEvent) { mouse(event, kind: "move") }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); mouse(event, kind: "down") }
    override func mouseUp(with event: NSEvent) { mouse(event, kind: "up") }
    override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); mouse(event, kind: "down") }
    override func rightMouseUp(with event: NSEvent) { mouse(event, kind: "up") }
    override func otherMouseDown(with event: NSEvent) { mouse(event, kind: "down") }
    override func otherMouseUp(with event: NSEvent) { mouse(event, kind: "up") }
    override func scrollWheel(with event: NSEvent) { guard inputEnabled else { return }; sendInput?(RemoteInput(kind: "scroll", x: event.scrollingDeltaX, y: event.scrollingDeltaY, flags: UInt64(event.modifierFlags.rawValue))) }
    override func keyDown(with event: NSEvent) { if handleLocalShortcut(event) { return }; guard inputEnabled else { super.keyDown(with: event); return }; sendInput?(RemoteInput(kind: "keyDown", code: event.keyCode, flags: UInt64(event.modifierFlags.rawValue))) }
    override func keyUp(with event: NSEvent) { guard inputEnabled else { return }; sendInput?(RemoteInput(kind: "keyUp", code: event.keyCode, flags: UInt64(event.modifierFlags.rawValue))) }
    override func flagsChanged(with event: NSEvent) {
        guard inputEnabled else { return }
        let masks: [UInt16: NSEvent.ModifierFlags] = [54: .command, 55: .command, 56: .shift, 60: .shift, 58: .option, 61: .option, 59: .control, 62: .control, 57: .capsLock, 63: .function]
        let down = masks[event.keyCode].map { event.modifierFlags.contains($0) } ?? false
        if down { modifierCodes.insert(event.keyCode) } else { modifierCodes.remove(event.keyCode) }
        sendInput?(RemoteInput(kind: "flags", code: event.keyCode, button: down ? 1 : 0, flags: UInt64(event.modifierFlags.rawValue)))
    }
    private func handleLocalShortcut(_ event: NSEvent) -> Bool {
        if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option, .command] { releaseInput?(); releaseShortcut?(); showCursor(); return true }
        return false
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleLocalShortcut(event) { return true }
        if event.keyCode == 3, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .command] { return false }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift], event.keyCode == 2 { releaseInput?(); return false }
        guard inputEnabled, window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    deinit { if cursorHidden { NSCursor.unhide() }; if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) } }
}

struct RemoteCanvas: NSViewRepresentable {
    let presenter: VideoPresenter
    var scale: DesktopScale
    var inputEnabled: Bool
    var hideCursor: Bool
    var input: (RemoteInput) -> Void
    var release: () -> Void
    var releaseShortcut: () -> Void
    func makeNSView(context: Context) -> NativeVideoView {
        let view = NativeVideoView(); presenter.canvas = view
        updateNSView(view, context: context); return view
    }
    func updateNSView(_ view: NativeVideoView, context: Context) {
        presenter.canvas = view; view.sendInput = input; view.releaseInput = release
        view.releaseShortcut = releaseShortcut; view.desktopScale = scale
        view.inputEnabled = inputEnabled; view.hideLocalCursor = hideCursor
    }
}

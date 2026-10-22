import AppKit
import ApplicationServices

// MARK: - Pure laws (asserted offline by --smoke-selection)

/// The gesture law behind P5's floating button: a press-release pair counts as
/// a selection when it DRAGGED past `dragThreshold` (a text sweep) or was a
/// multi-click (double/triple select words/paragraphs). Pure so the thresholds
/// are assertable without GUI; the controller feeds it live event fields.
enum SelectionGesture {
    static let dragThreshold: CGFloat = 12

    static func qualifies(down: CGPoint, up: CGPoint, clickCount: Int) -> Bool {
        let dx = up.x - down.x
        let dy = up.y - down.y
        // Displacement, not per-axis: a diagonal sweep is as much a selection
        // as a horizontal one. Origin-flips between coordinate systems cancel,
        // which is also why the event wrapper below can compare locations.
        let distance = (dx * dx + dy * dy).squareRoot()
        return distance >= dragThreshold || clickCount >= 2
    }

    /// Event-typed wrapper the monitor path would use. Click count takes the
    /// MAX of the pair — the up event carries the settled count, but the down
    /// of a triple-click already reports 3.
    static func qualifies(mouseDown: NSEvent, mouseUp: NSEvent) -> Bool {
        qualifies(
            down: mouseDown.locationInWindow,
            up: mouseUp.locationInWindow,
            clickCount: max(mouseDown.clickCount, mouseUp.clickCount)
        )
    }

    /// Events landing inside any of Mia's own windows (chat panel,
    /// Settings, the button itself) never count as foreign selections. The
    /// controller supplies the live window frames; the containment law is pure.
    static func isInside(point: CGPoint, frames: [CGRect]) -> Bool {
        frames.contains { $0.contains(point) }
    }

    /// Immediate-send decision: only when the user opted in AND there is real
    /// text — an empty capture falls back to the quote-prefill path rather
    /// than sending a blank turn.
    static func shouldSendImmediately(enabled: Bool, text: String) -> Bool {
        enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Placement law for the button: below the release point (≈ the selection's
/// tail end), left-aligned with it, clamped into the visible bounds so it can
/// never sit off-screen or under the Dock/menu bar.
enum Anchor {
    static let buttonSize: CGFloat = 28
    static let offset: CGFloat = 16

    static func clamp(point: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX - buttonSize),
            y: min(max(point.y - offset, bounds.minY), bounds.maxY - buttonSize)
        )
    }
}

// MARK: - Controller

/// P5 selection floating button. Watches the global mouse stream (no permission
/// needed for that), and on a selection-like gesture borrows the clipboard for
/// a momentary ⌘C in the source app — the same trick every "lookup" button
/// uses — then surfaces a small nonactivating button. Clicking hands the text
/// to the P2 quote channel (or sends it when "Send selection immediately" is
/// on, via the closure AppDelegate installs).
@MainActor
final class SelectionButtonController {
    /// Settings › Chat, default ON — `object(forKey:)` so a never-written key
    /// reads as ON; `bool(forKey:)` would read it as off.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "selectionButtonEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "selectionButtonEnabled") }
    }

    /// "Send selection immediately", default OFF: quoting into the composer
    /// first is the reversible default; sending is one opt-in step away.
    static var sendImmediatelyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "selectionSendImmediately") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "selectionSendImmediately") }
    }

    /// Polling budget for the ⌘C round-trip: ~20ms apart, ~150ms total. Apps
    /// that take longer to write the pasteboard simply don't get a button —
    /// better silent than a spinner for what is a glance feature.
    private static let pollInterval: TimeInterval = 0.02
    private static let pollAttempts = 7
    private static let autoDismissInterval: TimeInterval = 6

    private let onInvoke: (String) -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var panel: NSPanel?
    private var buttonView: SelectionButtonView?
    private var dismissWork: DispatchWorkItem?
    private var escTap: CFMachPort?
    private var escSource: CFRunLoopSource?
    /// Press awaiting its release, in Cocoa screen coordinates.
    private var pendingDown: (point: CGPoint, clickCount: Int)?
    /// Reentrancy guard across the whole async ⌘C round-trip.
    private var isCapturing = false
    private var capturedText: String?

    private var isVisible: Bool { panel?.isVisible ?? false }

    init(onInvoke: @escaping (String) -> Void) {
        self.onInvoke = onInvoke
    }

    func start() {
        // Global monitor: events delivered to OTHER apps only, and mouse
        // watching needs no permission. Scroll joins the mask because a
        // visible button is stale the moment the page moves under it.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handleGlobal(event) }
        }
        // Local monitor: our own windows' presses suppress gesture pairing
        // (a drag inside Mia is never a foreign selection) and an
        // in-app click retires a visible button — except on the button
        // itself, whose own mouseUp is the click.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .leftMouseDown, event.window !== self?.panel {
                    self?.hide()
                }
                self?.pendingDown = nil
            }
            return event
        }
    }

    // MARK: - Gesture stream

    private func handleGlobal(_ event: NSEvent) {
        switch event.type {
        case .scrollWheel:
            if isVisible { hide() }
        case .leftMouseDown:
            if isVisible { hide() }
            // NSEvent.mouseLocation, not the event's own coordinates: global
            // monitors report locations in the CG top-left origin, and the
            // live query sidesteps that ambiguity for placement entirely.
            let point = NSEvent.mouseLocation
            if SelectionGesture.isInside(point: point, frames: ownWindowFrames()) {
                pendingDown = nil
            } else {
                pendingDown = (point, event.clickCount)
            }
        case .leftMouseUp:
            // "不重复触发": while the button is up, a new gesture retires it
            // instead of stacking a second capture.
            guard !isVisible, !isCapturing, let down = pendingDown else {
                pendingDown = nil
                return
            }
            pendingDown = nil
            let point = NSEvent.mouseLocation
            guard !SelectionGesture.isInside(point: point, frames: ownWindowFrames()),
                  SelectionGesture.qualifies(
                      down: down.point, up: point,
                      clickCount: max(down.clickCount, event.clickCount)
                  ) else { return }
            captureSelection(releaseAt: point)
        default:
            break
        }
    }

    private func ownWindowFrames() -> [CGRect] {
        // Every visible Mia window — chat panel, Settings, popovers and
        // the button itself — is "us"; presses there are never selections.
        NSApp.windows.filter { $0.isVisible }.map(\.frame)
    }

    // MARK: - Clipboard round-trip

    private func captureSelection(releaseAt: CGPoint) {
        // Silent skip when disabled or untrusted: no permission dialogs from
        // a background mouse watcher, ever — Settings owns that conversation.
        guard Self.isEnabled, AXIsProcessTrusted(), !isCapturing else { return }
        isCapturing = true

        let pasteboard = NSPasteboard.general
        let savedCount = pasteboard.changeCount
        var savedItems: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var snapshot: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { snapshot[type] = data }
            }
            if !snapshot.isEmpty { savedItems.append(snapshot) }
        }

        postCommandC()

        pollPasteboard(savedCount: savedCount, savedItems: savedItems, attempt: 0) { [weak self] text in
            guard let self else { return }
            self.isCapturing = false
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.capturedText = text
            self.show(at: releaseAt)
        }
    }

    /// kVK_ANSI_C with ⌘ held, posted at the HID tap so the frontmost (source)
    /// app performs the copy. All failures silent — every optional here can be
    /// nil on an exotic configuration, and the feature degrades to "no button".
    private func postCommandC() {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func pollPasteboard(
        savedCount: Int,
        savedItems: [[NSPasteboard.PasteboardType: Data]],
        attempt: Int,
        then done: @escaping (String?) -> Void
    ) {
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount != savedCount {
            let text = pasteboard.string(forType: .string)
            restorePasteboard(savedCount: savedCount, savedItems: savedItems)
            done(text)
        } else if attempt >= Self.pollAttempts {
            done(nil)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollInterval) { [weak self] in
                self?.pollPasteboard(savedCount: savedCount, savedItems: savedItems, attempt: attempt + 1, then: done)
            }
        }
    }

    /// Puts the user's clipboard back. Only when the copy actually changed it —
    /// clear-and-rewrite of identical data still bumps changeCount, which
    /// wakes every clipboard manager for nothing. Restore failures are silent:
    /// a briefly stale clipboard must never cost the user their answer.
    private func restorePasteboard(savedCount: Int, savedItems: [[NSPasteboard.PasteboardType: Data]]) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != savedCount, !savedItems.isEmpty else { return }
        let items = savedItems.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snapshot { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    // MARK: - The button

    private func show(at point: CGPoint) {
        if panel == nil { makeButton() }
        guard let panel,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
        else { return }
        panel.setFrameOrigin(Anchor.clamp(point: point, in: screen.visibleFrame))
        // Fade in: a 28pt dot popping at full opacity reads as a glitch of the
        // source app; 120ms is enough to register as intentional chrome.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        armAutoDismiss()
        installEscTap()
    }

    func hide() {
        dismissWork?.cancel()
        dismissWork = nil
        removeEscTap()
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    private func armAutoDismiss() {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoDismissInterval, execute: work)
    }

    /// Esc dismissal while visible. Global NSEvent monitors never receive key
    /// events, so this needs a listen-only CGEventTap — which itself needs the
    /// Accessibility trust the capture already required, so a failed tap just
    /// means Esc won't work (click/scroll/timeout still do).
    private func installEscTap() {
        removeEscTap()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if type == .keyDown,
                   event.getIntegerValueField(.keyboardEventKeycode) == 53, // Esc
                   let refcon {
                    let controller = Unmanaged<SelectionButtonController>.fromOpaque(refcon).takeUnretainedValue()
                    DispatchQueue.main.async { controller.hide() }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        escTap = tap
        escSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEscTap() {
        if let escTap {
            CGEvent.tapEnable(tap: escTap, enable: false)
            if let escSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), escSource, .defaultMode)
            }
        }
        escSource = nil
        escTap = nil
    }

    private func makeButton() {
        let view = SelectionButtonView()
        view.onTap = { [weak self] in
            guard let self else { return }
            let text = capturedText ?? ""
            capturedText = nil
            hide()
            onInvoke(text)
        }
        // Chromeless, nonactivating, floating: it must sit OVER the source app
        // without taking focus from it — the same contract as the chat panel.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Anchor.buttonSize, height: Anchor.buttonSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        self.panel = panel
        buttonView = view
    }
}

/// The 28pt circular button itself: bubble glyph, hover lift, plain AppKit
/// drawing. An NSHostingView here would drag in SwiftUI's whole machinery for
/// one circle — the app's perf rules say prefer the cheapest identical look.
private final class SelectionButtonView: NSView {
    var onTap: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }

    private static let glyph: NSImage? = {
        guard let symbol = NSImage(
            systemSymbolName: "bubble.left.and.bubble.right.fill",
            accessibilityDescription: "Ask Mia"
        ) else { return nil }
        // Template glyphs draw black; tint once, at load, to the label color
        // so draw(_:) stays a cheap blit.
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor.labelColor.set()
        let rect = NSRect(origin: .zero, size: symbol.size)
        symbol.draw(in: rect)
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
    }()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Hover grows the disc a hair instead of swapping colors — on a
        // 28pt target a color flip reads as flicker, a size change as intent.
        let inset: CGFloat = hovered ? 1 : 2.5
        let disc = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))
        NSColor.windowBackgroundColor.withAlphaComponent(hovered ? 0.98 : 0.9).setFill()
        disc.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        disc.lineWidth = 0.5
        disc.stroke()
        if let glyph = Self.glyph {
            let side: CGFloat = 14
            let origin = CGPoint(
                x: bounds.midX - side / 2,
                y: bounds.midY - side / 2
            )
            glyph.draw(in: NSRect(origin: origin, size: CGSize(width: side, height: side)))
        }
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseUp(with event: NSEvent) { onTap?() }
}

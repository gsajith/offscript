import AppKit
import ClosetalkCore
import SwiftUI

/// What the island shows.
@MainActor
@Observable
final class IslandModel {
    enum Phase { case recording, transcribing }

    var phase = Phase.recording
    var levels = WaveformLevels()
    /// Drives the appear and disappear animation of the pill inside the panel.
    var isVisible = false
}

/// The small pill near the top of the screen while Closetalk listens: live bars while recording, a
/// spinner while transcribing. It must never take focus, because dictation pastes into whatever app is in
/// front, so it's a non-activating panel that ignores the mouse.
@MainActor
final class RecordingIsland {
    private static let size = NSSize(width: 120, height: 36)
    /// Gap between the menu bar (or notch) and the pill.
    private static let topGap: CGFloat = 8

    let model = IslandModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // The pill draws its own.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: IslandView(model: model))
    }

    func showRecording() {
        model.phase = .recording
        model.levels = WaveformLevels()
        show()
    }

    func showTranscribing() {
        model.phase = .transcribing
        show()
    }

    func hide() {
        guard model.isVisible else { return }
        model.isVisible = false
        // Let the pill animate out before the panel goes.
        let work = DispatchWorkItem { [panel] in panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func show() {
        hideWork?.cancel()
        if !model.isVisible {
            let screen = Self.screenBeingTypedOn() ?? NSScreen.main ?? NSScreen.screens[0]
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - Self.size.width / 2,
                                         y: screen.visibleFrame.maxY - Self.size.height - Self.topGap))
        }
        // Ordered in without activating Closetalk, so focus stays in the app being dictated into.
        panel.orderFrontRegardless()
        model.isVisible = true
    }

    /// The screen holding the front app's frontmost window, which is where the text will land. Window
    /// bounds from the window list don't need Screen Recording, unlike window titles.
    private static func screenBeingTypedOn() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let window = windows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
              }),
              let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict),
              let primary = NSScreen.screens.first
        else { return screenWithMouse() }
        // The window list measures from the top of the primary screen, AppKit from its bottom.
        let flipped = CGRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
        let best = NSScreen.screens.max { $0.frame.intersection(flipped).area < $1.frame.intersection(flipped).area }
        if let best, best.frame.intersects(flipped) { return best }
        return screenWithMouse()
    }

    private static func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

private struct IslandView: View {
    let model: IslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Capsule().fill(.black.opacity(0.85))
            Capsule().strokeBorder(.white.opacity(0.12))
            switch model.phase {
            case .recording: Bars(levels: model.levels.values)
            case .transcribing: ThinkingDots(animated: !reduceMotion)
            }
        }
        .frame(width: 120, height: 36)
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        .opacity(model.isVisible ? 1 : 0)
        .scaleEffect(model.isVisible || reduceMotion ? 1 : 0.8)
        .animation(.snappy(duration: 0.2), value: model.isVisible)
        .environment(\.colorScheme, .dark)
    }
}

/// Three dots pulsing in turn while the words are worked out. A system spinner draws dark grey on the
/// black pill, whatever the tint.
private struct ThinkingDots: View {
    let animated: Bool

    var body: some View {
        TimelineView(.animation(paused: !animated)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(.white)
                        .frame(width: 6, height: 6)
                        .opacity(animated ? 0.35 + 0.65 * (sin(t * 6 - Double(i)) * 0.5 + 0.5) : 0.8)
                }
            }
        }
    }
}

/// One bar per recent chunk of audio, newest on the right.
private struct Bars: View {
    let levels: [Double]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: 3 + levels[i] * 17)
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
    }
}

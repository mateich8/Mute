import AppKit
import SwiftUI

/// App-wide keyboard shortcuts via a local event monitor. Letter keys are
/// suppressed while a text field has focus so typing stays unaffected.
@MainActor
enum KeyboardShortcuts {
    static func install() {
        // Monitor callbacks arrive on the main thread.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    private static func handle(_ event: NSEvent) -> Bool {
        let ui = UIState.shared
        let player = Player.shared
        let editingText = NSApp.keyWindow?.firstResponder is NSTextView

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let shift = flags.contains(.shift)
        let char = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // Esc always works: close overlays in priority order.
        if event.keyCode == 53 {
            if ui.zenMode { withAnimation(.smooth(duration: 0.3)) { ui.zenMode = false }; return true }
            if ui.searchVisible { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { ui.searchVisible = false; ui.searchText = "" }; return true }
            if !ui.albumMultiSelection.isEmpty { withAnimation(.smooth(duration: 0.2)) { ui.albumMultiSelection = [] }; return true }
            if ui.showQueue { withAnimation(.smooth(duration: 0.35)) { ui.showQueue = false }; return true }
            return false
        }
        // Cmd+F / Cmd+Shift+Z work even while editing text.
        if cmd && char == "f" {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { ui.searchVisible = true }
            ui.searchFocusToken &+= 1
            return true
        }
        if cmd && shift && char == "z" {
            withAnimation(.smooth(duration: 0.3)) { ui.zenMode.toggle() }
            return true
        }
        guard !editingText else { return false }

        switch event.keyCode {
        case 49: // Space
            player.togglePlay()
            return true
        case 123: // ←
            cmd ? player.seek(by: -10) : player.previous()
            return true
        case 124: // →
            cmd ? player.seek(by: 10) : player.next()
            return true
        case 126: // ↑
            if cmd { player.jumpToStart() } else { player.volume = min(1, player.volume + 0.05) }
            return true
        case 125: // ↓
            if cmd { player.jumpToEnd() } else { player.volume = max(0, player.volume - 0.05) }
            return true
        default:
            break
        }
        switch char {
        case "f":
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { ui.searchVisible = true }
            ui.searchFocusToken &+= 1
            return true
        case "m":
            player.toggleMute()
            return true
        case "l":
            let s = Settings.shared
            s.normalizationMode = s.normalizationMode == .off ? .track : .off
            return true
        case "b":
            Settings.shared.bitPerfect.toggle()
            return true
        case ".":
            MiniPlayerController.shared.toggle()
            return true
        default:
            return false
        }
    }
}

/// Trackpad gestures for the Now Playing surface: two-finger horizontal swipe
/// = previous/next, two-finger vertical = volume, pinch = artwork zoom.
struct GestureCatcher: NSViewRepresentable {
    func makeNSView(context: Context) -> GestureCatcherView { GestureCatcherView() }
    func updateNSView(_ nsView: GestureCatcherView, context: Context) {}
}

final class GestureCatcherView: NSView {
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var trackingSwipe = false

    override func scrollWheel(with event: NSEvent) {
        switch event.phase {
        case .began:
            accumulatedX = 0
            accumulatedY = 0
            trackingSwipe = true
        case .changed:
            guard trackingSwipe else { return }
            accumulatedX += event.scrollingDeltaX
            accumulatedY += event.scrollingDeltaY
            // Vertical: live volume adjustment (natural scroll: fingers up = louder)
            if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
                let delta = Double(event.scrollingDeltaY) * 0.0015
                Task { @MainActor in
                    let p = Player.shared
                    p.volume = min(1, max(0, p.volume + delta))
                }
            }
        case .ended:
            guard trackingSwipe else { return }
            trackingSwipe = false
            if abs(accumulatedX) > 70, abs(accumulatedX) > abs(accumulatedY) * 1.5 {
                let forward = accumulatedX < 0
                Task { @MainActor in
                    forward ? Player.shared.next() : Player.shared.previous()
                }
            }
        default:
            break
        }
    }

    override func magnify(with event: NSEvent) {
        let delta = event.magnification
        Task { @MainActor in
            let ui = UIState.shared
            ui.artZoom = min(1.35, max(0.85, ui.artZoom + delta))
        }
    }
}

/// Small haptics helper (force-touch trackpads).
enum Haptics {
    static func tap(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .generic) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

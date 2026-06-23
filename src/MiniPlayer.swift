import AppKit
import SwiftUI

/// Floating, borderless, always-on-top mini player (2:1 aspect), sharing the
/// same Player/Library singletons as the main window. Toggle with "." .
@MainActor
final class MiniPlayerController {
    static let shared = MiniPlayerController()
    private var panel: NSPanel?

    var isVisible: Bool { panel != nil }

    func toggle() {
        if panel == nil { show() } else { hide() }
    }

    func show() {
        guard panel == nil else { return }
        let size = NSSize(width: 340, height: 170)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let origin = NSPoint(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.aspectRatio = NSSize(width: 2, height: 1)
        panel.minSize = NSSize(width: 260, height: 130)
        panel.contentView = NSHostingView(rootView: MiniPlayerView())
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct MiniPlayerView: View {
    @ObservedObject private var player = Player.shared
    @ObservedObject private var library = Library.shared
    @State private var hovering = false
    @State private var showControls = false
    @State private var artScale: CGFloat = 1

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var tint: NSColor { library.dominantColor(for: player.current) ?? .black }
    private var lightText: Bool {
        let c = tint.usingColorSpace(.sRGB) ?? tint
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luminance < 0.62
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(nsColor: tint).opacity(0.92),
                                    Color(nsColor: tint).opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .background(.black)
                .animation(.easeInOut(duration: 0.6), value: player.current?.artworkFile)

            HStack(spacing: 12) {
                ArtworkSquare(image: library.artwork(for: player.current), corner: 10,
                              remote: player.current?.remoteArtworkURL,
                              remoteFallback: player.current?.remoteArtworkFallbackURL)
                    .frame(width: 86, height: 86)
                    .scaleEffect(artScale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { artScale = min(1.25, max(0.8, $0)) }
                            .onEnded { _ in withAnimation(.bouncy) { artScale = 1 } }
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.current?.title ?? "Nothing playing")
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    Text(player.current?.artist.isEmpty == false ? player.current!.artist : "")
                        .font(.caption)
                        .opacity(0.75)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .foregroundStyle(lightText ? Color.white : Color.black)

            // Auto-hide transport: in on hover, out 0.5s after exit.
            if showControls {
                VStack {
                    HStack {
                        Button { MiniPlayerController.shared.hide() } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .frame(width: 20, height: 20)
                                .background(.black.opacity(0.35), in: .circle)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    Spacer()
                    HStack(spacing: 14) {
                        miniButton("backward.fill", size: 12) { player.previous() }
                        miniButton(player.isPlaying ? "pause.fill" : "play.fill", size: 16) { player.togglePlay() }
                        miniButton("forward.fill", size: 12) { player.next() }
                    }
                    .padding(.bottom, 10)
                }
                .padding(8)
                .foregroundStyle(.white)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
            }

            VStack {
                Spacer()
                MiniProgress()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .onHover { inside in
            hovering = inside
            if inside {
                withAnimation(reduceMotion ? .linear(duration: 0.05) : .spring(response: 0.3, dampingFraction: 0.7)) {
                    showControls = true
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !hovering {
                        withAnimation(reduceMotion ? .linear(duration: 0.05) : .easeOut(duration: 0.25)) {
                            showControls = false
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func miniButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: size + 18, height: size + 18)
                .background(.black.opacity(0.35), in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI
import AppKit

// MARK: - Design tokens
//
// One home for the values that had drifted across the view layer: before this
// file the views used 9 different corner radii, ~20 different white opacities,
// 4 hover scales and 3 hover curves — frequently for the same intent. Reach for
// a token here instead of a fresh literal at the call site, and when something
// genuinely needs a new value, add it to the scale.

/// Corner radii, named by the kind of surface rather than by number.
enum Radius {
    /// Chips, badges, small inline buttons.
    static let chip: CGFloat = 8
    /// List rows.
    static let row: CGFloat = 10
    /// Artwork squares and the cards built around them.
    static let art: CGFloat = 12
    /// Panels and containers that hold other content.
    static let panel: CGFloat = kPanelRadius
    /// Sheets, the mini player, and other large floating surfaces.
    static let sheet: CGFloat = 26
}

/// Translucent white fills, by role — four intents rather than twenty literals.
enum Surface {
    /// Barely-there fill for large resting areas.
    static let quiet = Color.white.opacity(0.04)
    /// A resting surface that should read as its own layer.
    static let base = Color.white.opacity(0.07)
    /// That same surface under the cursor.
    static let hover = Color.white.opacity(0.10)
    /// Selected, or currently playing.
    static let active = Color.white.opacity(0.14)
    /// Hairline borders and dividers.
    static let stroke = Color.white.opacity(0.12)
}

/// Every interactive surface shares these curves, so the app answers the cursor
/// with one personality instead of six.
enum Motion {
    /// Hover in and out.
    static let hover = Animation.spring(response: 0.26, dampingFraction: 0.78)
    /// Press down — quicker than `hover`, so a click lands immediately instead
    /// of easing into place.
    static let press = Animation.spring(response: 0.16, dampingFraction: 0.7)
    /// Moving between a grid and a detail screen. Slow enough to read the cover
    /// travelling, damped enough not to wobble when it lands.
    static let navigate = Animation.spring(response: 0.42, dampingFraction: 0.82)
}

/// How much a surface grows under the cursor. Cards have room to lift; rows sit
/// in a dense list where the same scale reads as jitter.
enum Lift {
    static let card: CGFloat = 1.03
    static let row: CGFloat = 1.01
}

/// Colours for artless cover art, derived from a name so the same album is the
/// same colour everywhere it appears. Desaturated and dark on purpose: these
/// sit beside real cover art and should read as a family of quiet surfaces
/// rather than compete with it.
enum Placeholder {
    static let neutral = [Color(white: 0.24), Color(white: 0.12)]

    /// Twelve hues rather than the full circle. Hashing straight to 0–360°
    /// clusters: three of eight sample album names landed within 26° of each
    /// other, and two covers that are *almost* the same colour read as a
    /// rendering fault, where two that are plainly the same read as a coincidence.
    /// Muddy yellow-greens are left out — they go dishwater at this brightness.
    private static let hues: [Double] = [12, 32, 52, 95, 145, 175, 200, 225, 262, 295, 325, 348]

    static func colors(seed: String?) -> [Color] {
        guard let seed, !seed.isEmpty else { return neutral }
        let hue = hue(for: seed) / 360
        return [Color(hue: hue, saturation: 0.30, brightness: 0.30),
                Color(hue: hue, saturation: 0.38, brightness: 0.13)]
    }

    /// A brighter, more saturated take on the same hue, for the surfaces that
    /// tint *from* the artwork rather than draw it: the Now Playing glow, the
    /// mini player wash, the window backdrop. A real cover's dominant colour is
    /// always preferred — this only stands in when a track has no art at all,
    /// so those surfaces aren't simply black. Returns nil for an empty seed, to
    /// keep each caller's own fallback meaningful.
    static func tint(seed: String?) -> NSColor? {
        guard let seed, !seed.isEmpty else { return nil }
        return NSColor(hue: hue(for: seed) / 360, saturation: 0.55, brightness: 0.62, alpha: 1)
    }

    /// The palette hue for a name, in degrees.
    private static func hue(for seed: String) -> Double {
        hues[Int(stableHash(seed) % UInt64(hues.count))]
    }

    /// FNV-1a, because `hashValue` is seeded per process — using it would
    /// repaint every artless album a different colour on every launch.
    private static func stableHash(_ seed: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}

/// A press dips the surface just below its resting size, proportional to how
/// far it lifts on hover, so both ends of the gesture feel like one material.
private func pressedScale(for lift: CGFloat) -> CGFloat { 1 - (lift - 1) * 0.9 }

// MARK: - Typography

/// The app had one voice before this: of 260 named font uses, 162 were
/// `.caption`/`.caption2` and exactly four were title-sized. Nothing was ever
/// big, so nothing carried emphasis. These three sizes exist to create the
/// contrast that was missing — use them for structure, and leave body text to
/// the system styles.
enum TypeScale {
    /// A section's title inside the content. Deliberately much larger than the
    /// rows beneath it.
    static let section = Font.system(size: 28, weight: .bold)
    /// The current page's title, in the top bar.
    static let page = Font.system(size: 24, weight: .bold)
    /// The small all-caps label that sits above a section title.
    static let eyebrow = Font.system(size: 10, weight: .bold)
}

/// An eyebrow label over a big title, with optional trailing controls on the
/// title's baseline. The eyebrow carries the accent colour, which is how the
/// chromatic tint reaches the content without flooding it.
struct SectionHeader<Trailing: View>: View {
    var eyebrow: String? = nil
    let title: String
    var accent: Color = .secondary
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(TypeScale.eyebrow)
                        .tracking(1.4)
                        .foregroundStyle(accent)
                }
                Text(title)
                    .font(TypeScale.section)
                    .tracking(-0.6)
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(eyebrow: String? = nil, title: String, accent: Color = .secondary) {
        self.init(eyebrow: eyebrow, title: title, accent: accent) { EmptyView() }
    }
}

// MARK: - Chromatic accent

/// The colour the chrome wears right now: taken from the playing track's cover,
/// or from its placeholder hue when it has no art. Read it in a view that
/// already observes `Player`/`Library`, so it refreshes when the track changes.
enum Chroma {
    @MainActor static var current: Color {
        let source = Library.shared.dominantColor(for: Player.shared.current)
            ?? Placeholder.tint(seed: Player.shared.current?.album)
        // Nothing playing: stay quiet. Pure white here made the eyebrow labels
        // compete with the titles they sit above.
        return source.map(legible) ?? .secondary
    }

    /// Cover colours are arbitrary — a near-black sleeve would vanish against
    /// the dark chrome and a pastel one would glare. This keeps the hue and
    /// clamps saturation and brightness into a band that stays legible.
    static func legible(_ color: NSColor) -> Color {
        guard let srgb = color.usingColorSpace(.sRGB) else { return .white }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h),
                     saturation: Double(min(max(s, 0.35), 0.80)),
                     brightness: Double(min(max(b, 0.62), 0.92)))
    }
}

// MARK: - Interaction

/// The app's hover and press behaviour for a surface that isn't a `Button` —
/// one that acts through `.onTapGesture`. This owns the scale and the curves;
/// the view keeps its own tint and overlay logic and hears about hover through
/// `onHoverChange`, so it can animate those in the same breath.
///
/// `pressable` exists for rows that also carry `.onDrag`: press tracking is a
/// zero-distance drag gesture, which on those rows would compete with the very
/// drag-and-drop it sits next to.
private struct InteractiveSurface: ViewModifier {
    let lift: CGFloat
    let pressable: Bool
    let onHoverChange: (Bool) -> Void

    @State private var hovered = false
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        if pressed { return pressedScale(for: lift) }
        return hovered ? lift : 1
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .animation(pressed ? Motion.press : Motion.hover, value: scale)
            .onHover { isHovering in
                hovered = isHovering
                // A mouse-up outside the view never reaches the gesture, which
                // would leave the surface stuck in its pressed state.
                if !isHovering { pressed = false }
                onHoverChange(isHovering)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded { _ in pressed = false },
                including: pressable ? .all : .subviews
            )
    }
}

/// The same treatment for cards that already are `Button`s, driven by the
/// button's own press state so no gesture is involved. Replaces
/// `.buttonStyle(.plain)` plus a hand-rolled `scaleEffect`/`onHover` pair.
struct PressableCard: ButtonStyle {
    var lift: CGFloat = Lift.card

    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration, lift: lift)
    }

    /// Named `CardBody` rather than `Body`: a nested type called `Body`
    /// matches `ButtonStyle`'s own associated-type requirement, which then
    /// has to be as accessible as the style itself.
    private struct CardBody: View {
        let configuration: ButtonStyleConfiguration
        let lift: CGFloat
        @State private var hovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var scale: CGFloat {
            guard !reduceMotion else { return 1 }
            if configuration.isPressed { return pressedScale(for: lift) }
            return hovered ? lift : 1
        }

        var body: some View {
            configuration.label
                .scaleEffect(scale)
                .animation(configuration.isPressed ? Motion.press : Motion.hover, value: scale)
                .onHover { hovered = $0 }
        }
    }
}

extension View {
    /// Standard hover + press treatment for a tap-gesture surface. See
    /// `InteractiveSurface`.
    func interactiveSurface(lift: CGFloat = Lift.card,
                            pressable: Bool = true,
                            onHoverChange: @escaping (Bool) -> Void = { _ in }) -> some View {
        modifier(InteractiveSurface(lift: lift, pressable: pressable,
                                    onHoverChange: onHoverChange))
    }
}

extension View {
    /// `matchedGeometryEffect`, but only when a namespace is actually supplied.
    /// Cards like `AlbumCard` also appear on screens that aren't part of any
    /// transition, and those callers pass nil.
    @ViewBuilder
    func matchedIfPresent(_ id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedGeometryEffect(id: id, in: namespace)
        } else {
            self
        }
    }
}

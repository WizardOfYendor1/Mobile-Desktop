import GameController
import UIKit

/// Keeps the arrow presses tvOS makes out of touch surface swipes away from
/// the engine's key repeater.
///
/// The engine listens for arrow presses with gesture recognizers and repeats
/// a held arrow at the configured key repeat rate. A swipe on the touch
/// surface reaches it as an arrow press that the system holds down for as
/// long as the finger rests, so swiping and holding kept stepping focus long
/// after SiriRemoteGlide had stopped. The only arrow press worth keeping is a
/// click on the ring, and a click is the one thing the controller can vouch
/// for, so an arrow recognizer may begin only while the surface is clicked.
///
/// The press and the controller's click state arrive on separate paths, so
/// each arrow recognizer waits a moment before it decides, long enough for
/// the click to have landed and short enough to go unnoticed.
@MainActor
final class SiriRemotePressGate: NSObject, UIGestureRecognizerDelegate {
    private static let arrowTypes: Set<Int> = [
        UIPress.PressType.upArrow, .downArrow, .leftArrow, .rightArrow,
    ].reduce(into: Set<Int>()) { $0.insert($1.rawValue) }

    private static let settleDuration: TimeInterval = 0.03

    private weak var upstream: UIGestureRecognizerDelegate?

    private init(upstream: UIGestureRecognizerDelegate) {
        self.upstream = upstream
    }

    /// Wraps the delegate of every arrow recognizer on `view`. Returns nil when
    /// the engine has not installed any, which only happens if it stops using
    /// recognizers for presses.
    static func install(on view: UIView) -> SiriRemotePressGate? {
        let arrows = (view.gestureRecognizers ?? [])
            .compactMap { $0 as? UILongPressGestureRecognizer }
            .filter { recognizer in
                let types = Set(recognizer.allowedPressTypes.map(\.intValue))
                return !types.isEmpty && types.isSubset(of: arrowTypes)
            }
        guard let upstream = arrows.first?.delegate else { return nil }
        let gate = SiriRemotePressGate(upstream: upstream)
        for recognizer in arrows where recognizer.delegate === upstream {
            recognizer.delegate = gate
            recognizer.minimumPressDuration = settleDuration
        }
        return gate
    }

    private static var surfaceIsClicked: Bool {
        GCController.controllers().contains { $0.microGamepad?.buttonA.isPressed == true }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard Self.surfaceIsClicked else { return false }
        return upstream?.gestureRecognizerShouldBegin?(gestureRecognizer) ?? true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        upstream?.gestureRecognizer?(gestureRecognizer, shouldRecognizeSimultaneouslyWith: other)
            ?? false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf other: UIGestureRecognizer
    ) -> Bool {
        upstream?.gestureRecognizer?(gestureRecognizer, shouldRequireFailureOf: other) ?? false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        upstream?.gestureRecognizer?(gestureRecognizer, shouldBeRequiredToFailBy: other) ?? false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        upstream?.gestureRecognizer?(gestureRecognizer, shouldReceive: touch) ?? true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress
    ) -> Bool {
        upstream?.gestureRecognizer?(gestureRecognizer, shouldReceive: press) ?? true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent
    ) -> Bool {
        upstream?.gestureRecognizer?(gestureRecognizer, shouldReceive: event) ?? true
    }
}

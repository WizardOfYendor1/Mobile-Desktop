import Flutter
import GameController
import UIKit

/// Keeps the arrow presses tvOS makes out of touch surface swipes away from
/// the engine's key repeater.
///
/// The engine listens for arrow presses with gesture recognizers and repeats
/// a held arrow at the configured key repeat rate. A swipe on the touch
/// surface reaches it as an arrow press that the system holds down for as
/// long as the finger rests, so swiping and holding kept stepping focus long
/// after SiriRemoteGlide had stopped.
///
/// Only a swipe is worth holding back, and a swipe always has a finger on the
/// pad, so an arrow press arriving with the pad untouched is passed straight
/// on. That is every press an infrared or HDMI-CEC remote sends. A click on
/// the ring lands with the finger down, and a click is the one thing the
/// controller can vouch for, so it is let through on that.
///
/// The touch report comes from SiriRemoteGlide, which already reads the same
/// touch stream the arrow presses are made from. It arrives on its own path,
/// as does the click state, so each arrow recognizer waits a moment before it
/// decides, long enough for both to have landed and short enough to go
/// unnoticed.
@MainActor
final class SiriRemotePressGate: NSObject, UIGestureRecognizerDelegate {
    private static let arrowTypes: Set<Int> = [
        UIPress.PressType.upArrow, .downArrow, .leftArrow, .rightArrow,
    ].reduce(into: Set<Int>()) { $0.insert($1.rawValue) }

    private static let settleDuration: TimeInterval = 0.03

    private weak var upstream: UIGestureRecognizerDelegate?
    private let channel: FlutterMethodChannel
    private var padIsTouched = false

    private init(
        upstream: UIGestureRecognizerDelegate, messenger: FlutterBinaryMessenger
    ) {
        self.upstream = upstream
        channel = FlutterMethodChannel(
            name: "moonfin/siri_remote_gate", binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            MainActor.assumeIsolated {
                guard call.method == "setPadTouched" else {
                    result(FlutterMethodNotImplemented)
                    return
                }
                self?.padIsTouched = call.arguments as? Bool ?? false
                result(nil)
            }
        }
        // A backgrounded app or a controller that drops mid gesture never
        // delivers the touch ended report, which would leave the gate blocking
        // arrows on stale evidence. Either way no finger is on the pad.
        for name in [
            UIApplication.willResignActiveNotification,
            .GCControllerDidDisconnect,
        ] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.padIsTouched = false }
            }
        }
    }

    /// Wraps the delegate of every arrow recognizer on `view`. Returns nil when
    /// the engine has not installed any, which only happens if it stops using
    /// recognizers for presses.
    static func install(
        on view: UIView, messenger: FlutterBinaryMessenger
    ) -> SiriRemotePressGate? {
        let arrows = (view.gestureRecognizers ?? [])
            .compactMap { $0 as? UILongPressGestureRecognizer }
            .filter { recognizer in
                let types = Set(recognizer.allowedPressTypes.map(\.intValue))
                return !types.isEmpty && types.isSubset(of: arrowTypes)
            }
        guard let upstream = arrows.first?.delegate else { return nil }
        let gate = SiriRemotePressGate(upstream: upstream, messenger: messenger)
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
        // Temporary diagnostic, do not ship. Answers whether tvOS synthesizes
        // arrow presses from swipes: lines with padIsTouched=true during a
        // swipe mean it does and the gate is load bearing, lines only on
        // taps, clicks, and IR presses mean the gate guards nothing a swipe
        // produces.
        let types = (gestureRecognizer as? UILongPressGestureRecognizer)?
            .allowedPressTypes.map(\.intValue) ?? []
        NSLog(
            "[gate] arrow press types=%@ padIsTouched=%d clicked=%d",
            "\(types)", padIsTouched ? 1 : 0, Self.surfaceIsClicked ? 1 : 0)
        if padIsTouched, !Self.surfaceIsClicked { return false }
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

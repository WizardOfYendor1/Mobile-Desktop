import Flutter
import GameController
import UIKit

@MainActor
final class AppleTvSystemChannel: NSObject {
    private let channel: FlutterMethodChannel
    private weak var gamepadHost: GCEventViewController?

    init(messenger: FlutterBinaryMessenger, gamepadHost: GCEventViewController) {
        channel = FlutterMethodChannel(
            name: "moonfin/appletv_system", binaryMessenger: messenger)
        self.gamepadHost = gamepadHost
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setIdleTimerDisabled":
            let disabled = (call.arguments as? Bool) ?? false
            UIApplication.shared.isIdleTimerDisabled = disabled
            result(nil)
        case "setGamepadNavigationEnabled":
            gamepadHost?.controllerUserInteractionEnabled = (call.arguments as? Bool) ?? false
            result(nil)
        case "exitApp":
            result(nil)
            exit(0)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

import Flutter
import UIKit

/// QuickAuth iOS plugin.
///
/// iOS already provides system-level OTP autofill via
/// `UITextContentType.oneTimeCode` — exposed on the Dart side through
/// `TextField(autofillHints: [AutofillHints.oneTimeCode])`. The plugin is
/// therefore a thin shim:
///   - `start`       → returns `false` (Android-only feature).
///   - `getAppHash`  → returns `nil`.
///   - `launchUrl`   → opens a URL via `UIApplication.shared.open`.
public class QuickAuthSdkFlutterPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "io.quickauth/sms_retriever",
            binaryMessenger: registrar.messenger()
        )
        let instance = QuickAuthSdkFlutterPlugin()
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        // No-op event channel so Dart subscribers don't error out.
        let eventChannel = FlutterEventChannel(
            name: "io.quickauth/sms_retriever/events",
            binaryMessenger: registrar.messenger()
        )
        eventChannel.setStreamHandler(NoOpStreamHandler())
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            result(false)
        case "getAppHash":
            result(nil)
        case "launchUrl":
            guard let args = call.arguments as? [String: Any],
                  let urlString = args["url"] as? String,
                  let url = URL(string: urlString) else {
                result(FlutterError(code: "invalid_args", message: "url required", details: nil))
                return
            }
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:]) { ok in result(ok) }
            } else {
                result(false)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

private final class NoOpStreamHandler: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        return nil
    }
}

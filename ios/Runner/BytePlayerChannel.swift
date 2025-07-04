import Flutter
import Foundation

final class BytePlayerChannel {
    static func register(with messenger: FlutterBinaryMessenger) {

        let channel = FlutterMethodChannel(
            name: "privastead.com/ios/byte_player",
            binaryMessenger: messenger)

        channel.setMethodCallHandler {
            (
                call: FlutterMethodCall,
                result: @escaping FlutterResult
            ) in
            print("[SWIFT] Channel call: \(call.method)")
            switch call.method {

            case "createStream":
                let id = ByteQueueManager.createStream()
                result(id)

            case "pushBytes":
                guard
                    let dict = call.arguments as? [String: Any],
                    let id = dict["id"] as? Int,
                    let bytes = dict["bytes"] as? FlutterStandardTypedData
                else {
                    result(FlutterError(code: "bad_args", message: nil, details: nil))
                    return
                }
                ByteQueueManager.push(id: id, bytes: bytes.data)
                result(nil)

            case "finishStream":
                guard
                    let dict = call.arguments as? [String: Any],
                    let id = dict["id"] as? Int
                else {
                    result(FlutterError(code: "bad_args", message: nil, details: nil))
                    return
                }
                ByteQueueManager.finish(id: id)
                result(nil)

            case "qLen":
                guard
                    let dict = call.arguments as? [String: Any],
                    let id = dict["id"] as? Int
                else {
                    result(FlutterError(code: "bad_args", message: nil, details: nil))
                    return
                }
                result(ByteQueueManager.queueLength(id: id))

            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}

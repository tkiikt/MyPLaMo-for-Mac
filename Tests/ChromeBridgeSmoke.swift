import Foundation
@main struct ChromeBridgeSmoke {
    @MainActor static func main() async {
        let bridge = ChromeBridge()
        bridge.start { text in
            if text == "slow" { try await Task.sleep(for: .seconds(16)) }
            return "訳:" + text
        }
        for _ in 0..<30 {
            if let error = bridge.error { print(error); exit(1) }
            if bridge.isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard bridge.isRunning else { exit(1) }
        print("READY"); fflush(stdout)
        try? await Task.sleep(for: .seconds(90))
        bridge.stop()
    }
}

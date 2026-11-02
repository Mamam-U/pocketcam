import SwiftUI

@main
struct PocketCamApp: App {
    @StateObject private var recorder: CameraRecorder
    @StateObject private var server: MJpegHttpServer

    init() {
        let recorder = CameraRecorder()
        _recorder = StateObject(wrappedValue: recorder)
        _server = StateObject(wrappedValue: MJpegHttpServer(recorder: recorder))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(server)
        }
    }
}

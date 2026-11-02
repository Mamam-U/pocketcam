import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var recorder: CameraRecorder
    @EnvironmentObject private var server: MJpegHttpServer
    @State private var hasPermission = false
    @State private var permissionAsked = false

    var body: some View {
        VStack(spacing: 0) {
            // 预览
            ZStack {
                Color.black
                PreviewView(session: recorder.session)
                    .opacity(recorder.state == .idle ? 0.35 : 1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .clipped()

            // 状态与控制
            VStack(spacing: 12) {
                HStack {
                    Circle()
                        .fill(recorder.state == .recording ? Color.red : Color.gray)
                        .frame(width: 10, height: 10)
                    Text(statusText)
                        .font(.headline)
                    Spacer()
                    if recorder.state == .recording {
                        Text(timeString(recorder.currentSegmentDuration))
                            .font(.subheadline.monospacedDigit())
                    }
                }

                ProgressView(value: storageFraction)
                    .tint(storageFraction > 0.9 ? Color.red : Color.blue)

                HStack {
                    Text("已用 \(byteString(recorder.storedBytes)) / \(byteString(Config.maxStorageBytes))")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if server.isRunning, !server.serverURL.isEmpty {
                    HStack {
                        Image(systemName: "wifi")
                        Text(server.serverURL).font(.subheadline.monospaced())
                        Spacer()
                        Button("打开") { openServerURL() }
                            .buttonStyle(.bordered)
                    }
                }

                Button(action: toggleRecording) {
                    Text(recorder.state == .recording || recorder.state == .paused ? "停止录制" : "开始录制")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(recorder.state == .recording ? Color.red : Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!hasPermission || recorder.state == .preparing || recorder.state == .failed)

                if case .failed(let message) = recorder.state {
                    Text("出错：\(message)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            Spacer()
        }
        .task {
            if !permissionAsked {
                permissionAsked = true
                hasPermission = await recorder.requestPermissions()
                if hasPermission {
                    server.start()
                    UIApplication.shared.isIdleTimerDisabled = true
                }
            }
        }
    }

    // MARK: - 文案与格式

    private var statusText: String {
        switch recorder.state {
        case .idle: return "未录制"
        case .preparing: return "准备中…"
        case .recording: return "录制中 · 后台保活已开启"
        case .paused: return "已暂停（来电中断）"
        case .failed(let message): return "失败：\(message)"
        }
    }

    private var storageFraction: Double {
        Double(recorder.storedBytes) / Double(Config.maxStorageBytes)
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private func byteString(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1024 / 1024 / 1024
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        return String(format: "%.0f MB", Double(bytes) / 1024 / 1024)
    }

    // MARK: - 动作

    private func toggleRecording() {
        switch recorder.state {
        case .idle, .failed:
            recorder.start()
        case .recording, .paused:
            recorder.stop()
        case .preparing:
            break
        }
    }

    private func openServerURL() {
        guard let url = URL(string: server.serverURL) else { return }
        UIApplication.shared.open(url)
    }
}

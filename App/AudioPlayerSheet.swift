import SwiftUI
import AVFoundation

/// 转换产物的播放器：.aud（SILK）/ .amr 先解码为 WAV 再交给 AVAudioPlayer，
/// mp3 / m4a / wav 等直接播放。
struct AudioPlayerSheet: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss

    @State private var player: AVAudioPlayer?
    @State private var cachedWAV: URL?
    @State private var loading = true
    @State private var failure: String?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var dragging = false
    @State private var dragTime: Double = 0

    private let ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    private var title: String { url.deletingPathExtension().lastPathComponent }
    private var formatText: String { url.pathExtension.uppercased() }

    var body: some View {
        VStack(spacing: 0) {
            header
            if loading {
                loadingView
            } else if let failure {
                failureView(failure)
            } else {
                playerBody
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .presentationDetents([.height(430)])
        .presentationDragIndicator(.visible)
        .onAppear(perform: prepare)
        .onDisappear(perform: teardown)
        .onReceive(ticker) { _ in tick() }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("播放")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("\(formatText) · 本机文件")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 30, height: 30)
                    .background(Palette.placeholder, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    // MARK: - 状态

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(Palette.ink)
            Text("正在解码…")
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 110)
    }

    private func failureView(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Palette.warning)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    // MARK: - 播放界面

    private var playerBody: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Palette.card)
                    .frame(width: 132, height: 132)
                    .shadow(color: Color.black.opacity(0.04), radius: 14, x: 0, y: 6)
                Circle()
                    .stroke(Palette.warning.opacity(0.25), lineWidth: 1.5)
                    .frame(width: 132, height: 132)
                Image(systemName: isPlaying ? "waveform" : "waveform.slash")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Palette.warning)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.top, 8)

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(url.lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 24)

            VStack(spacing: 6) {
                Slider(value: Binding(get: {
                    dragging ? dragTime : currentTime
                }, set: { value in
                    dragTime = value
                    dragging = true
                }), in: 0...max(duration, 0.01), onEditingChanged: { editing in
                    guard !editing, let player else { return }
                    player.currentTime = dragTime
                    currentTime = dragTime
                    dragging = false
                })
                .tint(Palette.warning)
                .disabled(duration <= 0)

                HStack {
                    Text(timeText(dragging ? dragTime : currentTime))
                    Spacer()
                    Text(timeText(duration))
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, 28)

            HStack(spacing: 34) {
                Button {
                    seek(by: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Palette.ink)
                }
                .buttonStyle(.plain)

                Button(action: toggle) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .imageScale(.large)
                        .frame(width: 66, height: 66)
                        .background(Palette.card, in: Circle())
                        .shadow(color: Color.black.opacity(0.05), radius: 12, x: 0, y: 5)
                }
                .buttonStyle(.plain)

                Button {
                    seek(by: 15)
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Palette.ink)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - 控制

    private func tick() {
        guard let player else { return }
        if !dragging {
            currentTime = player.currentTime
        }
        if isPlaying && !player.isPlaying {
            isPlaying = false
            currentTime = player.duration
        } else if !isPlaying && player.isPlaying {
            isPlaying = true
        }
    }

    private func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if player.currentTime >= player.duration - 0.05 {
                player.currentTime = 0
            }
            player.play()
            isPlaying = true
        }
    }

    private func seek(by delta: Double) {
        guard let player else { return }
        let target = min(max(player.currentTime + delta, 0), player.duration)
        player.currentTime = target
        currentTime = target
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - 准备 / 清理

    private func prepare() {
        loading = true
        failure = nil

        let source = url
        DispatchQueue.global(qos: .userInitiated).async {
            var playable = source
            var temp: URL?
            var problem: String?

            if AudioPlayback.isDecodablePath(source.path) {
                let wav = FileManager.default.temporaryDirectory
                    .appendingPathComponent("player-\(UUID().uuidString).wav")
                do {
                    try AudioPlayback.decodeAudio(at: source, toWAVURL: wav)
                    playable = wav
                    temp = wav
                } catch {
                    problem = error.localizedDescription
                }
            }

            var audio: AVAudioPlayer?
            if problem == nil {
                do {
                    audio = try AVAudioPlayer(contentsOf: playable)
                } catch {
                    problem = "无法播放该文件：\(error.localizedDescription)"
                }
            }

            DispatchQueue.main.async {
                guard problem == nil, let audio else {
                    if let temp { try? FileManager.default.removeItem(at: temp) }
                    failure = problem ?? "无法播放该文件"
                    loading = false
                    return
                }
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                try? AVAudioSession.sharedInstance().setActive(true)
                audio.prepareToPlay()
                cachedWAV = temp
                player = audio
                duration = audio.duration
                loading = false
                isPlaying = audio.play()
            }
        }
    }

    private func teardown() {
        player?.stop()
        player = nil
        isPlaying = false
        if let cachedWAV {
            try? FileManager.default.removeItem(at: cachedWAV)
        }
        cachedWAV = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

import AVFoundation
import AVKit
import SwiftUI

/// Full-screen camera. Shoot with the big button, a volume button, or a press on any DiTAG.
struct CameraView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var flashOpacity = 0.0
    @State private var pinchStart: CGFloat?

    private var camera: CameraManager { model.camera }

    var body: some View {
        GeometryReader { geometry in
            let previewHeight = min(geometry.size.width * 4 / 3, geometry.size.height - 220)
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, 16)
                        .frame(height: 52)

                    ZStack {
                        CameraPreview(camera: camera)
                            .gesture(pinch)
                        statusOverlay
                        if let count = camera.countdown {
                            Text("\(count)")
                                .font(.system(size: 120, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .shadow(radius: 12)
                                .contentTransition(.numericText(countsDown: true))
                                .animation(.snappy, value: count)
                        }
                        VStack {
                            Spacer()
                            if camera.status == .running && camera.zoomStops.count > 1 {
                                zoomChips
                                    .padding(.bottom, 12)
                            }
                        }
                    }
                    .frame(width: geometry.size.width, height: previewHeight)
                    .clipped()

                    Spacer(minLength: 0)
                    VStack(spacing: 14) {
                        tagPill
                        bottomBar
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
                    Spacer(minLength: 0)
                }

                Color.white
                    .opacity(flashOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        // Dark here only, without changing the rest of the app.
        .environment(\.colorScheme, .dark)
        .toolbarBackground(.black, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: camera.captureTick) { _, _ in
            flashOpacity = 0.8
            withAnimation(.easeOut(duration: 0.25)) { flashOpacity = 0 }
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("Camera")
                .font(.title3.bold())

            Spacer()

            if camera.flashAvailable {
                Menu {
                    Picker("Flash", selection: Binding(get: { camera.flash }, set: { camera.flash = $0 })) {
                        ForEach(CameraManager.Flash.allCases) { option in
                            Label(option.rawValue.capitalized, systemImage: option.symbol).tag(option)
                        }
                    }
                } label: {
                    CameraChip(symbol: camera.flash.symbol, text: nil,
                               highlighted: camera.flash != .off)
                }
                .accessibilityLabel("Flash \(camera.flash.rawValue)")
            }

            Button {
                camera.timerSeconds = next(after: camera.timerSeconds, in: CameraManager.timerChoices)
            } label: {
                CameraChip(symbol: "timer", text: camera.timerSeconds == 0 ? nil : "\(camera.timerSeconds)s",
                           highlighted: camera.timerSeconds > 0)
            }
            .accessibilityLabel(camera.timerSeconds == 0 ? "Timer off" : "Timer \(camera.timerSeconds) seconds")

            Button {
                camera.photosPerPress = next(after: camera.photosPerPress, in: CameraManager.burstChoices)
            } label: {
                CameraChip(symbol: "square.stack.3d.down.right.fill",
                           text: camera.photosPerPress == 1 ? nil : "×\(camera.photosPerPress)",
                           highlighted: camera.photosPerPress > 1)
            }
            .accessibilityLabel("\(camera.photosPerPress) photos per press")

            if camera.resolutions.count > 1 {
                Menu {
                    Picker("Resolution", selection: Binding(get: { camera.resolution }, set: { camera.resolution = $0 })) {
                        ForEach(camera.resolutions) { option in
                            Text(option.title).tag(Optional(option))
                        }
                    }
                } label: {
                    CameraChip(symbol: nil, text: camera.resolution?.title ?? "MP", highlighted: false)
                }
                .accessibilityLabel("Resolution \(camera.resolution?.title ?? "")")
            }
        }
        .foregroundStyle(.white)
    }

    private func next(after value: Int, in choices: [Int]) -> Int {
        guard let index = choices.firstIndex(of: value) else { return choices[0] }
        return choices[(index + 1) % choices.count]
    }

    // MARK: Preview overlays

    @ViewBuilder
    private var statusOverlay: some View {
        switch camera.status {
        case .unauthorized:
            CameraMessage(symbol: "camera.fill",
                          title: "Camera access is off",
                          text: "Allow DiTether to use the camera in Settings to take photos with your DiTAG.",
                          button: "Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        case .failed(let message):
            CameraMessage(symbol: "exclamationmark.triangle.fill", title: "Camera unavailable",
                          text: message, button: "Try again") { camera.start() }
        case .interrupted:
            CameraMessage(symbol: "pause.circle.fill", title: "Camera paused",
                          text: "Another app is using the camera.", button: nil) {}
        case .starting, .idle:
            ProgressView()
                .tint(.white)
        case .running:
            EmptyView()
        }
    }

    private var zoomChips: some View {
        HStack(spacing: 6) {
            ForEach(camera.zoomStops, id: \.self) { stop in
                let isCurrent = isCurrentStop(stop)
                Button {
                    camera.applyZoom(stop)
                } label: {
                    Text(isCurrent ? zoomLabel(camera.zoom) + "×" : zoomLabel(stop))
                        .font(.system(size: isCurrent ? 13 : 11, weight: .bold))
                        .foregroundStyle(isCurrent ? Color.yellow : .white)
                        .frame(width: isCurrent ? 40 : 32, height: isCurrent ? 40 : 32)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .accessibilityLabel("Zoom \(zoomLabel(stop)) times")
            }
        }
        .padding(5)
        .background(.black.opacity(0.25), in: Capsule())
        .animation(.snappy, value: camera.zoom)
    }

    /// The chip that "owns" the current zoom: the highest stop at or below it.
    private func isCurrentStop(_ stop: CGFloat) -> Bool {
        let owner = camera.zoomStops.last { $0 <= camera.zoom + 0.01 } ?? camera.zoomStops.first
        return owner == stop
    }

    private func zoomLabel(_ value: CGFloat) -> String {
        if value < 1 { return String(format: ".%d", Int((value * 10).rounded())) }
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))" : String(format: "%.1f", rounded)
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStart == nil { pinchStart = camera.zoom }
                camera.applyZoom((pinchStart ?? 1) * value.magnification, animated: false)
            }
            .onEnded { _ in pinchStart = nil }
    }

    // MARK: Bottom

    private var tagPill: some View {
        let connected = model.diTag.settings.tags.filter { model.diTag.status($0.id).state == .connected }
        return HStack(spacing: 6) {
            LiveDot(color: connected.isEmpty ? .gray : .green, pulsing: !connected.isEmpty)
            Text(connected.isEmpty
                 ? "No DiTAG connected · use the button"
                 : "\(connected.count == 1 ? connected[0].displayName : "DiTAG") ready · press to shoot")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.white.opacity(0.12), in: Capsule())
        .overlay(alignment: .bottom) {
            if let problem = camera.saveProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: 28)
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Button {
                camera.openPhotos()
            } label: {
                Group {
                    if let image = camera.lastThumbnail {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.white.opacity(0.12)
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                }
            }
            .accessibilityLabel("Open Photos")

            Spacer()

            Button {
                camera.shoot()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(.white, lineWidth: 4)
                        .frame(width: 80, height: 80)
                    Circle()
                        .fill(.white)
                        .frame(width: 66, height: 66)
                        .scaleEffect(camera.isCapturing ? 0.85 : 1)
                        .animation(.snappy, value: camera.isCapturing)
                }
            }
            .disabled(camera.status != .running || camera.countdown != nil)
            .accessibilityLabel("Take photo")

            Spacer()

            Button {
                camera.flip()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .disabled(camera.status != .running)
            .accessibilityLabel("Switch camera")
        }
    }
}

// MARK: - Pieces

private struct CameraChip: View {
    let symbol: String?
    let text: String?
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
            }
            if let text {
                Text(text)
                    .monospacedDigit()
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(highlighted ? Color.yellow : .white)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(.white.opacity(0.15), in: Capsule())
    }
}

private struct CameraMessage: View {
    let symbol: String
    let title: String
    let text: String
    let button: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40))
            Text(title)
                .font(.headline)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            if let button {
                Button(button, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
            }
        }
        .foregroundStyle(.white)
        .padding(32)
    }
}

/// The live camera picture. Also turns the volume buttons into a shutter (iOS 17.2 and later).
private struct CameraPreview: UIViewRepresentable {
    let camera: CameraManager

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.attach(view.previewLayer)
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { [weak camera] event in
                if event.phase == .ended {
                    MainActor.assumeIsolated { _ = camera?.shoot() }
                }
            }
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

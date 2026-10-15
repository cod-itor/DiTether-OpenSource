@preconcurrency import AVFoundation
import Photos
import UIKit

/// The DiTAG camera: Apple's own photo pipeline (`AVCapturePhotoOutput`) at full quality, so a press
/// on a DiTAG works as a remote shutter. Session work runs on a private serial queue, never on the
/// main thread. Night mode, Portrait and Cinematic stay in Apple's Camera app (iOS keeps them there).
@MainActor
final class CameraManager: NSObject, ObservableObject {
    enum Status: Equatable {
        case idle
        case starting
        case running
        case unauthorized
        case interrupted
        case failed(String)
    }

    enum Flash: String, CaseIterable, Identifiable {
        case off, auto, on
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .off: return "bolt.slash.fill"
            case .auto: return "bolt.badge.automatic.fill"
            case .on: return "bolt.fill"
            }
        }
        var mode: AVCaptureDevice.FlashMode {
            switch self {
            case .off: return .off
            case .auto: return .auto
            case .on: return .on
            }
        }
    }

    /// A photo size the camera offers, for example 24 MP.
    struct Resolution: Hashable, Identifiable {
        let width: Int32
        let height: Int32
        var id: String { "\(width)x\(height)" }
        var megapixels: Int { Int((Double(width) * Double(height) / 1_000_000).rounded()) }
        var title: String { "\(megapixels) MP" }
        var dimensions: CMVideoDimensions { CMVideoDimensions(width: width, height: height) }
    }

    @Published private(set) var status: Status = .idle
    /// True while the camera screen is open. The DiTAG button takes photos only then.
    @Published private(set) var isActive = false
    @Published private(set) var position: AVCaptureDevice.Position = .back
    @Published private(set) var zoomStops: [CGFloat] = [1]
    /// The zoom as people know it from the Camera app (0.5×, 1×, 2×, 5×).
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var resolutions: [Resolution] = []
    @Published private(set) var lastThumbnail: UIImage?
    @Published private(set) var countdown: Int?
    @Published private(set) var isCapturing = false
    /// Bumped on every capture, for the white flash on screen.
    @Published private(set) var captureTick = 0
    @Published private(set) var saveProblem: String?
    @Published private(set) var flashAvailable = true

    // Choices, remembered between launches (the same keys Settings uses).
    @Published var flash: Flash { didSet { defaults.set(flash.rawValue, forKey: Keys.flash) } }
    @Published var timerSeconds: Int { didSet { defaults.set(timerSeconds, forKey: Keys.timer) } }
    @Published var photosPerPress: Int { didSet { defaults.set(photosPerPress, forKey: Keys.burst) } }
    @Published var resolution: Resolution? {
        didSet { if let resolution { defaults.set(resolution.megapixels, forKey: Keys.megapixels) } }
    }

    enum Keys {
        static let flash = "camera.flash"
        static let timer = "camera.timer"
        static let burst = "camera.photosPerPress"
        static let megapixels = "camera.megapixels"
    }

    static let timerChoices = [0, 3, 10]
    static let burstChoices = [1, 3, 5]

    nonisolated let session = AVCaptureSession()
    private nonisolated let sessionQueue = DispatchQueue(label: "ditether.camera.session")
    private nonisolated(unsafe) let photoOutput = AVCapturePhotoOutput()
    private nonisolated(unsafe) var input: AVCaptureDeviceInput?
    /// UI zoom × this = the device's zoom factor (2 on a camera whose widest lens is 0.5×).
    private nonisolated(unsafe) var zoomScale: CGFloat = 1
    private nonisolated(unsafe) var configured = false

    private let defaults = UserDefaults.standard
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    /// Kept alive here until each capture finishes: the photo output only holds its delegate weakly.
    private var processors: [UUID: PhotoProcessor] = [:]
    private var shootTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    override init() {
        flash = Flash(rawValue: UserDefaults.standard.string(forKey: Keys.flash) ?? "") ?? .off
        let timer = UserDefaults.standard.integer(forKey: Keys.timer)
        timerSeconds = Self.timerChoices.contains(timer) ? timer : 0
        let burst = UserDefaults.standard.integer(forKey: Keys.burst)
        photosPerPress = Self.burstChoices.contains(burst) ? burst : 1
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                            object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.status = .interrupted }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                            object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isActive == true { self?.status = .running } }
        })
    }

    // MARK: - Start and stop

    /// The camera screen appeared: ask for access if needed, then start.
    func start() {
        isActive = true
        saveProblem = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            status = .starting
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if granted && isActive { startSession() } else if !granted { status = .unauthorized }
            }
        default:
            status = .unauthorized
        }
    }

    /// The camera screen went away: stop the camera so it uses no battery.
    func stop() {
        isActive = false
        shootTask?.cancel()
        shootTask = nil
        countdown = nil
        let session = session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
        if status == .running || status == .interrupted || status == .starting { status = .idle }
    }

    private func startSession() {
        status = .starting
        let position = position
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let result = self.configureIfNeeded(position: position)
            if result == nil, !self.session.isRunning { self.session.startRunning() }
            let stops = self.currentZoomStops()
            let resolutions = self.currentResolutions()
            let flashAvailable = self.input?.device.hasFlash ?? false
            Task { @MainActor in
                if let result {
                    self.status = .failed(result)
                    return
                }
                guard self.isActive else { return }
                self.status = .running
                self.zoomStops = stops
                self.flashAvailable = flashAvailable
                self.adoptResolutions(resolutions)
                self.applyZoom(1, animated: false)
                self.makeRotationCoordinator()
            }
        }
    }

    // MARK: - Configuration (session queue)

    /// Returns an error message, or nil when ready.
    private nonisolated func configureIfNeeded(position: AVCaptureDevice.Position) -> String? {
        if configured { return nil }
        guard let device = Self.bestDevice(for: position) else { return "No camera found." }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(newInput) else { return "The camera is busy." }
            session.addInput(newInput)
            input = newInput
        } catch {
            return "The camera could not start."
        }
        guard session.canAddOutput(photoOutput) else { return "The camera could not start." }
        session.addOutput(photoOutput)
        Self.chooseLargestPhotoFormat(for: device)
        configurePhotoOutput(for: device)
        zoomScale = Self.zoomScale(for: device)
        configured = true
        return nil
    }

    /// The back camera that covers every lens (so zoom glides across them), or the plain one.
    private nonisolated static func bestDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position)
        for type in types {
            if let device = discovery.devices.first(where: { $0.deviceType == type }) { return device }
        }
        return nil
    }

    /// Picks the format with the biggest photos (48 MP on an iPhone 15 Pro Max), preferring a 4:3
    /// preview like the Camera app. The `.photo` preset alone may stop at 12 MP.
    private nonisolated static func chooseLargestPhotoFormat(for device: AVCaptureDevice) {
        func pixels(_ dimensions: CMVideoDimensions) -> Int64 { Int64(dimensions.width) * Int64(dimensions.height) }
        func maxPhoto(_ format: AVCaptureDevice.Format) -> Int64 {
            format.supportedMaxPhotoDimensions.map(pixels).max() ?? 0
        }
        let current = maxPhoto(device.activeFormat)
        guard let best = device.formats.map(maxPhoto).max(), best > current else { return }
        let candidates = device.formats.filter { maxPhoto($0) == best }
        let fourByThree = candidates.filter {
            let video = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return abs(Double(video.width) / Double(max(video.height, 1)) - 4.0 / 3.0) < 0.01
        }
        guard let format = (fourByThree.isEmpty ? candidates : fourByThree).first else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.unlockForConfiguration()
        } catch {}
    }

    private nonisolated func configurePhotoOutput(for device: AVCaptureDevice) {
        photoOutput.maxPhotoQualityPrioritization = .quality
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) {
            photoOutput.maxPhotoDimensions = largest
        }
        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = true
            if photoOutput.isFastCapturePrioritizationSupported {
                photoOutput.isFastCapturePrioritizationEnabled = true
            }
        }
        if photoOutput.isZeroShutterLagSupported {
            photoOutput.isZeroShutterLagEnabled = true
        }
    }

    /// On a camera whose widest lens is the ultra wide, the device's zoom 1.0 is what people call
    /// 0.5×, and the switch to the main lens happens at zoom 2.0.
    private nonisolated static func zoomScale(for device: AVCaptureDevice) -> CGFloat {
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        guard hasUltraWide, let first = device.virtualDeviceSwitchOverVideoZoomFactors.first else { return 1 }
        return CGFloat(truncating: first)
    }

    /// The chips to show: 0.5× (ultra wide), 1×, 2×, and the telephoto (3× or 5×).
    private nonisolated func currentZoomStops() -> [CGFloat] {
        guard let device = input?.device else { return [1] }
        var stops: [CGFloat] = []
        if zoomScale > 1 { stops.append(1 / zoomScale) }
        stops.append(1)
        let maxUI = device.maxAvailableVideoZoomFactor / zoomScale
        if maxUI >= 2 { stops.append(2) }
        let switches = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) / zoomScale }
        if let tele = switches.last, tele > 2.1 {
            stops.append((tele * 10).rounded() / 10)
        }
        return stops
    }

    private nonisolated func currentResolutions() -> [Resolution] {
        guard let device = input?.device else { return [] }
        let all = device.activeFormat.supportedMaxPhotoDimensions.map { Resolution(width: $0.width, height: $0.height) }
        var seen = Set<Int>()
        return all.sorted { $0.megapixels < $1.megapixels }.filter { seen.insert($0.megapixels).inserted }
    }

    private func adoptResolutions(_ options: [Resolution]) {
        resolutions = options
        let saved = defaults.integer(forKey: Keys.megapixels)
        // Default 24 MP when offered (Apple's default), otherwise the biggest.
        resolution = options.first { $0.megapixels == saved }
            ?? options.first { $0.megapixels == 24 }
            ?? options.last
    }

    // MARK: - Preview and rotation

    func attach(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        makeRotationCoordinator()
    }

    private func makeRotationCoordinator() {
        guard let layer = previewLayer, let device = input?.device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = coordinator
        layer.connection?.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
    }

    // MARK: - Zoom

    /// Sets the zoom in Camera app terms (0.5×, 1×, 2×, 5×), clamped to what the camera can do.
    func applyZoom(_ value: CGFloat, animated: Bool = true) {
        let clamped = max(zoomStops.first ?? 1, min(value, maxZoom))
        zoom = clamped
        let scale = zoomScale
        sessionQueue.async { [weak self] in
            guard let device = self?.input?.device else { return }
            let factor = max(device.minAvailableVideoZoomFactor,
                             min(clamped * scale, device.maxAvailableVideoZoomFactor))
            do {
                try device.lockForConfiguration()
                if animated {
                    device.ramp(toVideoZoomFactor: factor, withRate: 16)
                } else {
                    device.videoZoomFactor = factor
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    /// Pinch zoom: up to 15× digital past the telephoto, like the Camera app.
    var maxZoom: CGFloat { max((zoomStops.last ?? 1) * 3, 1) }

    // MARK: - Flip

    func flip() {
        let newPosition: AVCaptureDevice.Position = position == .back ? .front : .back
        position = newPosition
        status = .starting
        sessionQueue.async { [weak self] in
            guard let self, let device = Self.bestDevice(for: newPosition) else { return }
            self.session.beginConfiguration()
            if let old = self.input { self.session.removeInput(old) }
            if let newInput = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.input = newInput
            }
            self.session.sessionPreset = .photo
            Self.chooseLargestPhotoFormat(for: device)
            self.configurePhotoOutput(for: device)
            self.zoomScale = Self.zoomScale(for: device)
            self.session.commitConfiguration()
            let stops = self.currentZoomStops()
            let resolutions = self.currentResolutions()
            let flashAvailable = device.hasFlash
            Task { @MainActor in
                self.zoomStops = stops
                self.flashAvailable = flashAvailable
                self.adoptResolutions(resolutions)
                self.applyZoom(1, animated: false)
                self.makeRotationCoordinator()
                if self.isActive { self.status = .running }
            }
        }
    }

    // MARK: - Taking photos

    /// The shutter: the on-screen button, a volume button, or a DiTAG press. Runs the self-timer
    /// and the photos-per-press burst. Returns false if the camera is not ready.
    @discardableResult
    func shoot() -> Bool {
        guard isActive, status == .running, countdown == nil, shootTask == nil else { return false }
        let timer = timerSeconds
        let count = photosPerPress
        shootTask = Task { [weak self] in
            guard let self else { return }
            defer { self.shootTask = nil; self.countdown = nil }
            if timer > 0 {
                for second in stride(from: timer, to: 0, by: -1) {
                    self.countdown = second
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                }
                self.countdown = nil
            }
            for index in 0..<count {
                if Task.isCancelled { return }
                self.captureOne()
                if index < count - 1 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
        }
        return true
    }

    private func captureOne() {
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        let dimensions = resolution?.dimensions
        let flashMode = flashAvailable ? flash.mode : .off
        captureTick += 1
        isCapturing = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let key = UUID()
        let processor = PhotoProcessor { [weak self] data in
            Task { @MainActor in self?.finished(data, key: key) }
        }
        processors[key] = processor
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let output = self.photoOutput
            let settings: AVCapturePhotoSettings
            if output.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            if let dimensions,
               dimensions.width <= output.maxPhotoDimensions.width,
               dimensions.height <= output.maxPhotoDimensions.height {
                settings.maxPhotoDimensions = dimensions
            } else {
                settings.maxPhotoDimensions = output.maxPhotoDimensions
            }
            settings.photoQualityPrioritization = output.maxPhotoQualityPrioritization
            if output.supportedFlashModes.contains(flashMode) {
                settings.flashMode = flashMode
            }
            if let angle, let connection = output.connection(with: .video),
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            output.capturePhoto(with: settings, delegate: processor)
        }
    }

    private func finished(_ data: Data?, key: UUID) {
        processors[key] = nil
        isCapturing = !processors.isEmpty
        guard let data else {
            saveProblem = "That photo didn't come out. Try again."
            return
        }
        if let image = UIImage(data: data) {
            Task {
                let thumbnail = await image.byPreparingThumbnail(ofSize: CGSize(width: 160, height: 160))
                lastThumbnail = thumbnail ?? image
            }
        }
        save(data)
    }

    private func save(_ data: Data) {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                saveProblem = "Allow DiTether to add photos in Settings → Privacy → Photos."
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }
                saveProblem = nil
            } catch {
                saveProblem = "Couldn't save the photo to your library."
            }
        }
    }

    func openPhotos() {
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url)
        }
    }
}

/// One capture's delegate. Hands over the finished HEIC data (or nil) once.
private final class PhotoProcessor: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: (Data?) -> Void
    private var data: Data?

    init(completion: @escaping (Data?) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        data = error == nil ? photo.fileDataRepresentation() : nil
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        completion(error == nil ? data : nil)
    }
}

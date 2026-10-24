import AppKit
import AVFoundation
import ClosetalkCore
import os

/// Connects the hotkey to recording, transcription, and pasting, and keeps the menu bar icon in sync.
/// Everything here runs on the main thread; only transcription runs elsewhere.
@MainActor
final class DictationController {
    /// Clips shorter than a quarter second are almost always accidental.
    private static let minimumSamples = Recorder.sampleRate / 4
    private nonisolated static let log = Logger(subsystem: "dev.gsajith.Closetalk", category: "dictation")
    /// "Talk now" once the mic is live, and a different sound when recording ends.
    private static let startSound = NSSound(named: "Tink")
    private static let stopSound = NSSound(named: "Pop")
    /// Safety net if a key release never reaches us (e.g. the screen locked mid-hold).
    private static let maxRecordingLength: TimeInterval = 5 * 60
    /// Just past HotkeyStateMachine's quick-tap window (0.2 s), so a tap never shows the island.
    private static let islandDelay: TimeInterval = 0.25

    private let menuBar: MenuBarController
    private let setup: SetupModel
    private let recorder = Recorder()
    private let island = RecordingIsland()
    private let transcriber = Transcriber()
    private var machine = HotkeyStateMachine()
    private var spacing = SpacingPolicy()
    private var monitor: HotkeyMonitor?
    /// A model is loaded, sample or full, so dictation works.
    private var modelReady = false
    private var fullModelReady = false
    private var usingSampleModel = false
    private var isRecording = false
    /// Bumped per recording so a late "mic is live" callback from a cancelled recording is ignored.
    private var recordingID = 0
    private var pendingTranscriptions = 0
    private var loadProgress: Double?
    private var modelError: String?
    private var recordingTimeout: DispatchWorkItem?
    /// Transcriptions run one at a time, in order, so back-to-back dictations paste in the order spoken.
    private var lastTranscription: Task<Void, Never>?

    init(menuBar: MenuBarController, setup: SetupModel) {
        self.menuBar = menuBar
        self.setup = setup
        setup.startRecordingShortcut = { [weak self] onStep in self?.recordShortcut(onStep: onStep) ?? false }
        setup.stopRecordingShortcut = { [weak self] in self?.stopRecordingShortcut() }
    }

    /// Permissions are requested from the setup window, not here.
    func start() {
        loadModel()
        startMonitor()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Self.log.debug("spacing reset: activated \(app?.bundleIdentifier ?? "?", privacy: .public)")
            MainActor.assumeIsolated { self?.spacing.reset() }
        }
        // A locked or sleeping Mac can swallow the key release, so stop listening then.
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle(.otherInput) }
            }
        }
    }

    /// Loads the model, retrying every 30 s. Failures are often a dropped connection during the first download.
    /// A first launch starts with the sample model, so dictation works while the full one gets ready.
    private func loadModel() {
        // Asked once, before anything loads: the sample model's compile fills the same cache that
        // hasCompiledBefore looks at for versions without the marker.
        let firstTime = !Transcriber.hasCompiledBefore
        Task {
            while !fullModelReady {
                modelError = nil
                var downloadStart: Date?
                var loadingStarted = false
                do {
                    try await transcriber.load(sampleFirst: firstTime) { event in
                        Task { @MainActor in
                            // These tasks can run out of order, so a late report must not undo a later state.
                            guard !self.fullModelReady else { return }
                            switch event {
                            case .sampleLoading:
                                self.setup.setSampleModel(.loading)
                            case .sampleFailed:
                                self.setup.setSampleModel(.none)
                            case .sampleReady:
                                self.modelReady = true
                                self.usingSampleModel = true
                                self.setup.setSampleModel(.ready)
                            case .downloading(let fraction):
                                guard !loadingStarted else { return }
                                let start = downloadStart ?? Date()
                                downloadStart = start
                                self.loadProgress = fraction
                                self.setup.setSpeechModel(.downloading(fraction: fraction, startedAt: start))
                            case .loading:
                                loadingStarted = true
                                self.loadProgress = nil
                                self.setup.setSpeechModel(.compiling(startedAt: Date(), firstTime: firstTime))
                            }
                            self.refreshMenu()
                        }
                    }
                    fullModelReady = true
                    modelReady = true
                    usingSampleModel = false
                    setup.setSpeechModel(.ready)
                } catch {
                    Self.log.error("model load failed: \(error.localizedDescription, privacy: .public)")
                    modelError = "Model failed to load, retrying in 30 s: \(error.localizedDescription)"
                    setup.setSpeechModel(.failed(message: error.localizedDescription))
                    refreshMenu()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            refreshMenu()
        }
    }

    /// The tap needs Accessibility. Until it's granted, retry every couple of seconds. Trying to create
    /// the tap without it makes macOS show its own prompt, so wait until it's on: the setup window asks.
    private func startMonitor() {
        let monitor = HotkeyMonitor(shortcut: DictationShortcutSettings.shortcut) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        if AXIsProcessTrusted(), monitor.start() {
            self.monitor = monitor
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startMonitor() }
        }
        refreshMenu()
    }

    /// Records a new shortcut through the event tap, which stops dictating meanwhile, and saves it when one
    /// comes through. `onStep` sees every step after that. Returns false when the tap isn't running yet,
    /// which means Accessibility isn't on.
    func recordShortcut(onStep: @escaping (ShortcutRecorder.Step) -> Void) -> Bool {
        guard let monitor else { return false }
        monitor.record { [weak self] step in
            MainActor.assumeIsolated {
                if case .done(let shortcut) = step { self?.save(shortcut) }
                onStep(step)
            }
        }
        return true
    }

    /// Ends a recording that's still going, back to listening for the saved shortcut.
    func stopRecordingShortcut() {
        monitor?.listen(for: DictationShortcutSettings.shortcut)
    }

    private func save(_ shortcut: DictationShortcut) {
        DictationShortcutSettings.shortcut = shortcut
        monitor?.listen(for: shortcut)
        setup.refreshStatus()
        refreshMenu()
    }

    private func handle(_ event: HotkeyEvent) {
        if case .otherInput = event {
            // Every key press, click and scroll lands here, so this only logs at debug level.
            Self.log.debug("spacing reset: key or click")
            spacing.reset()
        }
        guard modelReady, let action = machine.handle(event) else { return }

        switch action {
        case .startRecording:
            recordingID += 1
            let id = recordingID
            let pressedAt = ProcessInfo.processInfo.systemUptime
            do {
                try recorder.start(device: MicrophoneSettings.selectedDevice(), onFirstAudio: { [weak self] in
                    guard let self, self.isRecording, self.recordingID == id else { return }
                    let delay = Int((ProcessInfo.processInfo.systemUptime - pressedAt) * 1000)
                    Self.log.notice("mic live \(delay) ms after key down")
                    Self.play(Self.startSound)
                }, onLevel: { [weak self] rms in
                    self?.island.model.levels.append(rms: rms)
                })
                isRecording = true
                // Shown once the key has been held past a quick tap, so taps and shortcuts don't flash it.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.islandDelay) { [weak self] in
                    guard let self, self.isRecording, self.recordingID == id else { return }
                    self.island.showRecording()
                }
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.isRecording, self.recordingID == id else { return }
                    Self.log.notice("recording hit the length limit, cancelling")
                    self.handle(.otherInput)
                }
                recordingTimeout = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxRecordingLength, execute: timeout)
            } catch {
                menuBar.update(.error("Microphone error: \(error.localizedDescription)"))
                return
            }
        case .cancelRecording:
            guard isRecording else { return }
            _ = recorder.stop()
            isRecording = false
            recordingTimeout?.cancel()
            settleIsland()
        case .finishRecording:
            guard isRecording else { return }
            let samples = recorder.stop()
            isRecording = false
            recordingTimeout?.cancel()
            Self.play(Self.stopSound)
            if samples.count >= Self.minimumSamples { transcribe(samples) }
            settleIsland()
        }
        refreshMenu()
    }

    private func transcribe(_ samples: [Float]) {
        pendingTranscriptions += 1
        lastTranscription = Task { [previous = lastTranscription, transcriber] in
            await previous?.value
            let started = ProcessInfo.processInfo.systemUptime
            var raw = ""
            do {
                raw = try await transcriber.transcribe(samples)
            } catch {
                Self.log.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            }
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            let audioLength = samples.count * 1000 / Recorder.sampleRate
            Self.log.notice("transcribed \(audioLength) ms of audio in \(elapsed) ms")
            pendingTranscriptions -= 1
            if let text = TranscriptCleaner.clean(raw) {
                let now = ProcessInfo.processInfo.systemUptime
                let prefix = spacing.prefix(at: now)
                Self.log.notice("insert \(text.count) chars, leading space: \(!prefix.isEmpty)")
                Inserter.insert(prefix + text)
                setup.dictationInserted()
                spacing.recordInsert(at: now)
            }
            settleIsland()
            refreshMenu()
        }
    }

    /// Between recordings the island shows a spinner until every pending transcription has landed.
    /// While recording, the recording branch shows it once the key is held past a quick tap.
    private func settleIsland() {
        guard !isRecording else { return }
        if pendingTranscriptions > 0 { island.showTranscribing() } else { island.hide() }
    }

    private static func play(_ sound: NSSound?) {
        sound?.stop()
        sound?.play()
    }

    private func refreshMenu() {
        menuBar.update(state)
    }

    private var state: AppState {
        if monitor == nil { return .error("Needs Accessibility permission") }
        if DictationShortcutSettings.shortcut == nil { return .error("Choose a dictation key in Setup…") }
        // Checked fresh each time, so turning the mic on in System Settings clears it without a relaunch.
        if MicrophonePermission.isDenied {
            return .error("Needs Microphone permission")
        }
        // A failure while the sample model works still lets people dictate, but the menu says so.
        if let modelError { return .error(modelError) }
        if !modelReady { return .loadingModel(progress: loadProgress) }
        if isRecording { return .recording }
        return pendingTranscriptions > 0 ? .transcribing : .idle(sampleModel: usingSampleModel)
    }
}

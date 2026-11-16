import AppKit
import AVFoundation
import Foundation
import Speech

/// Composer mic — Speech framework dictation into the draft field.
@MainActor
final class SpeechDictation: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var lastError: String?

    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    private var baseText = ""
    private var onUpdate: ((String) -> Void)?

    var isAvailable: Bool {
        recognizer?.isAvailable == true
    }

    func toggle(base: String, onUpdate: @escaping (String) -> Void) {
        if isListening {
            stop()
        } else {
            start(base: base, onUpdate: onUpdate)
        }
    }

    func start(base: String, onUpdate: @escaping (String) -> Void) {
        lastError = nil
        guard let recognizer, recognizer.isAvailable else {
            lastError = "Speech recognition unavailable"
            return
        }
        self.onUpdate = onUpdate
        self.baseText = base

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.lastError = "Microphone / speech permission denied"
                    return
                }
                self.begin(recognizer: recognizer)
            }
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        onUpdate = nil
    }

    private func begin(recognizer: SFSpeechRecognizer) {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            req.addsPunctuation = true
        }
        request = req

        do {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                req.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            lastError = error.localizedDescription
            stop()
            return
        }

        isListening = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let spoken = result.bestTranscription.formattedString
                    let spacer = self.baseText.isEmpty || self.baseText.hasSuffix(" ") ? "" : " "
                    self.onUpdate?(self.baseText + spacer + spoken)
                    if result.isFinal {
                        self.stop()
                    }
                }
                if let error {
                    // Ignore cancel noise.
                    let ns = error as NSError
                    if ns.domain != "kAFAssistantErrorDomain" || ns.code != 216 {
                        self.lastError = error.localizedDescription
                    }
                    self.stop()
                }
            }
        }
    }
}

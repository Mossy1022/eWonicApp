//
//  NativeSTTService.swift
//  eWonicApp
//
//  Created by Evan Moscoso on 5/18/25.
//

import Foundation
import AVFoundation
import Speech
import Combine

// MARK: – Speech‑to‑Text error envelope used by the rest of the app
enum STTError: Error, LocalizedError {
  case unavailable
  case permissionDenied
  case recognitionError(Error)
  case taskError(String)
  case noAudioInput

  var errorDescription: String? {
    switch self {
    case .unavailable:          return "Speech recognition is not available on this device or for the selected language."
    case .permissionDenied:     return "Speech recognition permission was denied."
    case .recognitionError(let e): return "Recognition failed: \(e.localizedDescription)"
    case .taskError(let msg):   return msg
    case .noAudioInput:         return "No audio input was detected or the input was too quiet."
    }
  }
}

/// Manages the AVAudioEngine + SFSpeechRecognizer pipeline and publishes
/// partial / final results via Combine.
///
/// Must inherit from `NSObject` – `SFSpeechRecognizerDelegate` in Objective‑C
/// extends `NSObjectProtocol`.
final class NativeSTTService: NSObject, ObservableObject {
  // MARK: – Private engine / recognizer plumbing
  private var speechRecognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private let audioEngine = AVAudioEngine()

  private var segmentStart = Date()
  private let maxSegmentSeconds: TimeInterval = 120
  private var lastBufferHostTime: UInt64 = 0
  private let vadPause: TimeInterval = 0.4
  private let sentenceRegex = try! NSRegularExpression(pattern:"[.!?]$")
  private var watchdogTimer: DispatchSourceTimer?

  // MARK: – State exposed to SwiftUI
  @Published private(set) var isListening = false
  @Published var recognizedText: String = ""

  // MARK: – Combine subjects
  let partialResultSubject = PassthroughSubject<String,Never>()
  let finalResultSubject   = PassthroughSubject<String,STTError>()

  // Apple (as of iOS 17) does not expose a Swift enum for the “no speech”
  // condition, only an integer code. 203 has been stable since iOS 10.
  private let noSpeechDetectedCode = 203

  // MARK: – Permission helpers
  func requestPermission(_ completion:@escaping (Bool)->Void) {
    SFSpeechRecognizer.requestAuthorization { auth in
      DispatchQueue.main.async {
        guard auth == .authorized else { completion(false); return }
        AVAudioSession.sharedInstance().requestRecordPermission { micOK in
          DispatchQueue.main.async { completion(micOK) }
        }
      }
    }
  }

  // MARK: – Recognizer configuration ------------------------------------------------
  func setupSpeechRecognizer(languageCode: String) {
    let locale = Locale(identifier: languageCode)
    guard let recognizer = SFSpeechRecognizer(locale: locale) else {
      finalResultSubject.send(completion: .failure(.unavailable))
      return
    }

    speechRecognizer = recognizer
    recognizer.delegate = self

    guard recognizer.isAvailable else {
      finalResultSubject.send(completion: .failure(.unavailable))
      return
    }

    print("[NativeSTT] recognizer ready – lang: \(languageCode), on‑device: \(recognizer.supportsOnDeviceRecognition)")
  }

  // MARK: – Start / Stop ------------------------------------------------------------
  func startTranscribing(languageCode: String) {
    guard !isListening else { print("[NativeSTT] already listening"); return }

    setupSpeechRecognizer(languageCode: languageCode)
    guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }

    // Cancel any prior task
    recognitionTask?.cancel(); recognitionTask = nil

    AudioSessionManager.shared.begin()

    // Build request & task ----------------------------------------------------------
    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    guard let req = recognitionRequest else { fatalError("Could not create SFSpeechAudioBufferRecognitionRequest") }
    req.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }

    segmentStart = Date()
    watchdogTimer?.cancel()
    watchdogTimer = DispatchSource.makeTimerSource()
    watchdogTimer?.schedule(deadline:.now()+55*60)
    watchdogTimer?.setEventHandler { [weak self] in self?.rotateTask() }
    watchdogTimer?.resume()

    recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, err in
      guard let self = self else { return }
      var isFinal = false

      if let r = result {
        let text = r.bestTranscription.formattedString
        self.recognizedText = text
        self.partialResultSubject.send(text)
        isFinal = r.isFinal
        print("[NativeSTT] partial – \(text)")

        if Date().timeIntervalSince(self.segmentStart) > self.maxSegmentSeconds {
          DispatchQueue.main.async { self.rotateTask() }
        }
      }

      // Terminal path (either error or final)
      if err != nil || isFinal {
        self.stopTranscribing()

          if let e = err as NSError? {
            print("[NativeSTT] error – domain: \(e.domain) code: \(e.code)")
            if e.domain == "kAFAssistantErrorDomain" && e.code == self.noSpeechDetectedCode {
              self.finalResultSubject.send(completion: .failure(.noAudioInput))
            } else {
              self.finalResultSubject.send(completion: .failure(.recognitionError(e)))
            }
            return
          }


        // Success path – final produced
        if !self.recognizedText.isEmpty {
          self.finalResultSubject.send(self.recognizedText)
          self.finalResultSubject.send(completion: .finished)
          print("[NativeSTT] final – \(self.recognizedText)")
        } else {
          self.finalResultSubject.send(completion: .failure(.noAudioInput))
          print("[NativeSTT] final empty – treated as noAudioInput")
        }
      }
    }

    // Microphone tap ---------------------------------------------------------------
    let node   = audioEngine.inputNode
    let format = node.outputFormat(forBus: 0)
    guard format.sampleRate > 0 else {
      finalResultSubject.send(completion: .failure(.taskError("Invalid microphone format")))
      return
    }

    node.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, when in
      self.recognitionRequest?.append(buf)

      if self.lastBufferHostTime != 0 {
        let current = AVAudioTime.seconds(forHostTime: when.hostTime)
        let last    = AVAudioTime.seconds(forHostTime: self.lastBufferHostTime)
        let delta   = current - last
        if delta >= self.vadPause {
          let text = self.recognizedText
          let range = NSRange(location: max(text.count - 1, 0), length: text.isEmpty ? 0 : 1)
          if self.sentenceRegex.firstMatch(in: text, options: [], range: range) != nil {
            DispatchQueue.main.async { self.rotateTask() }
          }
        }
      }
      self.lastBufferHostTime = when.hostTime
    }

    audioEngine.prepare()
    do {
      try audioEngine.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
          guard let self = self else { return }
          if self.isListening && self.recognizedText.count > 3 {
            print("[NativeSTT] ⏱ Timeout triggered – forcing final result")
            self.finalResultSubject.send(self.recognizedText)
            self.finalResultSubject.send(completion: .finished)
            self.stopTranscribing()
          }
        }

      DispatchQueue.main.async { self.isListening = true }
      recognizedText = "Listening…"
      print("[NativeSTT] audio engine started")
    } catch {
      finalResultSubject.send(completion: .failure(.recognitionError(error)))
      stopTranscribing()
    }
  }

  func stopTranscribing() {
    guard isListening else { return }
    DispatchQueue.main.async { self.isListening = false }

    watchdogTimer?.cancel()

    AudioSessionManager.shared.end()

    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)

    recognitionRequest?.endAudio(); recognitionRequest = nil
    recognitionTask?.cancel();        recognitionTask  = nil
    print("[NativeSTT] stopped")
  }

  func rotateTask() {
    recognitionRequest?.endAudio(); recognitionRequest = nil
    recognitionTask?.cancel();        recognitionTask  = nil

    guard isListening, let recognizer = speechRecognizer else { return }

    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    guard let req = recognitionRequest else { return }
    req.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }

    recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, err in
      guard let self = self else { return }
      var isFinal = false

      if let r = result {
        let text = r.bestTranscription.formattedString
        self.recognizedText = text
        self.partialResultSubject.send(text)
        isFinal = r.isFinal
        print("[NativeSTT] partial – \(text)")
      }

      if err != nil || isFinal {
        self.stopTranscribing()

        if let e = err as NSError? {
          if e.domain == "kAFAssistantErrorDomain" && e.code == self.noSpeechDetectedCode {
            self.finalResultSubject.send(completion: .failure(.noAudioInput))
          } else {
            self.finalResultSubject.send(completion: .failure(.recognitionError(e)))
          }
          return
        }

        if !self.recognizedText.isEmpty {
          self.finalResultSubject.send(self.recognizedText)
          self.finalResultSubject.send(completion: .finished)
        } else {
          self.finalResultSubject.send(completion: .failure(.noAudioInput))
        }
      }
    }

    segmentStart = Date()
    lastBufferHostTime = 0
  }
}

// MARK: – Availability callbacks
extension NativeSTTService: SFSpeechRecognizerDelegate {
  func speechRecognizer(_ recognizer:SFSpeechRecognizer, availabilityDidChange available: Bool) {
    if !available {
      DispatchQueue.main.async { self.isListening = false }
      finalResultSubject.send(completion: .failure(.unavailable))
      print("[NativeSTT] recognizer became unavailable")
    } else {
      print("[NativeSTT] recognizer available again")
    }
  }
}

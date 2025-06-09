import Foundation

/// Unified error type for speech recognition across the app.
enum STTError: Error, LocalizedError, Equatable {
    case unavailable
    case permissionDenied
    case recognitionError(Error)
    case taskError(String)
    case noAudioInput

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Speech recognition is not available on this device or for the selected language."
        case .permissionDenied:
            return "Speech recognition permission was denied."
        case .recognitionError(let e):
            return "Recognition failed: \(e.localizedDescription)"
        case .taskError(let msg):
            return msg
        case .noAudioInput:
            return "No audio input was detected or the input was too quiet."
        }
    }

    /// Additional diagnostics that include underlying error details.
    var debugDescription: String {
        switch self {
        case .recognitionError(let e):
            let ns = e as NSError
            return "[\(ns.domain) code:\(ns.code)] \(ns.localizedDescription)"
        case .taskError(let msg):
            return msg
        default:
            return errorDescription ?? "Unknown error"
        }
    }

    static func == (lhs: STTError, rhs: STTError) -> Bool {
        switch (lhs, rhs) {
        case (.unavailable, .unavailable),
             (.permissionDenied, .permissionDenied),
             (.noAudioInput, .noAudioInput):
            return true
        case (.taskError(let lMsg), .taskError(let rMsg)):
            return lMsg == rMsg
        case (.recognitionError, .recognitionError):
            // Underlying NSError may differ, treat all recognition errors as equal
            return true
        default:
            return false
        }
    }
}

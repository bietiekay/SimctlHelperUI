import Foundation

enum FeedbackLevel: String, Equatable {
    case info
    case success
    case warning
    case error
}

struct FeedbackMessage: Identifiable, Equatable {
    let id = UUID()
    let level: FeedbackLevel
    let text: String

    init(level: FeedbackLevel, text: String) {
        self.level = level
        self.text = text
    }
}

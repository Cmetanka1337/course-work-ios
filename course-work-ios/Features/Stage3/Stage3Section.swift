import Foundation

enum Stage3Section: String, CaseIterable, Identifiable {
    case addWeek
    case closeWeek
    case history
    case calibration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .addWeek:
            return "Add Week"
        case .closeWeek:
            return "Close Week"
        case .history:
            return "History"
        case .calibration:
            return "Calibration"
        }
    }

    var subtitle: String {
        switch self {
        case .addWeek:
            return "Create the next pending week or seed a demo journey."
        case .closeWeek:
            return "Capture the actual outflow and save ground truth."
        case .history:
            return "Review closed weeks and the personalization audit trail."
        case .calibration:
            return "See whether personalization is active and when it updates."
        }
    }
}

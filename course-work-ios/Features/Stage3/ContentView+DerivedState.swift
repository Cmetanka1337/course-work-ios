import CoreData
import SwiftUI

extension ContentView {
    var latestPrediction: PredictionSnapshot? {
        predictionSnapshots.first
    }

    var latestCalibrationState: CalibrationStateRecord? {
        calibrationStates.first
    }

    var orderedWeeklyRecords: [WeeklyRecord] {
        weeklyRecords.sorted { ($0.weekStart ?? .distantPast) > ($1.weekStart ?? .distantPast) }
    }

    var pendingWeeks: [WeeklyRecord] {
        orderedWeeklyRecords.filter { !$0.hasActualOutcome }
    }

    var closedWeeks: [WeeklyRecord] {
        orderedWeeklyRecords.filter(\.hasActualOutcome)
    }

    var latestPendingWeek: WeeklyRecord? {
        pendingWeeks.first
    }

    var labeledSamples: [CalibrationSample] {
        (calibrationSnapshot?.samples ?? []).sorted { $0.weekIndex > $1.weekIndex }
    }

    var warmupWeeks: Int {
        contracts.featureContract.guardrails.warmupWeeks
    }

    var calibrationCadence: Int {
        calibrationStatus?.updateEveryWeeks ?? calibrationSnapshot?.config.updateEveryWeeks ?? 2
    }

    var canRetrainNow: Bool {
        calibrationStatus?.canRetrainNow ?? (labeledSamples.count >= warmupWeeks)
    }

    var personalizationIsActive: Bool {
        calibrationStates.first?.isActive ?? calibrationStatus?.isActive ?? false
    }

    var usesBlendedInference: Bool {
        personalizationIsActive && latestPrediction?.sourceMode == "blended"
    }

    var currentInferenceModeTitle: String {
        if usesBlendedInference {
            return "Blended personalization"
        }
        if orderedWeeklyRecords.count < warmupWeeks {
            return "RF warm-up"
        }
        return "RF-only"
    }

    var currentInferenceExplanation: String {
        if orderedWeeklyRecords.count < warmupWeeks {
            let remaining = max(0, warmupWeeks - orderedWeeklyRecords.count)
            return "The RF pipeline still needs \(remaining) more week(s) of history before a fresh prediction can run."
        }

        if usesBlendedInference {
            let alpha = calibrationSnapshot?.config.alpha ?? contracts.featureContract.guardrails.alphaAfterWarmup
            return "Personalization is active. The final output blends the RF probabilities with the local calibrator using alpha \(formatPercent(alpha))."
        }

        if labeledSamples.count < warmupWeeks {
            let remaining = max(0, warmupWeeks - labeledSamples.count)
            return "Predictions are RF-only for now. Save \(remaining) more labeled week(s) before the personal calibrator can warm up."
        }

        return "Warm-up labels are ready, but the calibrator is not active yet. Use Retrain now or wait for the next scheduled update."
    }

    var nextRecommendedActionText: String {
        if orderedWeeklyRecords.isEmpty {
            return "Start with Seed demo data or Add pending week."
        }
        if latestPendingWeek != nil {
            return "Open Close Week and save the real outflow."
        }
        if labeledSamples.count < warmupWeeks {
            let remaining = max(0, warmupWeeks - labeledSamples.count)
            return "Close \(remaining) more labeled week(s) to finish calibration warm-up."
        }
        if !personalizationIsActive {
            return canRetrainNow ? "Run Retrain now to activate blending." : "Wait for the next scheduled calibration update."
        }
        return "Keep adding and closing weeks so personalization keeps adapting."
    }

    var warmupSummaryText: String {
        let historyRemaining = max(0, warmupWeeks - orderedWeeklyRecords.count)
        let labelRemaining = max(0, warmupWeeks - labeledSamples.count)

        if historyRemaining > 0 {
            return "Prediction history warm-up needs \(historyRemaining) more week(s)."
        }
        if labelRemaining > 0 {
            return "Label warm-up needs \(labelRemaining) more closed week(s)."
        }
        if personalizationIsActive {
            return "Warm-up complete. Personalized blending is available."
        }
        return "Warm-up complete. Waiting for the next training pass."
    }

    var nextAutomaticUpdateText: String {
        if labeledSamples.count < warmupWeeks {
            let remaining = max(0, warmupWeeks - labeledSamples.count)
            return "After \(remaining) more labeled week(s)"
        }

        let remainingCadence = max(0, calibrationCadence - (calibrationStatus?.weeksSinceLastUpdate ?? 0))
        if remainingCadence == 0 {
            return "Ready now"
        }
        return "After \(remainingCadence) more labeled week(s)"
    }

    var retrainAvailabilityText: String {
        canRetrainNow ? "Retrain available" : "Retrain locked"
    }

    var lastCalibrationStateSaveText: String {
        guard let timestamp = latestCalibrationState?.updatedAt else {
            return "No calibration state yet"
        }
        return timestampFormatter.string(from: timestamp)
    }

    var calibrationStateNote: String {
        latestCalibrationState?.notes ?? "No calibration events yet."
    }

    var storedWeightsStatusText: String {
        guard let snapshot = calibrationSnapshot else {
            return "No state saved yet"
        }
        return snapshotLooksPersonalized(snapshot) ? "Personalized weights saved" : "Identity weights only"
    }

    var parsedCloseOutflow: Double? {
        let normalized = closeOutflowInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }

    var nextPendingWeekDate: Date? {
        let calendar = Calendar(identifier: .gregorian)
        let latestDate = orderedWeeklyRecords.compactMap(\.weekStart).max()
            ?? calendar.date(from: DateComponents(year: 2026, month: 4, day: 6))
        return latestDate.flatMap { calendar.date(byAdding: .weekOfYear, value: 1, to: $0) }
    }

    var nextPendingWeekIndex: Int {
        (orderedWeeklyRecords.map { $0.weekIndex?.intValue ?? -1 }.max() ?? -1) + 1
    }

    func saveOutcomePreviewLines(for week: WeeklyRecord, amount: Double) -> [String] {
        var lines = [
            "Store raw outflow \(formatNumber(amount)) for week idx \(week.weekIndex?.intValue ?? 0).",
            "Derive \(bucketName(spendBucket(for: amount))) using the frozen training thresholds."
        ]

        let historyCount = historyCount(upTo: week)
        if historyCount < warmupWeeks {
            lines.append("Keep this week as local ground truth only for now because prediction history is still in warm-up (\(historyCount)/\(warmupWeeks)).")
        } else {
            lines.append("Append one labeled sample to the calibrator buffer so this week can help the next personalization update.")
        }

        return lines
    }

    func calibrationLabelStatus(for week: WeeklyRecord) -> String {
        guard week.hasActualOutcome else {
            return "Not closed yet"
        }

        let weekIndex = week.weekIndex?.intValue ?? -1
        if labeledSamples.contains(where: { $0.weekIndex == weekIndex }) {
            return "Saved and included in buffer"
        }

        let historyCount = historyCount(upTo: week)
        if historyCount < warmupWeeks {
            return "Saved locally only (prediction warm-up)"
        }

        return "Saved locally"
    }

    func historyCount(upTo week: WeeklyRecord) -> Int {
        orderedWeeklyRecords.filter { ($0.weekStart ?? .distantPast) <= (week.weekStart ?? .distantFuture) }.count
    }

    func snapshotLooksPersonalized(_ snapshot: CalibrationStateSnapshot) -> Bool {
        let identity = SoftmaxCalibrator.identity()
        guard snapshot.weights.count == identity.weights.count, snapshot.bias.count == identity.bias.count else {
            return false
        }

        let weightsMatchIdentity = zip(snapshot.weights, identity.weights).allSatisfy { lhsRow, rhsRow in
            guard lhsRow.count == rhsRow.count else { return false }
            return zip(lhsRow, rhsRow).allSatisfy { abs($0 - $1) < 0.0000001 }
        }

        let biasMatchesIdentity = zip(snapshot.bias, identity.bias).allSatisfy { abs($0 - $1) < 0.0000001 }
        return !(weightsMatchIdentity && biasMatchesIdentity)
    }

    func bucketName(_ bucket: Int) -> String {
        switch bucket {
        case 0:
            return "Bucket 0 • No spend"
        case 1:
            return "Bucket 1 • Low spend"
        case 2:
            return "Bucket 2 • Typical spend"
        case 3:
            return "Bucket 3 • High spend"
        default:
            return "Bucket \(bucket)"
        }
    }

    func spendBucket(for outflow: Double) -> Int {
        PersonalizationService.spendBucket(for: max(0.0, outflow), thresholds: contracts.thresholds)
    }

    func formatNumber(_ value: Double) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    func formatPercent(_ value: Double) -> String {
        percentageFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    func numericValue(_ value: NSNumber?) -> Double {
        value?.doubleValue ?? 0
    }
}

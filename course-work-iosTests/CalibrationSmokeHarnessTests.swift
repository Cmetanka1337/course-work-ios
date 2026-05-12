import CoreData
import CoreML
import XCTest
@testable import course_work_ios

@MainActor
final class CalibrationSmokeHarnessTests: XCTestCase {
    func testStage3CalibrationHistoricalReplaySmoke() throws {
        let environment = ProcessInfo.processInfo.environment
        let storePath = try XCTUnwrap(
            environment["CALIBRATION_SMOKE_STORE_URL"],
            "CALIBRATION_SMOKE_STORE_URL must be provided by the smoke script."
        )
        let reportPath = try XCTUnwrap(
            environment["CALIBRATION_SMOKE_REPORT_PATH"],
            "CALIBRATION_SMOKE_REPORT_PATH must be provided by the smoke script."
        )
        let shouldRunRealCoreML = environment["CALIBRATION_SMOKE_RUN_REAL_COREML"] != "0"

        let storeURL = URL(fileURLWithPath: storePath)
        let reportURL = URL(fileURLWithPath: reportPath)
        let contracts = AppContractStore()
        let scenario = makeReplayScenario()
        let predictor = ReplayPredictor(probabilitiesByWeekOfYear: Dictionary(uniqueKeysWithValues: scenario.map { ($0.weekOfYear, $0.baseProbabilities) }))
        let smokeReport = CalibrationSmokeReport(
            warmupWeeks: contracts.featureContract.guardrails.warmupWeeks,
            cadence: 2,
            alpha: contracts.featureContract.guardrails.alphaAfterWarmup,
            storePath: storePath
        )
        var outcome = HarnessOutcome(report: smokeReport)

        defer {
            try? FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? outcome.report.render(status: outcome.status).write(to: reportURL, atomically: true, encoding: .utf8)
        }

        do {
            let controller = PersistenceController(storeURL: storeURL)
            let context = controller.container.viewContext
            let service = try PersonalizationService(contracts: contracts, predictor: predictor)

            for week in scenario.prefix(15) {
                let record = makeWeeklyRecord(from: week, in: context)
                try context.save()

                let currentHistory = try fetchWeeklyRecords(in: context)
                let predictionResult = try service.evaluateAndPersistPrediction(for: currentHistory, in: context)
                let closeResult = try service.closeWeek(record, actualOutflow: week.actualOutflow, history: currentHistory, in: context)
                let status = try service.fetchCalibrationStatus(in: context)
                let snapshot = try service.fetchCalibrationSnapshot(in: context)
                let latestPrediction = try fetchLatestPredictionSnapshot(in: context)

                outcome.report.rows.append(
                    ReplayReportRow(
                        weekIndex: week.weekIndex,
                        referenceOutflow: week.referenceOutflow,
                        actualOutflow: week.actualOutflow,
                        derivedBucket: PersonalizationService.spendBucket(for: week.actualOutflow, thresholds: contracts.thresholds),
                        labelBuffered: snapshot.samples.contains(where: { $0.weekIndex == week.weekIndex }),
                        mode: modeLabel(for: predictionResult, sourceMode: latestPrediction?.sourceMode),
                        updateCount: status.updateCount
                    )
                )

                if week.weekIndex <= 6 {
                    try assert(!snapshot.samples.contains(where: { $0.weekIndex == week.weekIndex }), "Weeks before history warm-up must not enter the calibration buffer.", report: &outcome.report)
                    try assert(closeResult == .updatedOnlyWarmup(completedWeeks: week.weekIndex + 1, requiredWeeks: contracts.featureContract.guardrails.warmupWeeks), "Weeks before warm-up should close without creating calibration labels.", report: &outcome.report)
                } else if week.weekIndex < 14 {
                    try assert(closeResult == .updatedAndQueuedForCalibration, "Warm-up labels before the final replay week should queue for calibration.", report: &outcome.report)
                    try assert(status.isActive == false, "Personalization should remain inactive until the final warm-up label triggers training.", report: &outcome.report)
                }
            }

            let preRestartStatus = try service.fetchCalibrationStatus(in: context)
            let preRestartSnapshot = try service.fetchCalibrationSnapshot(in: context)
            try assert(preRestartStatus.isActive, "Calibration must become active after the replay warm-up completes.", report: &outcome.report)
            try assert(preRestartStatus.updateCount >= 1, "At least one calibration update must complete during replay.", report: &outcome.report)
            try assert(preRestartSnapshot.samples.count == 8, "Replay should accumulate exactly 8 labeled samples before evaluation.", report: &outcome.report)
            try assert(snapshotLooksPersonalized(preRestartSnapshot), "Calibration weights should no longer match the identity matrix after retraining.", report: &outcome.report)

            outcome.report.roundTrip = "Before restart: labeled=\(preRestartSnapshot.samples.count), active=\(preRestartStatus.isActive), updates=\(preRestartStatus.updateCount)"

            let restartedController = PersistenceController(storeURL: storeURL)
            let restartedContext = restartedController.container.viewContext
            let restartedService = try PersonalizationService(contracts: contracts, predictor: predictor)
            let restartedStatus = try restartedService.fetchCalibrationStatus(in: restartedContext)
            let restartedSnapshot = try restartedService.fetchCalibrationSnapshot(in: restartedContext)

            try assert(restartedStatus.isActive, "Calibration state should stay active after reopening the temp store.", report: &outcome.report)
            try assert(restartedStatus.updateCount == preRestartStatus.updateCount, "Update count should persist across restart.", report: &outcome.report)
            try assert(restartedSnapshot.samples == preRestartSnapshot.samples, "Calibration buffer should survive restart without corruption.", report: &outcome.report)
            try assert(snapshotLooksPersonalized(restartedSnapshot), "Personalized weights should survive restart.", report: &outcome.report)

            outcome.report.roundTrip += " | After restart: labeled=\(restartedSnapshot.samples.count), active=\(restartedStatus.isActive), updates=\(restartedStatus.updateCount)"

            let evaluationWeek = try XCTUnwrap(scenario.last)
            _ = makeWeeklyRecord(from: evaluationWeek, in: restartedContext)
            try restartedContext.save()

            let evaluationHistory = try fetchWeeklyRecords(in: restartedContext)
            let baselineService = PredictionService(
                contract: contracts.featureContract,
                thresholds: contracts.thresholds,
                predictor: predictor
            )
            let baselineResult = try baselineService.runPrediction(for: evaluationHistory)
            guard case let .ready(baseComputation) = baselineResult else {
                throw SmokeHarnessError.missingReadyPrediction("Evaluation week should be past RF warm-up.")
            }

            let finalResult = try restartedService.evaluateAndPersistPrediction(for: evaluationHistory, in: restartedContext)
            guard case let .ready(finalComputation) = finalResult else {
                throw SmokeHarnessError.missingReadyPrediction("Evaluation week should return a blended prediction.")
            }

            let baselineProbabilities = probabilitiesArray(from: baseComputation.probabilities)
            let finalProbabilities = probabilitiesArray(from: finalComputation.probabilities)
            let trueClass = 3
            let baseBrier = brierScore(probabilities: baselineProbabilities, trueClass: trueClass)
            let finalBrier = brierScore(probabilities: finalProbabilities, trueClass: trueClass)
            let baseLogLoss = logLoss(probabilities: baselineProbabilities, trueClass: trueClass)
            let finalLogLoss = logLoss(probabilities: finalProbabilities, trueClass: trueClass)

            outcome.report.rows.append(
                ReplayReportRow(
                    weekIndex: evaluationWeek.weekIndex,
                    referenceOutflow: evaluationWeek.referenceOutflow,
                    actualOutflow: evaluationWeek.actualOutflow,
                    derivedBucket: trueClass,
                    labelBuffered: false,
                    mode: "blended",
                    updateCount: restartedStatus.updateCount
                )
            )

            outcome.report.evaluation = EvaluationSummary(
                baselineProbabilities: baselineProbabilities,
                finalProbabilities: finalProbabilities,
                deltaTrueClassProbability: finalProbabilities[trueClass] - baselineProbabilities[trueClass],
                baseBrier: baseBrier,
                finalBrier: finalBrier,
                baseLogLoss: baseLogLoss,
                finalLogLoss: finalLogLoss
            )

            try assert(abs(baseComputation.diagnostics.sumProbs - 1.0) < 0.000001, "Baseline RF probabilities must stay normalized.", report: &outcome.report)
            try assert(abs(finalProbabilities.reduce(0.0, +) - 1.0) < 0.000001, "Blended probabilities must stay normalized.", report: &outcome.report)
            try assert(finalProbabilities[trueClass] > baselineProbabilities[trueClass], "Calibration should increase probability for the observed high-spend class on the evaluation week.", report: &outcome.report)
            try assert(finalBrier < baseBrier, "Calibration should improve Brier score on the evaluation week.", report: &outcome.report)
            try assert(finalLogLoss < baseLogLoss, "Calibration should improve log-loss on the evaluation week.", report: &outcome.report)

            if shouldRunRealCoreML {
                outcome.report.coreMLRows = try runRealCoreMLInformationalReplay(contracts: contracts)
            }

            outcome.status = "PASS"
        } catch {
            outcome.report.failureReason = "Smoke harness failed: \(error.localizedDescription)"
            throw error
        }
    }

    private func makeReplayScenario() -> [ReplayWeek] {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5)) ?? .distantPast

        let inflows: [Double] = [2680, 2740, 2810, 2890, 2960, 3040, 3110, 3180, 3240, 3300, 3360, 3320, 3275, 3210, 3160, 3120]
        let referenceOutflows: [Double] = [1860, 1940, 2025, 2140, 2235, 2320, 2410, 2495, 2580, 2660, 2745, 2810, 2875, 2920, 2880, 2840]
        let actualOutflows: [Double] = [7620, 7740, 7860, 7985, 8120, 8280, 8410, 8560, 8720, 8890, 9075, 9260, 9440, 9590, 9780, 9650]
        let txnCounts: [Double] = [5, 5, 6, 6, 7, 7, 8, 8, 8, 9, 9, 8, 7, 7, 6, 6]
        let diversities: [Double] = [3, 3, 3, 4, 4, 4, 5, 5, 5, 5, 4, 4, 4, 3, 3, 3]
        let probabilities: [[Double]] = [
            [0.08, 0.46, 0.30, 0.16],
            [0.08, 0.45, 0.31, 0.16],
            [0.07, 0.45, 0.31, 0.17],
            [0.07, 0.44, 0.32, 0.17],
            [0.07, 0.44, 0.32, 0.17],
            [0.06, 0.43, 0.33, 0.18],
            [0.06, 0.42, 0.34, 0.18],
            [0.06, 0.42, 0.33, 0.19],
            [0.06, 0.41, 0.34, 0.19],
            [0.05, 0.41, 0.34, 0.20],
            [0.05, 0.40, 0.35, 0.20],
            [0.05, 0.40, 0.35, 0.20],
            [0.05, 0.39, 0.36, 0.20],
            [0.05, 0.39, 0.35, 0.21],
            [0.05, 0.38, 0.36, 0.21],
            [0.06, 0.43, 0.33, 0.18]
        ]

        return inflows.indices.map { index in
            let weekStart = calendar.date(byAdding: .weekOfYear, value: index, to: start) ?? start
            let weekOfYear = Calendar(identifier: .iso8601).component(.weekOfYear, from: weekStart)
            return ReplayWeek(
                weekIndex: index,
                weekStart: weekStart,
                weekOfYear: weekOfYear,
                inflow: inflows[index],
                referenceOutflow: referenceOutflows[index],
                actualOutflow: actualOutflows[index],
                txnCount: txnCounts[index],
                categoryDiversity: diversities[index],
                baseProbabilities: probabilities[index]
            )
        }
    }

    private func makeWeeklyRecord(from week: ReplayWeek, in context: NSManagedObjectContext) -> WeeklyRecord {
        let record = WeeklyRecord(context: context)
        record.id = UUID()
        record.weekStart = week.weekStart
        record.weekIndex = NSNumber(value: week.weekIndex)
        record.inflow = NSNumber(value: week.inflow)
        record.outflow = NSNumber(value: week.referenceOutflow)
        record.net = NSNumber(value: week.inflow - week.referenceOutflow)
        record.txnCount = NSNumber(value: week.txnCount)
        record.categoryDiversity = NSNumber(value: week.categoryDiversity)
        record.modelSpendBucket = NSNumber(value: PersonalizationService.spendBucket(for: week.referenceOutflow, thresholds: AppContractStore().thresholds))
        record.modelNetBucket = NSNumber(value: 2)
        record.actualSpendAmount = 0
        record.actualSpendBucket = 0
        record.hasActualOutcome = false
        record.createdAt = week.weekStart
        record.updatedAt = week.weekStart
        return record
    }

    private func fetchWeeklyRecords(in context: NSManagedObjectContext) throws -> [WeeklyRecord] {
        let request: NSFetchRequest<WeeklyRecord> = WeeklyRecord.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \WeeklyRecord.weekStart, ascending: true)]
        return try context.fetch(request)
    }

    private func fetchLatestPredictionSnapshot(in context: NSManagedObjectContext) throws -> PredictionSnapshot? {
        let request: NSFetchRequest<PredictionSnapshot> = PredictionSnapshot.fetchRequest()
        request.fetchLimit = 1
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PredictionSnapshot.createdAt, ascending: false)]
        return try context.fetch(request).first
    }

    private func modeLabel(for result: PredictionRunResult, sourceMode: String?) -> String {
        switch result {
        case .warmup:
            return "warmup"
        case .ready:
            return sourceMode == "blended" ? "blended" : "rf-only"
        }
    }

    private func probabilitiesArray(from dictionary: [Int: Double]) -> [Double] {
        (0...3).map { dictionary[$0] ?? 0.0 }
    }

    private func brierScore(probabilities: [Double], trueClass: Int) -> Double {
        probabilities.enumerated().reduce(0.0) { total, element in
            let expected = element.offset == trueClass ? 1.0 : 0.0
            return total + pow(element.element - expected, 2.0)
        }
    }

    private func logLoss(probabilities: [Double], trueClass: Int) -> Double {
        let clipped = min(max(probabilities[trueClass], 0.000001), 0.999999)
        return -log(clipped)
    }

    private func snapshotLooksPersonalized(_ snapshot: CalibrationStateSnapshot) -> Bool {
        let identity = SoftmaxCalibrator.identity()
        let weightsMatchIdentity = zip(snapshot.weights, identity.weights).allSatisfy { lhs, rhs in
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) < 0.0000001 }
        }
        let biasMatchesIdentity = zip(snapshot.bias, identity.bias).allSatisfy { abs($0 - $1) < 0.0000001 }
        return !(weightsMatchIdentity && biasMatchesIdentity)
    }

    private func assert(_ condition: @autoclosure () -> Bool, _ message: String, report: inout CalibrationSmokeReport) throws {
        guard condition() else {
            report.failureReason = message
            throw SmokeHarnessError.expectationFailed(message)
        }
    }

    private func runRealCoreMLInformationalReplay(contracts: AppContractStore) throws -> [CoreMLInfoRow] {
        let service = try PredictionService(contracts: contracts)
        return try informationalReferenceCases().map { sample in
            let startedAt = CFAbsoluteTimeGetCurrent()
            let computation = try service.predict(featureVector: sample.features)
            let latencyMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0
            return CoreMLInfoRow(
                expectedClass: sample.expectedClass,
                predictedClass: computation.predictedClass,
                probabilities: probabilitiesArray(from: computation.probabilities),
                sumProbs: computation.diagnostics.sumProbs,
                latencyMs: latencyMs
            )
        }
    }

    private func informationalReferenceCases() -> [InformationalReferenceCase] {
        [
            InformationalReferenceCase(
                expectedClass: 1,
                features: [
                    "bucket_spend_t": 3.0,
                    "bucket_net_t": 3.0,
                    "weekly_inflow_t": 23752.0,
                    "weekly_outflow_t": 17084.0,
                    "weekly_net_t": 6668.0,
                    "txn_count_t": 3.0,
                    "category_diversity_t": 3.0,
                    "weekly_inflow_t_minus_1": 162.9,
                    "weekly_outflow_t_minus_1": 714.6,
                    "weekly_net_t_minus_1": -551.7,
                    "weekly_inflow_t_minus_2": 0.0,
                    "weekly_outflow_t_minus_2": 1300.0,
                    "outflow_inflow_ratio_t": 0.719266,
                    "week_of_year": 50.0,
                    "month": 12.0,
                    "quarter": 4.0,
                    "week_of_month": 1.0,
                    "is_month_start_week": 1.0,
                    "is_month_end_week": 0.0,
                    "delta_inflow": 23589.1,
                    "delta_outflow": 16369.4,
                    "inflow_outflow_ratio": 1.390307,
                    "inflow_share": 0.581644,
                    "inflow_rolling_mean_8w": 6000.4,
                    "inflow_rolling_std_8w": 8144.11376,
                    "outflow_rolling_mean_8w": 5986.975,
                    "outflow_rolling_std_8w": 7042.18199,
                    "inflow_frequency_8w": 0.75,
                    "outflow_frequency_8w": 0.875,
                    "weeks_since_inflow": 2.0,
                    "weeks_since_outflow": 1.0
                ]
            ),
            InformationalReferenceCase(
                expectedClass: 1,
                features: [
                    "bucket_spend_t": 1.0,
                    "bucket_net_t": 2.0,
                    "weekly_inflow_t": 52.8,
                    "weekly_outflow_t": 14.6,
                    "weekly_net_t": 38.2,
                    "txn_count_t": 2.0,
                    "category_diversity_t": 2.0,
                    "weekly_inflow_t_minus_1": 94.9,
                    "weekly_outflow_t_minus_1": 0.0,
                    "weekly_net_t_minus_1": 94.9,
                    "weekly_inflow_t_minus_2": 549.0,
                    "weekly_outflow_t_minus_2": 0.0,
                    "outflow_inflow_ratio_t": 0.276515,
                    "week_of_year": 38.0,
                    "month": 9.0,
                    "quarter": 3.0,
                    "week_of_month": 4.0,
                    "is_month_start_week": 0.0,
                    "is_month_end_week": 1.0,
                    "delta_inflow": -42.1,
                    "delta_outflow": 14.6,
                    "inflow_outflow_ratio": 3.616191,
                    "inflow_share": 0.783383,
                    "inflow_rolling_mean_8w": 663.0125,
                    "inflow_rolling_std_8w": 786.406948,
                    "outflow_rolling_mean_8w": 108.625,
                    "outflow_rolling_std_8w": 262.602244,
                    "inflow_frequency_8w": 0.875,
                    "outflow_frequency_8w": 0.25,
                    "weeks_since_inflow": 1.0,
                    "weeks_since_outflow": 7.0
                ]
            ),
            InformationalReferenceCase(
                expectedClass: 2,
                features: [
                    "bucket_spend_t": 2.0,
                    "bucket_net_t": 1.0,
                    "weekly_inflow_t": 1064.8,
                    "weekly_outflow_t": 3351.6,
                    "weekly_net_t": -2286.8,
                    "txn_count_t": 7.0,
                    "category_diversity_t": 4.0,
                    "weekly_inflow_t_minus_1": 359.1,
                    "weekly_outflow_t_minus_1": 2858.1,
                    "weekly_net_t_minus_1": -2499.0,
                    "weekly_inflow_t_minus_2": 417.9,
                    "weekly_outflow_t_minus_2": 2701.0,
                    "outflow_inflow_ratio_t": 3.147693,
                    "week_of_year": 39.0,
                    "month": 9.0,
                    "quarter": 3.0,
                    "week_of_month": 5.0,
                    "is_month_start_week": 0.0,
                    "is_month_end_week": 1.0,
                    "delta_inflow": 705.7,
                    "delta_outflow": 493.5,
                    "inflow_outflow_ratio": 0.317703,
                    "inflow_share": 0.241103,
                    "inflow_rolling_mean_8w": 380.225,
                    "inflow_rolling_std_8w": 242.54653,
                    "outflow_rolling_mean_8w": 2083.8125,
                    "outflow_rolling_std_8w": 1302.901484,
                    "inflow_frequency_8w": 1.0,
                    "outflow_frequency_8w": 0.875,
                    "weeks_since_inflow": 1.0,
                    "weeks_since_outflow": 1.0
                ]
            )
        ]
    }
}

private struct ReplayWeek {
    let weekIndex: Int
    let weekStart: Date
    let weekOfYear: Int
    let inflow: Double
    let referenceOutflow: Double
    let actualOutflow: Double
    let txnCount: Double
    let categoryDiversity: Double
    let baseProbabilities: [Double]
}

private struct ReplayReportRow {
    let weekIndex: Int
    let referenceOutflow: Double
    let actualOutflow: Double
    let derivedBucket: Int
    let labelBuffered: Bool
    let mode: String
    let updateCount: Int
}

private struct EvaluationSummary {
    let baselineProbabilities: [Double]
    let finalProbabilities: [Double]
    let deltaTrueClassProbability: Double
    let baseBrier: Double
    let finalBrier: Double
    let baseLogLoss: Double
    let finalLogLoss: Double
}

private struct CoreMLInfoRow {
    let expectedClass: Int
    let predictedClass: Int
    let probabilities: [Double]
    let sumProbs: Double
    let latencyMs: Double
}

private struct InformationalReferenceCase {
    let expectedClass: Int
    let features: [String: Double]
}

private struct HarnessOutcome {
    var status = "FAIL"
    var report: CalibrationSmokeReport
}

private struct CalibrationSmokeReport {
    let warmupWeeks: Int
    let cadence: Int
    let alpha: Double
    let storePath: String
    var rows: [ReplayReportRow] = []
    var roundTrip = "Not executed"
    var evaluation: EvaluationSummary?
    var coreMLRows: [CoreMLInfoRow] = []
    var failureReason: String?

    func render(status: String) -> String {
        var lines: [String] = []
        lines.append("Stage 3 Calibration Smoke Harness")
        lines.append("config: warmup=\(warmupWeeks), cadence=\(cadence), alpha=\(format(alpha))")
        lines.append("temp_store: \(storePath)")
        lines.append("")
        lines.append("Replay weeks")
        lines.append("weekIndex | referenceOutflow | actualOutflow | derivedBucket | labelBuffered | mode | updateCount")
        lines.append(String(repeating: "-", count: 96))
        for row in rows {
            lines.append(
                "\(row.weekIndex) | \(format(row.referenceOutflow)) | \(format(row.actualOutflow)) | \(row.derivedBucket) | \(row.labelBuffered ? "yes" : "no") | \(row.mode) | \(row.updateCount)"
            )
        }
        lines.append("")
        lines.append("Persistence round-trip")
        lines.append(roundTrip)
        lines.append("")
        lines.append("Evaluation summary")
        if let evaluation {
            lines.append("pRF: \(formatProbabilities(evaluation.baselineProbabilities))")
            lines.append("pFinal: \(formatProbabilities(evaluation.finalProbabilities))")
            lines.append("delta true-class prob: \(format(evaluation.deltaTrueClassProbability))")
            lines.append("Brier before/after: \(format(evaluation.baseBrier)) -> \(format(evaluation.finalBrier))")
            lines.append("Log-loss before/after: \(format(evaluation.baseLogLoss)) -> \(format(evaluation.finalLogLoss))")
        } else {
            lines.append("Missing evaluation summary.")
        }
        lines.append("")
        lines.append("Real CoreML informational replay")
        if coreMLRows.isEmpty {
            lines.append("Skipped.")
        } else {
            for (index, row) in coreMLRows.enumerated() {
                lines.append("case \(index): expected=\(row.expectedClass) predicted=\(row.predictedClass) sumProbs=\(format(row.sumProbs)) latencyMs=\(format(row.latencyMs)) probs=\(formatProbabilities(row.probabilities))")
            }
        }
        lines.append("")
        if let failureReason {
            lines.append("Failure: \(failureReason)")
        }
        lines.append(status)
        return lines.joined(separator: "\n")
    }
}

private enum SmokeHarnessError: LocalizedError {
    case expectationFailed(String)
    case missingReadyPrediction(String)

    var errorDescription: String? {
        switch self {
        case let .expectationFailed(message), let .missingReadyPrediction(message):
            return message
        }
    }
}

private struct ReplayPredictor: ModelPredicting {
    let probabilitiesByWeekOfYear: [Int: [Double]]
    private let voteTotal = 420.0

    func predict(featureProvider: MLFeatureProvider) throws -> MLFeatureProvider {
        guard
            let featureValue = featureProvider.featureValue(for: "week_of_year"),
            featureValue.type == .double
        else {
            throw SmokeHarnessError.expectationFailed("Replay predictor requires week_of_year in the feature vector.")
        }

        let weekOfYear = Int(featureValue.doubleValue.rounded())
        guard let probabilities = probabilitiesByWeekOfYear[weekOfYear] else {
            throw SmokeHarnessError.expectationFailed("Missing replay probabilities for ISO week \(weekOfYear).")
        }

        guard let predictedClass = probabilities.enumerated().max(by: { $0.element < $1.element })?.offset else {
            throw SmokeHarnessError.expectationFailed("Replay probabilities must not be empty.")
        }

        let votes = Dictionary(uniqueKeysWithValues: probabilities.enumerated().map { index, probability in
            (String(index), NSNumber(value: probability * voteTotal))
        })

        return try MLDictionaryFeatureProvider(dictionary: [
            "classLabel": "\(predictedClass)",
            "classProbability": votes
        ])
    }
}

private func format(_ value: Double) -> String {
    String(format: "%.4f", value)
}

private func formatProbabilities(_ probabilities: [Double]) -> String {
    probabilities.map(format).joined(separator: " | ")
}

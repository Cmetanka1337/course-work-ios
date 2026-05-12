import CoreData
import CoreML
import XCTest
@testable import course_work_ios

@MainActor
final class course_work_iosTests: XCTestCase {
    func testContractsBundleLoadsFrozenStageInputs() throws {
        let contracts = AppContractStore()

        XCTAssertEqual(contracts.thresholds.q25Spend, 14.6, accuracy: 0.0001)
        XCTAssertEqual(contracts.thresholds.q75Spend, 7028.0, accuracy: 0.0001)
        XCTAssertEqual(contracts.thresholds.q25Net, -4100.0, accuracy: 0.0001)
        XCTAssertEqual(contracts.thresholds.q75Net, 3401.0, accuracy: 0.0001)
        XCTAssertEqual(contracts.featureContract.featureOrder.count, 31)
        XCTAssertEqual(contracts.featureContract.guardrails.warmupWeeks, 8)
        XCTAssertEqual(contracts.featureContract.guardrails.alphaAfterWarmup, 0.2, accuracy: 0.0001)
        XCTAssertEqual(contracts.releaseManifest.selectedPrefix, "full_spend_tuned")
        XCTAssertTrue(contracts.isComplete)
    }

    func testFeatureBuilderBuildsFiniteContractOrderedVector() throws {
        let contracts = AppContractStore()
        let builder = FeatureBuilder(contract: contracts.featureContract, thresholds: contracts.thresholds)

        let features = try builder.buildFeatureVector(from: makeFeatureHistory(weeks: 10))

        XCTAssertEqual(features.count, contracts.featureContract.featureOrder.count)
        XCTAssertEqual(Set(features.keys), Set(contracts.featureContract.featureOrder))
        XCTAssertTrue(features.values.allSatisfy(\.isFinite))
        XCTAssertEqual(featureValue(features, key: "week_of_year"), 11.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "weekly_inflow_t_minus_1"), 2400.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "weekly_outflow_t_minus_1"), 720.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "inflow_frequency_8w"), 0.75, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "outflow_frequency_8w"), 1.0, accuracy: 0.0001)
    }

    func testPredictionServiceReturnsWarmupBeforeMinimumHistory() throws {
        let contracts = AppContractStore()
        let service = PredictionService(
            contract: contracts.featureContract,
            thresholds: contracts.thresholds,
            predictor: StubPredictor(output: stubPredictionOutput(classLabel: "0", votes: ["0": 420.0]))
        )

        let result = try service.runPrediction(for: makeFeatureHistory(weeks: 7))

        guard case let .warmup(state) = result else {
            return XCTFail("Expected warm-up state")
        }
        XCTAssertEqual(state.completedWeeks, 7)
        XCTAssertEqual(state.requiredWeeks, 8)
    }

    func testPredictionServiceNormalizesVotesIntoProbabilitiesAndConfidence() throws {
        let contracts = AppContractStore()
        let service = PredictionService(
            contract: contracts.featureContract,
            thresholds: contracts.thresholds,
            predictor: StubPredictor(output: stubPredictionOutput(classLabel: "1", votes: sampleVotes))
        )

        let result = try service.runPrediction(for: makeFeatureHistory(weeks: 10))

        guard case let .ready(computation) = result else {
            return XCTFail("Expected ready prediction")
        }
        XCTAssertEqual(computation.predictedClass, 1)
        XCTAssertEqual(computation.confidence, 0.37576000268266835, accuracy: 0.0000001)
        XCTAssertEqual(computation.diagnostics.sumVotes, 420.0, accuracy: 0.0001)
        XCTAssertEqual(computation.diagnostics.sumProbs, 1.0, accuracy: 0.0000001)
        XCTAssertTrue(computation.diagnostics.classLabelMatchesArgmax)
        XCTAssertTrue(computation.isLowConfidence)
    }

    func testPredictionServiceFlagsModelClassMismatchInDiagnostics() throws {
        let contracts = AppContractStore()
        let service = PredictionService(
            contract: contracts.featureContract,
            thresholds: contracts.thresholds,
            predictor: StubPredictor(output: stubPredictionOutput(
                classLabel: "0",
                votes: ["0": 10.0, "1": 20.0, "2": 30.0, "3": 360.0]
            ))
        )

        let computation = try service.predict(featureVector: goldenPredictionCases[0].features)

        XCTAssertEqual(computation.predictedClass, 3)
        XCTAssertFalse(computation.diagnostics.classLabelMatchesArgmax)
        XCTAssertEqual(computation.diagnostics.classLabelFromModel, 0)
        XCTAssertEqual(computation.diagnostics.argmaxClass, 3)
    }

    func testPredictionServiceMatchesRepresentativeGoldenCases() throws {
        let contracts = AppContractStore()

        for sample in goldenPredictionCases {
            let service = PredictionService(
                contract: contracts.featureContract,
                thresholds: contracts.thresholds,
                predictor: StubPredictor(output: stubPredictionOutput(
                    classLabel: "\(sample.expectedClass)",
                    votes: sample.expectedVotes
                ))
            )

            let computation = try service.predict(featureVector: sample.features)

            XCTAssertEqual(computation.predictedClass, sample.expectedClass)
            XCTAssertEqual(computation.diagnostics.sumVotes, sample.expectedSumVotes, accuracy: 0.000001)
            XCTAssertEqual(computation.diagnostics.sumProbs, 1.0, accuracy: 0.000001)

            for classID in 0...3 {
                XCTAssertEqual(
                    computation.probabilities[classID] ?? -1,
                    sample.expectedProbs[classID],
                    accuracy: 0.000001
                )
            }
        }
    }

    func testPredictionSnapshotPersistenceStoresNormalizedDiagnostics() throws {
        let contracts = AppContractStore()
        let service = PredictionService(
            contract: contracts.featureContract,
            thresholds: contracts.thresholds,
            predictor: StubPredictor(output: stubPredictionOutput(classLabel: "1", votes: sampleVotes))
        )
        let context = PersistenceController(inMemory: true).container.viewContext
        let records = makeWeeklyRecords(in: context, weeks: 10)

        let result = try service.upsertPredictionSnapshot(for: records, in: context)

        guard case let .ready(computation) = result else {
            return XCTFail("Expected ready prediction")
        }

        let request: NSFetchRequest<PredictionSnapshot> = PredictionSnapshot.fetchRequest()
        let snapshots = try context.fetch(request)
        XCTAssertEqual(snapshots.count, 1)

        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshot.predictedClass?.intValue, computation.predictedClass)
        XCTAssertEqual(snapshot.sumVotes?.doubleValue ?? -1, 420.0, accuracy: 0.000001)
        XCTAssertEqual(snapshot.sumProbs?.doubleValue ?? -1, 1.0, accuracy: 0.000001)
        XCTAssertEqual(snapshot.sourceMode, "rf")
        XCTAssertTrue((snapshot.notes ?? "").contains("sumVotes=420.0"))
        XCTAssertNotNil(snapshot.featureVectorData)
    }

    func testSpendBucketizationUsesFrozenThresholds() {
        let thresholds = AppContractStore().thresholds

        XCTAssertEqual(PersonalizationService.spendBucket(for: 0.0, thresholds: thresholds), 0)
        XCTAssertEqual(PersonalizationService.spendBucket(for: 14.6, thresholds: thresholds), 1)
        XCTAssertEqual(PersonalizationService.spendBucket(for: 14.61, thresholds: thresholds), 2)
        XCTAssertEqual(PersonalizationService.spendBucket(for: 7028.0, thresholds: thresholds), 2)
        XCTAssertEqual(PersonalizationService.spendBucket(for: 7028.01, thresholds: thresholds), 3)
    }

    func testSoftmaxCalibratorTrainingMovesAwayFromIdentity() {
        var calibrator = SoftmaxCalibrator.identity()
        let config = CalibrationConfig(
            warmupWeeks: 1,
            updateEveryWeeks: 1,
            historyCap: 20,
            learningRate: 0.05,
            l2: 0.0,
            gradClip: 5.0,
            alpha: 0.2,
            epochs: 1,
            confidenceThreshold: 0.5
        )
        let sample = CalibrationSample(
            weekIndex: 0,
            pRF: [1.0, 0.0, 0.0, 0.0],
            yTrue: 0,
            actualOutflow: 0.0
        )

        calibrator.train(samples: [sample], config: config)

        XCTAssertNotEqual(calibrator.weights[0][0], 1.0, accuracy: 0.000000001)
        XCTAssertNotEqual(calibrator.bias[0], 0.0, accuracy: 0.000000001)
    }

    func testSoftmaxCalibratorImprovesHeldOutBrierScoreAndLogLoss() {
        var calibrator = SoftmaxCalibrator.identity()
        let config = CalibrationConfig(
            warmupWeeks: 8,
            updateEveryWeeks: 2,
            historyCap: 20,
            learningRate: 0.05,
            l2: 0.0,
            gradClip: 5.0,
            alpha: 0.2,
            epochs: 20,
            confidenceThreshold: 0.5
        )
        let trainingSamples = makeDeterministicCalibrationSamples()
        let heldOutPRF = [0.12, 0.50, 0.18, 0.20]
        let heldOutLabel = 3

        let baseBrier = brierScore(probabilities: heldOutPRF, trueClass: heldOutLabel)
        let baseLogLoss = logLoss(probabilities: heldOutPRF, trueClass: heldOutLabel)

        calibrator.train(samples: trainingSamples, config: config)

        let calibrated = calibrator.predict(heldOutPRF)
        let blended = zip(heldOutPRF, calibrated).map { (1.0 - config.alpha) * $0 + config.alpha * $1 }
        let blendedBrier = brierScore(probabilities: blended, trueClass: heldOutLabel)
        let blendedLogLoss = logLoss(probabilities: blended, trueClass: heldOutLabel)

        XCTAssertEqual(calibrated.reduce(0.0, +), 1.0, accuracy: 0.000001)
        XCTAssertEqual(blended.reduce(0.0, +), 1.0, accuracy: 0.000001)
        XCTAssertGreaterThan(blended[heldOutLabel], heldOutPRF[heldOutLabel])
        XCTAssertLessThan(blendedBrier, baseBrier)
        XCTAssertLessThan(blendedLogLoss, baseLogLoss)
    }

    func testCoreMLSmokeUsesRealModelOnlyWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["RUN_COREML_SMOKE"] == "1" else {
            throw XCTSkip("Set RUN_COREML_SMOKE=1 to run the real-model smoke test.")
        }

        let contracts = AppContractStore()
        let service = try PredictionService(contracts: contracts)
        let computation = try service.predict(featureVector: goldenPredictionCases[0].features)

        XCTAssertEqual(computation.diagnostics.sumProbs, 1.0, accuracy: 0.000001)
        XCTAssertTrue((0...3).contains(computation.predictedClass))
    }

    func testCalibrationBufferPersistsAcrossStoreReload() throws {
        let contracts = AppContractStore()
        let storeURL = temporaryStoreURL()
        defer { removeStoreFiles(at: storeURL) }

        let predictor = StubPredictor(output: stubPredictionOutput(classLabel: "1", votes: sampleVotes))
        let firstController = PersistenceController(storeURL: storeURL)
        let firstContext = firstController.container.viewContext
        let service = try PersonalizationService(contracts: contracts, predictor: predictor)
        let records = makeWeeklyRecords(in: firstContext, weeks: 10)

        _ = try service.fetchCalibrationStatus(in: firstContext)
        let state = try XCTUnwrap(fetchCalibrationState(in: firstContext))
        state.warmupWeeks = 1
        state.updateEveryWeeks = 99
        state.historyCap = 20
        state.epochs = 1
        try firstContext.save()

        let latest = try XCTUnwrap(records.max(by: { ($0.weekStart ?? .distantPast) < ($1.weekStart ?? .distantPast) }))
        let closeResult = try service.closeWeek(latest, actualOutflow: 500.0, history: records, in: firstContext)
        XCTAssertEqual(closeResult, .updatedAndQueuedForCalibration)

        let firstSnapshot = try service.fetchCalibrationSnapshot(in: firstContext)
        XCTAssertEqual(firstSnapshot.samples.count, 1)
        XCTAssertEqual(firstSnapshot.samples[0].actualOutflow, 500.0, accuracy: 0.0000001)
        XCTAssertEqual(firstSnapshot.samples[0].yTrue, 2)

        let secondController = PersistenceController(storeURL: storeURL)
        let secondContext = secondController.container.viewContext
        let reloadedService = try PersonalizationService(contracts: contracts, predictor: predictor)
        let secondSnapshot = try reloadedService.fetchCalibrationSnapshot(in: secondContext)

        XCTAssertEqual(secondSnapshot.samples, firstSnapshot.samples)
        XCTAssertEqual(secondSnapshot.config.historyCap, 20)
    }

    func testManualRetrainActivatesCalibrationAfterWarmup() throws {
        let contracts = AppContractStore()
        let context = PersistenceController(inMemory: true).container.viewContext
        let service = try PersonalizationService(
            contracts: contracts,
            predictor: StubPredictor(output: stubPredictionOutput(classLabel: "1", votes: sampleVotes))
        )
        let records = makeWeeklyRecords(in: context, weeks: 10)

        _ = try service.fetchCalibrationStatus(in: context)
        let state = try XCTUnwrap(fetchCalibrationState(in: context))
        state.warmupWeeks = 1
        state.updateEveryWeeks = 99
        state.historyCap = 20
        state.epochs = 1
        try context.save()

        let latest = try XCTUnwrap(records.max(by: { ($0.weekStart ?? .distantPast) < ($1.weekStart ?? .distantPast) }))
        _ = try service.closeWeek(latest, actualOutflow: 600.0, history: records, in: context)

        XCTAssertTrue(try service.retrainNow(in: context))

        let status = try service.fetchCalibrationStatus(in: context)
        XCTAssertTrue(status.isActive)
        XCTAssertEqual(status.updateCount, 1)
        XCTAssertEqual(status.labeledWeeks, 1)
    }

    private func stubPredictionOutput(classLabel: String, votes: [String: Double]) -> [String: Any] {
        [
            "classLabel": classLabel,
            "classProbability": votes.mapValues { NSNumber(value: $0) }
        ]
    }

    private func fetchCalibrationState(in context: NSManagedObjectContext) throws -> CalibrationStateRecord? {
        let request: NSFetchRequest<CalibrationStateRecord> = CalibrationStateRecord.fetchRequest()
        request.fetchLimit = 1
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CalibrationStateRecord.createdAt, ascending: true)]
        return try context.fetch(request).first
    }

    private func featureValue(
        _ features: [String: Double],
        key: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Double {
        guard let value = features[key] else {
            XCTFail("Missing feature value for \(key)", file: file, line: line)
            return .nan
        }
        return value
    }

    private func makeFeatureHistory(weeks: Int) -> [WeeklyFeatureInput] {
        let start = mondayDate(year: 2026, month: 1, day: 5)
        let inflows: [Double] = [1200, 800, 0, 900, 2100, 1800, 0, 1500, 2400, 3000]
        let outflows: [Double] = [500, 650, 710, 720, 800, 760, 740, 730, 720, 690]

        return (0..<weeks).map { index in
            let date = Calendar(identifier: .gregorian).date(byAdding: .weekOfYear, value: index, to: start) ?? start
            return WeeklyFeatureInput(
                weekStart: date,
                weekIndex: index,
                inflow: inflows[index],
                outflow: outflows[index],
                txnCount: Double(2 + (index % 4)),
                categoryDiversity: Double(1 + (index % 3))
            )
        }
    }

    private func makeWeeklyRecords(in context: NSManagedObjectContext, weeks: Int) -> [WeeklyRecord] {
        makeFeatureHistory(weeks: weeks).map { item in
            let record = WeeklyRecord(context: context)
            record.id = UUID()
            record.weekStart = item.weekStart
            record.weekIndex = NSNumber(value: item.weekIndex)
            record.inflow = NSNumber(value: item.inflow)
            record.outflow = NSNumber(value: item.outflow)
            record.net = NSNumber(value: item.net)
            record.txnCount = NSNumber(value: item.txnCount)
            record.categoryDiversity = NSNumber(value: item.categoryDiversity)
            record.modelSpendBucket = 0
            record.modelNetBucket = 0
            record.actualSpendAmount = 0
            record.actualSpendBucket = 0
            record.hasActualOutcome = false
            record.createdAt = item.weekStart
            record.updatedAt = item.weekStart
            return record
        }
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
    }

    private func removeStoreFiles(at storeURL: URL) {
        let urls = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-shm"),
            URL(fileURLWithPath: storeURL.path + "-wal")
        ]

        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func mondayDate(year: Int, month: Int, day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    private func makeDeterministicCalibrationSamples() -> [CalibrationSample] {
        let referencePRFs: [[Double]] = [
            [0.10, 0.56, 0.18, 0.16],
            [0.11, 0.54, 0.19, 0.16],
            [0.09, 0.57, 0.18, 0.16],
            [0.12, 0.53, 0.19, 0.16],
            [0.11, 0.52, 0.19, 0.18],
            [0.10, 0.51, 0.20, 0.19],
            [0.12, 0.50, 0.19, 0.19],
            [0.13, 0.49, 0.18, 0.20]
        ]

        return referencePRFs.enumerated().map { index, pRF in
            CalibrationSample(
                weekIndex: index,
                pRF: pRF,
                yTrue: 3,
                actualOutflow: 9000.0 + Double(index)
            )
        }
    }

    private func brierScore(probabilities: [Double], trueClass: Int) -> Double {
        probabilities.enumerated().reduce(0.0) { total, item in
            let expected = item.offset == trueClass ? 1.0 : 0.0
            return total + pow(item.element - expected, 2.0)
        }
    }

    private func logLoss(probabilities: [Double], trueClass: Int) -> Double {
        let clipped = min(max(probabilities[trueClass], 0.000001), 0.999999)
        return -log(clipped)
    }
}

private struct StubPredictor: ModelPredicting {
    let output: [String: Any]

    func predict(featureProvider _: MLFeatureProvider) throws -> MLFeatureProvider {
        try MLDictionaryFeatureProvider(dictionary: output)
    }
}

private struct GoldenPredictionCase {
    let features: [String: Double]
    let expectedVotes: [String: Double]
    let expectedSumVotes: Double
    let expectedProbs: [Double]
    let expectedClass: Int
}

private let sampleVotes: [String: Double] = [
    "0": 20.088006,
    "1": 157.819201,
    "2": 152.624247,
    "3": 89.468546
]

private let goldenPredictionCases: [GoldenPredictionCase] = [
    GoldenPredictionCase(
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
        ],
        expectedVotes: ["0": 20.088006, "1": 157.819201, "2": 152.624247, "3": 89.468546],
        expectedSumVotes: 420.0,
        expectedProbs: [0.047829, 0.375760, 0.363391, 0.213020],
        expectedClass: 1
    ),
    GoldenPredictionCase(
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
        ],
        expectedVotes: ["0": 123.62797, "1": 174.32566, "2": 118.87694, "3": 3.1694286],
        expectedSumVotes: 420.0,
        expectedProbs: [0.294352, 0.415061, 0.283040, 0.007546],
        expectedClass: 1
    ),
    GoldenPredictionCase(
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
        ],
        expectedVotes: ["0": 25.913305, "1": 137.0748, "2": 229.1454, "3": 27.866463],
        expectedSumVotes: 420.0,
        expectedProbs: [0.061698, 0.326369, 0.545584, 0.066349],
        expectedClass: 2
    )
]


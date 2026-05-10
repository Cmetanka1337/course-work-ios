import XCTest
import CoreData
import CoreML
@testable import course_work_ios

final class course_work_iosTests: XCTestCase {
    func testContractBundleLoadsExpectedThresholds() throws {
        let contracts = AppContractStore()

        XCTAssertEqual(contracts.thresholds.q25Spend, 14.6, accuracy: 0.0001)
        XCTAssertEqual(contracts.thresholds.q75Spend, 7028.0, accuracy: 0.0001)
        XCTAssertEqual(contracts.thresholds.q25Net, -4100.0, accuracy: 0.0001)
        XCTAssertEqual(contracts.thresholds.q75Net, 3401.0, accuracy: 0.0001)
        XCTAssertEqual(contracts.thresholds.eps, 0.000001, accuracy: 0.0000001)
        XCTAssertEqual(contracts.thresholds.weeksSinceCap, 52)
        XCTAssertEqual(contracts.thresholds.ratioClipMax, 10.0, accuracy: 0.0001)
        XCTAssertEqual(contracts.featureContract.featureOrder.count, 31)
        XCTAssertEqual(contracts.featureContract.guardrails.warmupWeeks, 8)
        XCTAssertEqual(contracts.featureContract.guardrails.alphaAfterWarmup, 0.2, accuracy: 0.0001)
        XCTAssertTrue(contracts.modelResourceExists)
        XCTAssertTrue(contracts.featurePassportExists)
        XCTAssertTrue(contracts.releaseManifestExists)
        XCTAssertTrue(contracts.goldenInferenceSetExists)
        XCTAssertEqual(contracts.goldenInferenceSetRecordCount, 3)
        XCTAssertTrue(contracts.isComplete)
    }

    func testReleaseManifestCarriesSelectedModelProvenance() throws {
        let contracts = AppContractStore()

        XCTAssertEqual(contracts.releaseManifest.selectedPrefix, "full_spend_tuned")
        XCTAssertEqual(contracts.releaseManifest.target, "bucket_spend_t_plus_1")
        XCTAssertEqual(contracts.releaseManifest.featureCount, 31)
        XCTAssertEqual(contracts.releaseManifest.metrics.rfBalancedAccuracy, 0.5664228464678376, accuracy: 0.0000001)
    }

    func testPreviewPersistenceSeedsDomainEntities() throws {
        let context = PersistenceController.preview.container.viewContext

        XCTAssertEqual(try count(entity: "WeeklyRecord", context: context), 2)
        XCTAssertEqual(try count(entity: "PredictionSnapshot", context: context), 1)
        XCTAssertEqual(try count(entity: "CalibrationStateRecord", context: context), 1)
    }

    func testFeatureBuilderProducesContractCompleteAndFiniteVector() throws {
        let contracts = AppContractStore()
        let builder = FeatureBuilder(contract: contracts.featureContract, thresholds: contracts.thresholds)
        let history = makeFeatureHistory(weeks: 10)

        let features = try builder.buildFeatureVector(from: history)

        XCTAssertEqual(features.count, contracts.featureContract.featureOrder.count)
        XCTAssertEqual(Set(features.keys), Set(contracts.featureContract.featureOrder))
        XCTAssertTrue(features.values.allSatisfy(\.isFinite))
        XCTAssertEqual(featureValue(features, key: "week_of_year"), 11.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "month"), 3.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "quarter"), 1.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "week_of_month"), 2.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "is_month_start_week"), 0.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "is_month_end_week"), 0.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "weekly_inflow_t_minus_1"), 2400.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "weekly_outflow_t_minus_1"), 720.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "weekly_inflow_t_minus_2"), 1500.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "inflow_frequency_8w"), 0.75, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "outflow_frequency_8w"), 1.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "weeks_since_inflow"), 1.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "weeks_since_outflow"), 1.0, accuracy: 0.0001)
    }

    func testFeatureBuilderSanitizesRatioAndCapsWeeksSince() throws {
        let contracts = AppContractStore()
        let builder = FeatureBuilder(contract: contracts.featureContract, thresholds: contracts.thresholds)
        let date = mondayDate(year: 2026, month: 4, day: 6)

        let history = (0..<8).map { offset in
            WeeklyFeatureInput(
                weekStart: Calendar(identifier: .gregorian).date(byAdding: .weekOfYear, value: offset, to: date) ?? date,
                weekIndex: offset,
                inflow: 0.0,
                outflow: 150.0,
                txnCount: 1.0,
                categoryDiversity: 1.0
            )
        }

        let features = try builder.buildFeatureVector(from: history)
        XCTAssertEqual(featureValue(features, key: "outflow_inflow_ratio_t"), 0.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "inflow_outflow_ratio"), 0.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "weeks_since_inflow"), Double(contracts.thresholds.weeksSinceCap), accuracy: 0.0001)
    }

    func testFeatureBuilderRollingRequiresFullEightShiftedWeeks() throws {
        let contracts = AppContractStore()
        let builder = FeatureBuilder(contract: contracts.featureContract, thresholds: contracts.thresholds)
        let history = makeFeatureHistory(weeks: 8)

        let features = try builder.buildFeatureVector(from: history)
        XCTAssertEqual(featureValue(features, key: "inflow_rolling_mean_8w"), 0.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "inflow_rolling_std_8w"), 0.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "outflow_rolling_mean_8w"), 0.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "outflow_rolling_std_8w"), 0.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "inflow_frequency_8w"), 0.0, accuracy: 0.0001)
        XCTAssertEqual(featureValue(features, key: "outflow_frequency_8w"), 0.0, accuracy: 0.0001)
    }

    func testPredictionServiceNormalizesVotesIntoProbabilities() throws {
        let contracts = AppContractStore()
        let predictor = StubPredictor(
            output: [
                "classLabel": "1",
                "classProbability": [
                    "0": NSNumber(value: 20.088006),
                    "1": NSNumber(value: 157.819201),
                    "2": NSNumber(value: 152.624247),
                    "3": NSNumber(value: 89.468546)
                ]
            ]
        )

        let service = PredictionService(
            contract: contracts.featureContract,
            thresholds: contracts.thresholds,
            predictor: predictor
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

    func testPredictionServiceMatchesGoldenSampleCases() throws {
        let contracts = AppContractStore()

        for sample in goldenPredictionCases {
            let predictor = StubPredictor(
                output: [
                    "classLabel": "\(sample.expectedClass)",
                    "classProbability": sample.expectedVotes.mapValues { NSNumber(value: $0) }
                ]
            )

            let service = PredictionService(
                contract: contracts.featureContract,
                thresholds: contracts.thresholds,
                predictor: predictor
            )

            let computation = try service.predict(featureVector: sample.features)
            XCTAssertEqual(computation.predictedClass, sample.expectedClass)
            XCTAssertEqual(computation.diagnostics.sumVotes, sample.expectedSumVotes, accuracy: 0.000001)
            XCTAssertEqual(computation.diagnostics.sumProbs, sample.expectedSumProbs, accuracy: 0.000001)
            XCTAssertEqual(computation.diagnostics.missingFeatureCount, 0)
            XCTAssertFalse(computation.diagnostics.hasNonFiniteFeature)
            XCTAssertTrue(computation.diagnostics.classLabelMatchesArgmax)

            for classId in 0...3 {
                XCTAssertEqual(
                    computation.probabilities[classId] ?? -1,
                    sample.expectedProbs[classId],
                    accuracy: 0.000001
                )
            }
        }
    }

    func testPredictionServiceReturnsWarmupBeforeEnoughWeeks() throws {
        let contracts = AppContractStore()
        let predictor = StubPredictor(output: [
            "classLabel": "0",
            "classProbability": ["0": NSNumber(value: 420.0)]
        ])

        let service = PredictionService(
            contract: contracts.featureContract,
            thresholds: contracts.thresholds,
            predictor: predictor
        )

        let result = try service.runPrediction(for: makeFeatureHistory(weeks: 7))
        guard case let .warmup(state) = result else {
            return XCTFail("Expected warmup state")
        }

        XCTAssertEqual(state.completedWeeks, 7)
        XCTAssertEqual(state.requiredWeeks, 8)
    }

    func testPredictionServiceFlagsClassLabelArgmaxMismatchInDiagnostics() throws {
        let contracts = AppContractStore()
        let predictor = StubPredictor(output: [
            "classLabel": "0",
            "classProbability": [
                "0": NSNumber(value: 10.0),
                "1": NSNumber(value: 20.0),
                "2": NSNumber(value: 30.0),
                "3": NSNumber(value: 360.0)
            ]
        ])

        let service = PredictionService(
            contract: contracts.featureContract,
            thresholds: contracts.thresholds,
            predictor: predictor
        )

        let computation = try service.predict(featureVector: goldenPredictionCases[0].features)
        XCTAssertEqual(computation.predictedClass, 3)
        XCTAssertFalse(computation.diagnostics.classLabelMatchesArgmax)
        XCTAssertEqual(computation.diagnostics.classLabelFromModel, 0)
        XCTAssertEqual(computation.diagnostics.argmaxClass, 3)
    }

    func testPredictionServicePersistsPredictionSnapshotWithDiagnostics() throws {
        let contracts = AppContractStore()
        let predictor = StubPredictor(output: [
            "classLabel": "1",
            "classProbability": [
                "0": NSNumber(value: 20.088006),
                "1": NSNumber(value: 157.819201),
                "2": NSNumber(value: 152.624247),
                "3": NSNumber(value: 89.468546)
            ]
        ])

        let service = PredictionService(
            contract: contracts.featureContract,
            thresholds: contracts.thresholds,
            predictor: predictor
        )

        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let records = makeWeeklyRecords(in: context, weeks: 10)

        let result = try service.upsertPredictionSnapshot(for: records, in: context)
        guard case let .ready(computation) = result else {
            return XCTFail("Expected ready prediction")
        }

        let request: NSFetchRequest<PredictionSnapshot> = PredictionSnapshot.fetchRequest()
        let snapshots = try context.fetch(request)
        XCTAssertEqual(snapshots.count, 1)

        guard let snapshot = snapshots.first else {
            return XCTFail("Missing persisted snapshot")
        }

        XCTAssertEqual(snapshot.predictedClass?.intValue, computation.predictedClass)
        XCTAssertEqual(snapshot.sumVotes?.doubleValue ?? -1, 420.0, accuracy: 0.000001)
        XCTAssertEqual(snapshot.sumProbs?.doubleValue ?? -1, 1.0, accuracy: 0.000001)
        XCTAssertEqual(snapshot.confidence?.doubleValue ?? -1, computation.confidence, accuracy: 0.000001)
        XCTAssertEqual(snapshot.isLowConfidence, computation.isLowConfidence)
        XCTAssertNotNil(snapshot.featureVectorData)
        XCTAssertTrue((snapshot.notes ?? "").contains("sumVotes=420.0"))
        XCTAssertTrue((snapshot.notes ?? "").contains("sumProbs=1.0"))
    }

    func testCoreMLOnDeviceInferenceMatchesGoldenSamplesWhenModelIsAvailable() throws {
        guard let modelURL = resolveCompiledModelURL() else {
            throw XCTSkip("Compiled CoreML model not found in accessible paths for this environment.")
        }

        let model = try MLModel(contentsOf: modelURL)
        let predictor = MLModelBackedPredictor(model: model)
        let contracts = AppContractStore()
        let service = PredictionService(
            contract: contracts.featureContract,
            thresholds: contracts.thresholds,
            predictor: predictor
        )

        for sample in goldenPredictionCases {
            let computation = try service.predict(featureVector: sample.features)
            let expectedProbs = normalizedProbabilities(from: sample.expectedVotes)

            XCTAssertEqual(computation.predictedClass, sample.expectedClass)
            XCTAssertEqual(computation.diagnostics.sumVotes, 420.0, accuracy: 0.000001)
            XCTAssertEqual(computation.diagnostics.sumProbs, 1.0, accuracy: 0.000001)
            XCTAssertTrue(computation.diagnostics.classLabelMatchesArgmax)

            for classId in 0...3 {
                XCTAssertEqual(
                    computation.probabilities[classId] ?? -1,
                    expectedProbs[classId],
                    accuracy: 0.000000001
                )
            }
        }
    }

    private func count(entity: String, context: NSManagedObjectContext) throws -> Int {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
        return try context.count(for: request)
    }

    private func featureValue(
        _ features: [String: Double],
        key: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Double {
        guard let value = features[key] else {
            XCTFail("Missing feature value for key \(key)", file: file, line: line)
            return .nan
        }
        return value
    }

    private func makeFeatureHistory(weeks: Int) -> [WeeklyFeatureInput] {
        let start = mondayDate(year: 2026, month: 1, day: 5)
        let inflows: [Double] = [
            1200, 800, 0, 900, 2100, 1800, 0, 1500, 2400, 3000
        ]
        let outflows: [Double] = [
            500, 650, 710, 720, 800, 760, 740, 730, 720, 690
        ]

        return (0..<weeks).map { idx in
            let date = Calendar(identifier: .gregorian).date(byAdding: .weekOfYear, value: idx, to: start) ?? start
            return WeeklyFeatureInput(
                weekStart: date,
                weekIndex: idx,
                inflow: inflows[idx],
                outflow: outflows[idx],
                txnCount: Double(2 + (idx % 4)),
                categoryDiversity: Double(1 + (idx % 3))
            )
        }
    }

    private func makeWeeklyRecords(in context: NSManagedObjectContext, weeks: Int) -> [WeeklyRecord] {
        let history = makeFeatureHistory(weeks: weeks)
        let records = history.map { item in
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
        return records
    }

    private func normalizedProbabilities(from votes: [String: Double]) -> [Double] {
        let orderedVotes = (0...3).map { votes[String($0)] ?? 0.0 }
        let sum = orderedVotes.reduce(0.0, +)
        return orderedVotes.map { $0 / sum }
    }

    private func resolveCompiledModelURL() -> URL? {
        let candidateBundles: [Bundle] = [
            .main,
            Bundle(for: type(of: self))
        ]

        for bundle in candidateBundles {
            if let url = bundle.url(forResource: "BerkaSpendBucketRFCompiled", withExtension: "mlmodelc"),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent("BerkaSpendBucketRFCompiled.mlmodelc"),
            cwd.appendingPathComponent("course-work-ios/BerkaSpendBucketRFCompiled.mlmodelc"),
            cwd.appendingPathComponent("../BerkaSpendBucketRFCompiled.mlmodelc")
        ]

        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            if FileManager.default.fileExists(atPath: standardized.path) {
                return standardized
            }
        }

        return nil
    }

    private func mondayDate(year: Int, month: Int, day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }
}

private struct StubPredictor: ModelPredicting {
    let output: [String: Any]

    func predict(featureProvider _: MLFeatureProvider) throws -> MLFeatureProvider {
        try MLDictionaryFeatureProvider(dictionary: output)
    }
}

private struct MLModelBackedPredictor: ModelPredicting {
    let model: MLModel

    func predict(featureProvider: MLFeatureProvider) throws -> MLFeatureProvider {
        try model.prediction(from: featureProvider)
    }
}

private struct GoldenPredictionCase {
    let features: [String: Double]
    let expectedVotes: [String: Double]
    let expectedSumVotes: Double
    let expectedProbs: [Double]
    let expectedSumProbs: Double
    let expectedClass: Int
}

private let goldenPredictionCases: [GoldenPredictionCase] = [
    GoldenPredictionCase(
        features: [
            "bucket_spend_t": 3.000000,
            "bucket_net_t": 3.000000,
            "weekly_inflow_t": 23752.000000,
            "weekly_outflow_t": 17084.000000,
            "weekly_net_t": 6668.000000,
            "txn_count_t": 3.000000,
            "category_diversity_t": 3.000000,
            "weekly_inflow_t_minus_1": 162.900000,
            "weekly_outflow_t_minus_1": 714.600000,
            "weekly_net_t_minus_1": -551.700000,
            "weekly_inflow_t_minus_2": 0.000000,
            "weekly_outflow_t_minus_2": 1300.000000,
            "outflow_inflow_ratio_t": 0.719266,
            "week_of_year": 50.000000,
            "month": 12.000000,
            "quarter": 4.000000,
            "week_of_month": 1.000000,
            "is_month_start_week": 1.000000,
            "is_month_end_week": 0.000000,
            "delta_inflow": 23589.100000,
            "delta_outflow": 16369.400000,
            "inflow_outflow_ratio": 1.390307,
            "inflow_share": 0.581644,
            "inflow_rolling_mean_8w": 6000.400000,
            "inflow_rolling_std_8w": 8144.113760,
            "outflow_rolling_mean_8w": 5986.975000,
            "outflow_rolling_std_8w": 7042.181990,
            "inflow_frequency_8w": 0.750000,
            "outflow_frequency_8w": 0.875000,
            "weeks_since_inflow": 2.000000,
            "weeks_since_outflow": 1.000000
        ],
        expectedVotes: ["0": 20.088006, "1": 157.819201, "2": 152.624247, "3": 89.468546],
        expectedSumVotes: 420.000000,
        expectedProbs: [0.047829, 0.375760, 0.363391, 0.213020],
        expectedSumProbs: 1.000000,
        expectedClass: 1
    ),
    GoldenPredictionCase(
        features: [
            "bucket_spend_t": 1.000000,
            "bucket_net_t": 2.000000,
            "weekly_inflow_t": 52.800000,
            "weekly_outflow_t": 14.600000,
            "weekly_net_t": 38.200000,
            "txn_count_t": 2.000000,
            "category_diversity_t": 2.000000,
            "weekly_inflow_t_minus_1": 0.000000,
            "weekly_outflow_t_minus_1": 11816.000000,
            "weekly_net_t_minus_1": -11816.000000,
            "weekly_inflow_t_minus_2": 23122.000000,
            "weekly_outflow_t_minus_2": 11700.000000,
            "outflow_inflow_ratio_t": 0.276515,
            "week_of_year": 44.000000,
            "month": 10.000000,
            "quarter": 4.000000,
            "week_of_month": 4.000000,
            "is_month_start_week": 0.000000,
            "is_month_end_week": 0.000000,
            "delta_inflow": 52.800000,
            "delta_outflow": -11801.400000,
            "inflow_outflow_ratio": 3.616438,
            "inflow_share": 0.783383,
            "inflow_rolling_mean_8w": 8681.437500,
            "inflow_rolling_std_8w": 11967.765272,
            "outflow_rolling_mean_8w": 7934.650000,
            "outflow_rolling_std_8w": 4965.558943,
            "inflow_frequency_8w": 0.500000,
            "outflow_frequency_8w": 1.000000,
            "weeks_since_inflow": 1.000000,
            "weeks_since_outflow": 1.000000
        ],
        expectedVotes: ["0": 58.237703, "1": 3.261004, "2": 79.893069, "3": 278.608224],
        expectedSumVotes: 420.000000,
        expectedProbs: [0.138661, 0.007764, 0.190222, 0.663353],
        expectedSumProbs: 1.000000,
        expectedClass: 3
    ),
    GoldenPredictionCase(
        features: [
            "bucket_spend_t": 2.000000,
            "bucket_net_t": 2.000000,
            "weekly_inflow_t": 2966.000000,
            "weekly_outflow_t": 523.000000,
            "weekly_net_t": 2443.000000,
            "txn_count_t": 2.000000,
            "category_diversity_t": 2.000000,
            "weekly_inflow_t_minus_1": 0.000000,
            "weekly_outflow_t_minus_1": 1814.000000,
            "weekly_net_t_minus_1": -1814.000000,
            "weekly_inflow_t_minus_2": 68.500000,
            "weekly_outflow_t_minus_2": 14.600000,
            "outflow_inflow_ratio_t": 0.176332,
            "week_of_year": 46.000000,
            "month": 11.000000,
            "quarter": 4.000000,
            "week_of_month": 2.000000,
            "is_month_start_week": 0.000000,
            "is_month_end_week": 0.000000,
            "delta_inflow": 2966.000000,
            "delta_outflow": -1291.000000,
            "inflow_outflow_ratio": 5.671128,
            "inflow_share": 0.850100,
            "inflow_rolling_mean_8w": 1136.812500,
            "inflow_rolling_std_8w": 1514.954732,
            "outflow_rolling_mean_8w": 994.350000,
            "outflow_rolling_std_8w": 812.648852,
            "inflow_frequency_8w": 0.750000,
            "outflow_frequency_8w": 1.000000,
            "weeks_since_inflow": 1.000000,
            "weeks_since_outflow": 1.000000
        ],
        expectedVotes: ["0": 21.077288, "1": 286.891471, "2": 103.458292, "3": 8.572949],
        expectedSumVotes: 420.000000,
        expectedProbs: [0.050184, 0.683075, 0.246329, 0.020412],
        expectedSumProbs: 1.000000,
        expectedClass: 1
    )
]

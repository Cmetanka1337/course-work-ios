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
        XCTAssertEqual(features["week_of_year"], 11.0, accuracy: 0.0001)
        XCTAssertEqual(features["month"], 3.0, accuracy: 0.0001)
        XCTAssertEqual(features["quarter"], 1.0, accuracy: 0.0001)
        XCTAssertEqual(features["week_of_month"], 2.0, accuracy: 0.0001)
        XCTAssertEqual(features["is_month_start_week"], 0.0, accuracy: 0.0001)
        XCTAssertEqual(features["is_month_end_week"], 0.0, accuracy: 0.0001)
        XCTAssertEqual(features["weekly_inflow_t_minus_1"], 2400.0, accuracy: 0.0001)
        XCTAssertEqual(features["weekly_outflow_t_minus_1"], 720.0, accuracy: 0.0001)
        XCTAssertEqual(features["weekly_inflow_t_minus_2"], 1500.0, accuracy: 0.0001)
        XCTAssertEqual(features["inflow_frequency_8w"], 0.75, accuracy: 0.0001)
        XCTAssertEqual(features["outflow_frequency_8w"], 1.0, accuracy: 0.0001)
        XCTAssertEqual(features["weeks_since_inflow"], 1.0, accuracy: 0.0001)
        XCTAssertEqual(features["weeks_since_outflow"], 1.0, accuracy: 0.0001)
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
        XCTAssertEqual(features["outflow_inflow_ratio_t"], 0.0, accuracy: 0.0001)
        XCTAssertEqual(features["inflow_outflow_ratio"], 0.0, accuracy: 0.0001)
        XCTAssertEqual(features["weeks_since_inflow"], Double(contracts.thresholds.weeksSinceCap), accuracy: 0.0001)
    }

    func testFeatureBuilderRollingRequiresFullEightShiftedWeeks() throws {
        let contracts = AppContractStore()
        let builder = FeatureBuilder(contract: contracts.featureContract, thresholds: contracts.thresholds)
        let history = makeFeatureHistory(weeks: 8)

        let features = try builder.buildFeatureVector(from: history)
        XCTAssertEqual(features["inflow_rolling_mean_8w"], 0.0, accuracy: 0.0001)
        XCTAssertEqual(features["inflow_rolling_std_8w"], 0.0, accuracy: 0.0001)
        XCTAssertEqual(features["outflow_rolling_mean_8w"], 0.0, accuracy: 0.0001)
        XCTAssertEqual(features["outflow_rolling_std_8w"], 0.0, accuracy: 0.0001)
        XCTAssertEqual(features["inflow_frequency_8w"], 0.0, accuracy: 0.0001)
        XCTAssertEqual(features["outflow_frequency_8w"], 0.0, accuracy: 0.0001)
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

    private func count(entity: String, context: NSManagedObjectContext) throws -> Int {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
        return try context.count(for: request)
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

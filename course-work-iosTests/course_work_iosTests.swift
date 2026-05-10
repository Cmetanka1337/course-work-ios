import XCTest
import CoreData
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

    private func count(entity: String, context: NSManagedObjectContext) throws -> Int {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
        return try context.count(for: request)
    }
}

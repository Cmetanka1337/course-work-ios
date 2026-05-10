import CoreData
import Foundation

struct PersistenceController {
    static let shared = PersistenceController()

    @MainActor
    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        seedPreviewData(in: context)

        do {
            try context.save()
        } catch {
            let nsError = error as NSError
            fatalError("Unresolved preview error \(nsError), \(nsError.userInfo)")
        }

        return controller
    }()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "course_work_ios")
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("Unresolved CoreData error \(error), \(error.userInfo)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
}

private func seedPreviewData(in context: NSManagedObjectContext) {
    let calendar = Calendar(identifier: .gregorian)
    let baseDate = calendar.date(from: DateComponents(year: 2026, month: 4, day: 6)) ?? Date()

    let week1 = WeeklyRecord(context: context)
    week1.id = UUID()
    week1.weekStart = baseDate
    week1.weekIndex = 1
    week1.inflow = 23_752
    week1.outflow = 17_084
    week1.net = NSNumber(value: scalar(week1.inflow) - scalar(week1.outflow))
    week1.txnCount = 3
    week1.categoryDiversity = 3
    week1.modelSpendBucket = 3
    week1.modelNetBucket = 3
    week1.actualSpendAmount = 17_084
    week1.actualSpendBucket = 3
    week1.hasActualOutcome = true
    week1.createdAt = baseDate
    week1.updatedAt = baseDate

    let week2 = WeeklyRecord(context: context)
    week2.id = UUID()
    week2.weekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: baseDate) ?? baseDate
    week2.weekIndex = 0
    week2.inflow = 52.8
    week2.outflow = 14.6
    week2.net = NSNumber(value: scalar(week2.inflow) - scalar(week2.outflow))
    week2.txnCount = 2
    week2.categoryDiversity = 2
    week2.modelSpendBucket = 1
    week2.modelNetBucket = 2
    week2.actualSpendAmount = 14.6
    week2.actualSpendBucket = 1
    week2.hasActualOutcome = true
    week2.createdAt = calendar.date(byAdding: .weekOfYear, value: -1, to: baseDate) ?? baseDate
    week2.updatedAt = week2.createdAt

    let prediction = PredictionSnapshot(context: context)
    prediction.id = UUID()
    prediction.weekStart = baseDate
    prediction.weekIndex = 1
    prediction.createdAt = baseDate
    prediction.modelVersion = "full_spend_tuned"
    prediction.sourceMode = "rf"
    prediction.predictedClass = 1
    prediction.confidence = 0.37576
    prediction.probability0 = 0.04782858591950597
    prediction.probability1 = 0.37576000268266835
    prediction.probability2 = 0.36339106354152184
    prediction.probability3 = 0.21302034785630972
    prediction.sumVotes = 420
    prediction.sumProbs = 1
    prediction.isLowConfidence = true
    prediction.featureVectorData = makeFeatureVectorData()
    prediction.notes = "Preview seeded from golden sample case 1."

    let calibratorState = CalibrationStateRecord(context: context)
    calibratorState.id = UUID()
    calibratorState.createdAt = baseDate
    calibratorState.updatedAt = baseDate
    calibratorState.schemaVersion = "v1"
    calibratorState.warmupWeeks = 8
    calibratorState.updateEveryWeeks = 2
    calibratorState.historyCap = 20
    calibratorState.learningRate = 0.05
    calibratorState.l2 = 0.001
    calibratorState.gradClip = 5
    calibratorState.alpha = 0.2
    calibratorState.epochs = 20
    calibratorState.weeksSinceLastUpdate = 0
    calibratorState.updateCount = 0
    calibratorState.weightsData = makeCalibratorWeightsData()
    calibratorState.biasData = makeCalibratorBiasData()
    calibratorState.bufferData = Data("[]".utf8)
    calibratorState.isActive = false
    calibratorState.notes = "Warm-up only."
}

private func makeFeatureVectorData() -> Data {
    let sample: [String: Double] = [
        "bucket_spend_t": 3,
        "bucket_net_t": 3,
        "weekly_inflow_t": 23_752,
        "weekly_outflow_t": 17_084,
        "weekly_net_t": 6_668,
        "txn_count_t": 3
    ]
    return (try? JSONEncoder().encode(sample)) ?? Data()
}

private func scalar(_ value: NSNumber?) -> Double {
    value?.doubleValue ?? 0
}

private func makeCalibratorWeightsData() -> Data {
    let identity = Array(0..<4).map { row in
        Array(0..<4).map { column in row == column ? 1.0 : 0.0 }
    }
    return (try? JSONEncoder().encode(identity)) ?? Data()
}

private func makeCalibratorBiasData() -> Data {
    let zeros = Array(repeating: 0.0, count: 4)
    return (try? JSONEncoder().encode(zeros)) ?? Data()
}

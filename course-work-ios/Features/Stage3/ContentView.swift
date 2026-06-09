import CoreData
import SwiftUI

struct ContentView: View {
    let contracts: AppContractStore

    @Environment(\.managedObjectContext) private var viewContext

    @State var predictionPipelineStatus = "Awaiting history"
    @State var closeOutflowInput = ""
    @State var closeFlowStatus = "Add or seed a week, then save the real outflow when the week is over."
    @State var calibrationStatus: CalibrationStatus?
    @State var calibrationSnapshot: CalibrationStateSnapshot?
    @State var calibrationActionStatus = "RF-only until personalization warm-up finishes."
    @State var selectedSection: Stage3Section = .addWeek

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \WeeklyRecord.updatedAt, ascending: false)],
        animation: .default
    )
    var weeklyRecords: FetchedResults<WeeklyRecord>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \PredictionSnapshot.createdAt, ascending: false)],
        animation: .default
    )
    var predictionSnapshots: FetchedResults<PredictionSnapshot>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \CalibrationStateRecord.updatedAt, ascending: false)],
        animation: .default
    )
    var calibrationStates: FetchedResults<CalibrationStateRecord>

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    weeklyFlowSection
                    predictionOverviewSection
                    sectionPicker
                    activeSection
                    diagnosticsSection
                }
                .padding()
            }
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.98, green: 0.97, blue: 0.94),
                        Color(red: 0.94, green: 0.96, blue: 0.99)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle("CourseWork")
            .task(id: weeklyRecords.count) {
                guard !AppRuntime.isRunningTests else { return }
                await refreshPredictionSnapshot()
            }
        }
    }

    @MainActor
    func refreshPredictionSnapshot() async {
        do {
            let service = try PersonalizationService(contracts: contracts)
            let history = Array(weeklyRecords)
            let result = try service.evaluateAndPersistPrediction(for: history, in: viewContext)
            calibrationStatus = try service.fetchCalibrationStatus(in: viewContext)
            calibrationSnapshot = try service.fetchCalibrationSnapshot(in: viewContext)

            switch result {
            case let .warmup(state):
                predictionPipelineStatus = "Warm-up \(state.completedWeeks)/\(state.requiredWeeks)"
            case let .ready(computation):
                let mode = usesBlendedInference ? "blended" : (latestPrediction?.sourceMode ?? "rf")
                predictionPipelineStatus = computation.isLowConfidence ? "Ready (\(mode), low confidence)" : "Ready (\(mode))"
            }
        } catch {
            predictionPipelineStatus = "Pipeline error"
            calibrationActionStatus = "Calibration error"
            print("Prediction pipeline error: \(error.localizedDescription)")
        }
    }

    @MainActor
    func submitOutcome(for week: WeeklyRecord) {
        let normalized = closeOutflowInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let amount = Double(normalized), amount >= 0 else {
            closeFlowStatus = "Enter a non-negative number."
            return
        }

        do {
            let service = try PersonalizationService(contracts: contracts)
            let result = try service.closeWeek(
                week,
                actualOutflow: amount,
                history: Array(weeklyRecords),
                in: viewContext
            )

            switch result {
            case let .updatedOnlyWarmup(completedWeeks, requiredWeeks):
                closeFlowStatus = "Saved. Prediction warm-up is \(completedWeeks)/\(requiredWeeks) for that week, so ground truth is stored locally but that week is not yet a calibration sample."
            case .updatedAndQueuedForCalibration:
                closeFlowStatus = "Saved. Ground truth is stored and queued for the next calibration update."
            case .updatedAndTrained:
                closeFlowStatus = "Saved. Ground truth is stored and the calibrator retrained immediately."
            }

            closeOutflowInput = ""
            Task {
                await refreshPredictionSnapshot()
            }
        } catch {
            closeFlowStatus = "Failed to save outcome."
            print("Weekly close error: \(error.localizedDescription)")
        }
    }

    @MainActor
    func seedDemoData() {
        do {
            try resetAllData()

            let calendar = Calendar(identifier: .gregorian)
            let baseDate = calendar.date(from: DateComponents(year: 2026, month: 4, day: 6)) ?? .now
            let inflows: [Double] = [1200, 800, 0, 900, 2100, 1800, 0, 1500, 2400, 3000]
            let outflows: [Double] = [500, 650, 710, 720, 800, 760, 740, 730, 720, 690]
            let txnCounts: [Double] = [2, 3, 2, 4, 3, 5, 2, 4, 5, 4]
            let diversity: [Double] = [1, 2, 1, 2, 2, 3, 1, 2, 3, 3]

            for index in 0..<10 {
                guard let weekStart = calendar.date(byAdding: .weekOfYear, value: index, to: baseDate) else {
                    continue
                }

                let record = WeeklyRecord(context: viewContext)
                record.id = UUID()
                record.weekStart = weekStart
                record.weekIndex = NSNumber(value: index)
                record.inflow = NSNumber(value: inflows[index])
                record.outflow = NSNumber(value: outflows[index])
                record.net = NSNumber(value: inflows[index] - outflows[index])
                record.txnCount = NSNumber(value: txnCounts[index])
                record.categoryDiversity = NSNumber(value: diversity[index])
                record.modelSpendBucket = NSNumber(value: spendBucket(for: outflows[index]))
                record.modelNetBucket = 2
                record.createdAt = weekStart
                record.updatedAt = weekStart
                record.hasActualOutcome = index < 9

                if index < 9 {
                    record.actualSpendAmount = NSNumber(value: outflows[index])
                    record.actualSpendBucket = NSNumber(value: spendBucket(for: outflows[index]))
                }
            }

            try viewContext.save()
            selectedSection = .closeWeek
            closeFlowStatus = "Demo history seeded. One pending week is ready to close."
            calibrationActionStatus = "Demo history ready."
            predictionPipelineStatus = "Demo history seeded"

            Task {
                await refreshPredictionSnapshot()
            }
        } catch {
            closeFlowStatus = "Failed to seed demo data."
            print("Seed demo data error: \(error.localizedDescription)")
        }
    }

    @MainActor
    func addPendingWeek() {
        do {
            let calendar = Calendar(identifier: .gregorian)
            let latestDate = orderedWeeklyRecords.compactMap(\.weekStart).max()
                ?? calendar.date(from: DateComponents(year: 2026, month: 4, day: 6)) ?? .now
            let nextDate = calendar.date(byAdding: .weekOfYear, value: 1, to: latestDate) ?? latestDate
            let nextIndex = nextPendingWeekIndex
            let referenceInflow = orderedWeeklyRecords.first?.inflow?.doubleValue ?? 1500.0
            let referenceOutflow = orderedWeeklyRecords.first?.outflow?.doubleValue ?? 700.0

            let record = WeeklyRecord(context: viewContext)
            record.id = UUID()
            record.weekStart = nextDate
            record.weekIndex = NSNumber(value: nextIndex)
            record.inflow = NSNumber(value: referenceInflow)
            record.outflow = NSNumber(value: referenceOutflow)
            record.net = NSNumber(value: referenceInflow - referenceOutflow)
            record.txnCount = NSNumber(value: orderedWeeklyRecords.first?.txnCount?.doubleValue ?? 3.0)
            record.categoryDiversity = NSNumber(value: orderedWeeklyRecords.first?.categoryDiversity?.doubleValue ?? 2.0)
            record.modelSpendBucket = NSNumber(value: spendBucket(for: referenceOutflow))
            record.modelNetBucket = 2
            record.hasActualOutcome = false
            record.createdAt = nextDate
            record.updatedAt = nextDate
            try viewContext.save()

            selectedSection = .closeWeek
            closeFlowStatus = "Pending week added. Enter the actual outflow when you are ready to close it."
            predictionPipelineStatus = "Pending week added"

            Task {
                await refreshPredictionSnapshot()
            }
        } catch {
            closeFlowStatus = "Failed to add pending week."
            print("Add pending week error: \(error.localizedDescription)")
        }
    }

    @MainActor
    func resetAllData() throws {
        let requestTypes: [NSFetchRequest<NSFetchRequestResult>] = [
            WeeklyRecord.fetchRequest(),
            PredictionSnapshot.fetchRequest(),
            CalibrationStateRecord.fetchRequest()
        ]

        for request in requestTypes {
            let batch = NSBatchDeleteRequest(fetchRequest: request)
            batch.resultType = .resultTypeObjectIDs
            let result = try viewContext.execute(batch) as? NSBatchDeleteResult
            if let objectIDs = result?.result as? [NSManagedObjectID], !objectIDs.isEmpty {
                NSManagedObjectContext.mergeChanges(
                    fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs],
                    into: [viewContext]
                )
            }
        }

        try viewContext.save()
        selectedSection = .addWeek
        predictionPipelineStatus = "Awaiting history"
        closeFlowStatus = "Local store reset."
        calibrationActionStatus = "Calibration state cleared."
        calibrationStatus = nil
        calibrationSnapshot = nil
    }

    @MainActor
    func retrainCalibration() {
        do {
            let service = try PersonalizationService(contracts: contracts)
            let didRetrain = try service.retrainNow(in: viewContext)
            calibrationActionStatus = didRetrain ? "Manual retrain completed." : "Not enough labeled weeks yet."
            Task {
                await refreshPredictionSnapshot()
            }
        } catch {
            calibrationActionStatus = "Manual retrain failed."
            print("Calibration retrain error: \(error.localizedDescription)")
        }
    }

    @MainActor
    func resetCalibration() {
        do {
            let service = try PersonalizationService(contracts: contracts)
            try service.reset(in: viewContext)
            calibrationActionStatus = "Calibrator reset to identity."
            Task {
                await refreshPredictionSnapshot()
            }
        } catch {
            calibrationActionStatus = "Reset failed."
            print("Calibration reset error: \(error.localizedDescription)")
        }
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(contracts: AppContractStore())
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
#endif

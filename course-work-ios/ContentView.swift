import SwiftUI
import CoreData

struct ContentView: View {
    let contracts: AppContractStore

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \WeeklyRecord.updatedAt, ascending: false)],
        animation: .default
    )
    private var weeklyRecords: FetchedResults<WeeklyRecord>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \PredictionSnapshot.createdAt, ascending: false)],
        animation: .default
    )
    private var predictionSnapshots: FetchedResults<PredictionSnapshot>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \CalibrationStateRecord.updatedAt, ascending: false)],
        animation: .default
    )
    private var calibrationStates: FetchedResults<CalibrationStateRecord>

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    contractSection
                    thresholdSection
                    storageSection
                    provenanceSection
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
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stage 1 foundation")
                .font(.system(.title, design: .rounded).weight(.bold))
            Text("Contracts, bundle resources, and local persistence are frozen and ready for feature work.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var contractSection: some View {
        infoCard(title: "Model contract") {
            metricRow(label: "Features", value: "\(contracts.featureContract.featureOrder.count)")
            metricRow(label: "Warm-up", value: "\(contracts.featureContract.guardrails.warmupWeeks) weeks")
            metricRow(label: "Blended alpha", value: formatPercent(contracts.featureContract.guardrails.alphaAfterWarmup))
            metricRow(label: "Confidence threshold", value: "0.50")
            metricRow(label: "Label map", value: contracts.featureContract.labelMapping.values.sorted().joined(separator: ", "))
        }
    }

    private var thresholdSection: some View {
        infoCard(title: "Frozen thresholds") {
            metricRow(label: "Spend q25 / q75", value: "\(formatNumber(contracts.thresholds.q25Spend)) / \(formatNumber(contracts.thresholds.q75Spend))")
            metricRow(label: "Net q25 / q75", value: "\(formatNumber(contracts.thresholds.q25Net)) / \(formatNumber(contracts.thresholds.q75Net))")
            metricRow(label: "Weeks since cap", value: "\(contracts.thresholds.weeksSinceCap)")
            metricRow(label: "Ratio clip max", value: formatNumber(contracts.thresholds.ratioClipMax))
            metricRow(label: "EPS", value: formatScientific(contracts.thresholds.eps))
        }
    }

    private var storageSection: some View {
        infoCard(title: "Local storage") {
            metricRow(label: "Weekly records", value: "\(weeklyRecords.count)")
            metricRow(label: "Predictions", value: "\(predictionSnapshots.count)")
            metricRow(label: "Calibrator states", value: "\(calibrationStates.count)")

            if let latestWeek = weeklyRecords.first {
                Divider().padding(.vertical, 6)
                Text("Latest week")
                    .font(.headline)
                metricRow(label: "Week start", value: shortDateFormatter.string(from: latestWeek.weekStart ?? .now))
                metricRow(label: "Spend bucket", value: numericString(latestWeek.modelSpendBucket))
                metricRow(label: "Actual bucket", value: latestWeek.hasActualOutcome ? numericString(latestWeek.actualSpendBucket) : "pending")
                metricRow(
                    label: "Inflow / outflow",
                    value: "\(formatNumber(numericValue(latestWeek.inflow))) / \(formatNumber(numericValue(latestWeek.outflow)))"
                )
            }

            if let latestPrediction = predictionSnapshots.first {
                Divider().padding(.vertical, 6)
                Text("Latest prediction")
                    .font(.headline)
                metricRow(label: "Class", value: numericString(latestPrediction.predictedClass))
                metricRow(label: "Confidence", value: formatPercent(numericValue(latestPrediction.confidence)))
                metricRow(label: "Low confidence", value: latestPrediction.isLowConfidence ? "yes" : "no")
                metricRow(
                    label: "Probabilities",
                    value: [latestPrediction.probability0, latestPrediction.probability1, latestPrediction.probability2, latestPrediction.probability3]
                        .map { formatPercent(numericValue($0)) }
                        .joined(separator: " | ")
                )
            }
        }
    }

    private var provenanceSection: some View {
        infoCard(title: "Bundle provenance") {
            metricRow(label: "Release prefix", value: contracts.releaseManifest.selectedPrefix)
            metricRow(label: "RF balanced acc", value: formatPercent(contracts.releaseManifest.metrics.rfBalancedAccuracy))
            metricRow(label: "Model package", value: contracts.modelResourceExists ? "available" : "missing")
            metricRow(label: "Feature passport", value: contracts.featurePassportExists ? "available" : "missing")
            metricRow(label: "Release manifest", value: contracts.releaseManifestExists ? "available" : "missing")
            metricRow(label: "Golden set", value: contracts.goldenInferenceSetRecordCount.map { "\($0) records" } ?? "missing")
            metricRow(label: "Passport lines", value: contracts.featurePassportLineCount.map { "\($0) lines" } ?? "n/a")

            if !contracts.issues.isEmpty {
                Divider().padding(.vertical, 6)
                Text("Load issues")
                    .font(.headline)
                ForEach(contracts.issues, id: \.self) { issue in
                    Text("• \(issue)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func infoCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.05), radius: 12, y: 6)
        )
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
    }

    private func formatNumber(_ value: Double) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatScientific(_ value: Double) -> String {
        scientificFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatPercent(_ value: Double) -> String {
        percentageFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func numericValue(_ value: NSNumber?) -> Double {
        value?.doubleValue ?? 0
    }

    private func numericString(_ value: NSNumber?) -> String {
        value.map { String($0.int64Value) } ?? "n/a"
    }
}

private let numberFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 2
    formatter.minimumFractionDigits = 0
    return formatter
}()

private let scientificFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .scientific
    formatter.maximumFractionDigits = 2
    return formatter
}()

private let percentageFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .percent
    formatter.maximumFractionDigits = 1
    formatter.minimumFractionDigits = 0
    return formatter
}()

private let shortDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
}()

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(contracts: AppContractStore())
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
#endif

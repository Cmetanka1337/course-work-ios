import CoreData
import SwiftUI

private enum Stage3Section: String, CaseIterable, Identifiable {
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

struct ContentView: View {
    let contracts: AppContractStore

    @Environment(\.managedObjectContext) private var viewContext

    @State private var predictionPipelineStatus = "Awaiting history"
    @State private var closeOutflowInput = ""
    @State private var closeFlowStatus = "Add or seed a week, then save the real outflow when the week is over."
    @State private var calibrationStatus: CalibrationStatus?
    @State private var calibrationSnapshot: CalibrationStateSnapshot?
    @State private var calibrationActionStatus = "RF-only until personalization warm-up finishes."
    @State private var selectedSection: Stage3Section = .addWeek

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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stage 3 weekly personalization")
                .font(.system(.title, design: .rounded).weight(.bold))
            Text("This flow keeps week capture simple: create a week, close it with the real outflow, and let the app build local personalization only when enough labeled history exists.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var weeklyFlowSection: some View {
        infoCard(title: "Weekly flow") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Use the same four-step loop every week so the app can move from plain RF predictions to transparent, local personalization.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                flowStepRow(
                    number: 1,
                    title: "Create or seed history",
                    detail: "Use Seed demo data for a presentation-ready timeline, or Add pending week for the next real week.",
                    status: orderedWeeklyRecords.isEmpty ? "Current" : "Done",
                    tone: orderedWeeklyRecords.isEmpty ? .blue : .green
                )

                flowStepRow(
                    number: 2,
                    title: "Close a week with the real outflow",
                    detail: "Save outcome stores the raw amount and derives the frozen spend bucket for that week.",
                    status: closedWeeks.isEmpty ? "Current" : "Done",
                    tone: closedWeeks.isEmpty ? .blue : .green
                )

                flowStepRow(
                    number: 3,
                    title: "Build labeled samples",
                    detail: "Closed weeks become calibration labels only after the RF warm-up window exists for that week.",
                    status: labeledSamples.isEmpty ? "Later" : "Done",
                    tone: labeledSamples.isEmpty ? .orange : .green
                )

                flowStepRow(
                    number: 4,
                    title: "Activate personalization",
                    detail: "The app stays RF-only until warm-up labels exist and at least one calibration pass completes.",
                    status: personalizationIsActive ? "Done" : (canRetrainNow ? "Ready now" : "Later"),
                    tone: personalizationIsActive ? .teal : (canRetrainNow ? .green : .orange)
                )

                Divider()
                metricRow(label: "Recommended next step", value: nextRecommendedActionText)
            }
        }
    }

    private var predictionOverviewSection: some View {
        infoCard(title: "Current prediction") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    statusPill(
                        title: currentInferenceModeTitle,
                        tone: usesBlendedInference ? .teal : .blue
                    )
                    statusPill(
                        title: latestPrediction?.isLowConfidence == true ? "Low confidence" : "Confidence OK",
                        tone: latestPrediction?.isLowConfidence == true ? .orange : .green
                    )
                }

                Text(currentInferenceExplanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let latestPrediction {
                    metricRow(label: "Predicted bucket", value: bucketName(latestPrediction.predictedClass?.intValue ?? 0))
                    metricRow(label: "Confidence", value: formatPercent(numericValue(latestPrediction.confidence)))
                    metricRow(label: "High spend risk", value: formatPercent(numericValue(latestPrediction.probability3)))
                    metricRow(label: "Pipeline status", value: predictionPipelineStatus)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Probability mix")
                            .font(.subheadline.weight(.semibold))
                        probabilityBar(label: bucketName(0), value: numericValue(latestPrediction.probability0))
                        probabilityBar(label: bucketName(1), value: numericValue(latestPrediction.probability1))
                        probabilityBar(label: bucketName(2), value: numericValue(latestPrediction.probability2))
                        probabilityBar(label: bucketName(3), value: numericValue(latestPrediction.probability3))
                    }

                    if latestPrediction.isLowConfidence {
                        Text("The model still returns a bucket, but the confidence bar is below the threshold, so treat it as a softer suggestion.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No prediction snapshot yet. Add more weekly history if the RF model is still in warm-up.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Stage3Section.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                                .font(.subheadline.weight(.semibold))
                            Text(section.subtitle)
                                .font(.caption)
                                .multilineTextAlignment(.leading)
                        }
                        .foregroundStyle(selectedSection == section ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(width: 170, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(selectedSection == section ? Color(red: 0.16, green: 0.38, blue: 0.57) : Color.white.opacity(0.88))
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("section-\(section.rawValue)")
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var activeSection: some View {
        switch selectedSection {
        case .addWeek:
            addWeekSection
        case .closeWeek:
            closeWeekSection
        case .history:
            historySection
        case .calibration:
            calibrationSection
        }
    }

    private var addWeekSection: some View {
        infoCard(title: "Add Week") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Use this step to create a realistic weekly flow before you close a week. Demo data builds a full story for presentations, while Add pending week adds the next not-yet-closed week to the local timeline.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                actionRow(
                    title: "Seed demo data",
                    description: "Creates a demonstration history with closed weeks, predictions, and one pending week so the rest of the flow is visible immediately.",
                    buttonTitle: "Seed demo data",
                    tint: Color(red: 0.19, green: 0.45, blue: 0.36),
                    action: seedDemoData
                )

                actionRow(
                    title: "Add pending week",
                    description: "Adds a new not-yet-closed week. The app copies the latest week shape so you can move straight to the close step.",
                    buttonTitle: "Add pending week",
                    tint: Color(red: 0.16, green: 0.38, blue: 0.57),
                    action: addPendingWeek
                )

                actionRow(
                    title: "Reset all data",
                    description: "Clears the local Core Data store, prediction snapshots, and calibration state so you can replay the Stage 3 flow from scratch.",
                    buttonTitle: "Reset all data",
                    tint: Color(red: 0.73, green: 0.29, blue: 0.24),
                    role: .destructive
                ) {
                    do {
                        try resetAllData()
                    } catch {
                        closeFlowStatus = "Failed to reset local data."
                        print("Reset error: \(error.localizedDescription)")
                    }
                }

                Divider()

                if let previewDate = nextPendingWeekDate {
                    metricRow(label: "Next week to create", value: "\(shortDateFormatter.string(from: previewDate)) (idx \(nextPendingWeekIndex))")
                }
                metricRow(label: "Weeks in local history", value: "\(orderedWeeklyRecords.count)")
                metricRow(label: "Closed weeks", value: "\(closedWeeks.count)")
                metricRow(label: "Pending weeks", value: "\(pendingWeeks.count)")
            }
        }
    }

    private var closeWeekSection: some View {
        infoCard(title: "Close Week") {
            VStack(alignment: .leading, spacing: 16) {
                Text("When the week ends, enter the actual outflow total. Save outcome stores the raw amount, derives the frozen spend bucket, and creates a personalization label once enough prediction history exists for that week.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let targetWeek = latestPendingWeek {
                    VStack(alignment: .leading, spacing: 10) {
                        metricRow(
                            label: "Pending week",
                            value: "\(shortDateFormatter.string(from: targetWeek.weekStart ?? .now)) (idx \(targetWeek.weekIndex?.intValue ?? 0))"
                        )
                        metricRow(label: "Reference inflow", value: formatNumber(numericValue(targetWeek.inflow)))
                        metricRow(label: "Reference planned outflow", value: formatNumber(numericValue(targetWeek.outflow)))

                        TextField("Actual outflow amount", text: $closeOutflowInput)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)

                        if let typedAmount = parsedCloseOutflow {
                            metricRow(label: "Derived bucket", value: bucketName(spendBucket(for: typedAmount)))

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Saving now will")
                                    .font(.subheadline.weight(.semibold))

                                ForEach(saveOutcomePreviewLines(for: targetWeek, amount: typedAmount), id: \.self) { line in
                                    HStack(alignment: .top, spacing: 8) {
                                        Circle()
                                            .fill(Color(red: 0.18, green: 0.48, blue: 0.64))
                                            .frame(width: 6, height: 6)
                                            .padding(.top, 6)
                                        Text(line)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white.opacity(0.72))
                            )
                        }

                        Button("Save outcome") {
                            submitOutcome(for: targetWeek)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Text("There is no pending week right now. Create one in Add Week, then come back here to capture the real outcome.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()
                metricRow(label: "Close flow status", value: closeFlowStatus)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            infoCard(title: "Weekly history") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Closed weeks show what the user actually entered. Pending weeks stay visible until they receive a real outcome.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    metricRow(label: "Weekly records", value: "\(orderedWeeklyRecords.count)")
                    metricRow(label: "Prediction snapshots", value: "\(predictionSnapshots.count)")
                    metricRow(label: "Closed weeks", value: "\(closedWeeks.count)")

                    if orderedWeeklyRecords.isEmpty {
                        Text("No weekly history yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(orderedWeeklyRecords.prefix(8)), id: \.objectID) { week in
                            historyWeekRow(week)
                        }
                    }
                }
            }

            infoCard(title: "Calibration audit trail") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("These are the labeled samples currently stored for personalization. Each sample keeps the raw amount, derived bucket, week index, and capture time so the ground truth path is transparent.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    metricRow(label: "Stored labels", value: "\(labeledSamples.count)")
                    metricRow(label: "Calibrator buffer", value: "\(calibrationStatus?.bufferSize ?? labeledSamples.count)")

                    if labeledSamples.isEmpty {
                        Text("No labeled calibration samples yet. Close weeks after the RF warm-up window to populate this list.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(labeledSamples.prefix(10)), id: \.weekIndex) { sample in
                            auditSampleRow(sample)
                        }
                    }
                }
            }
        }
    }

    private var calibrationSection: some View {
        infoCard(title: "Calibration") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Personalization stays RF-only until there are enough labeled weeks and at least one training pass has finished. After that, the app blends RF and calibrator output on device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 12) {
                    statusPill(
                        title: personalizationIsActive ? "Personalization active" : "RF-only mode",
                        tone: personalizationIsActive ? .teal : .blue
                    )
                    statusPill(
                        title: retrainAvailabilityText,
                        tone: canRetrainNow ? .green : .orange
                    )
                }

                metricRow(label: "Labeled weeks", value: "\(labeledSamples.count) / \(warmupWeeks)")
                metricRow(label: "Warm-up state", value: warmupSummaryText)
                metricRow(label: "Current inference", value: currentInferenceModeTitle)
                metricRow(label: "Next automatic update", value: nextAutomaticUpdateText)
                metricRow(label: "Manual retrain", value: canRetrainNow ? "Available now" : "Locked until warm-up finishes")
                metricRow(label: "Calibration cadence", value: "Every \(calibrationCadence) labeled week(s)")
                metricRow(label: "Last state save", value: lastCalibrationStateSaveText)
                metricRow(label: "Latest state note", value: calibrationStateNote)
                metricRow(label: "Stored weights", value: storedWeightsStatusText)
                metricRow(label: "Weeks since last update", value: "\(calibrationStatus?.weeksSinceLastUpdate ?? 0)")
                metricRow(label: "Completed updates", value: "\(calibrationStatus?.updateCount ?? 0)")
                metricRow(label: "Blend alpha", value: formatPercent(calibrationSnapshot?.config.alpha ?? contracts.featureContract.guardrails.alphaAfterWarmup))
                metricRow(label: "Low-confidence threshold", value: formatPercent(calibrationSnapshot?.config.confidenceThreshold ?? (contracts.featureContract.guardrails.confidenceThreshold ?? 0.5)))

                HStack(spacing: 12) {
                    Button("Retrain now") {
                        retrainCalibration()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRetrainNow)

                    Button("Reset calibration") {
                        resetCalibration()
                    }
                    .buttonStyle(.bordered)
                }

                Text("Retrain now runs a manual calibration pass once warm-up labels exist. Reset calibration clears the calibrator weights and buffered labels, but keeps the weekly history intact.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("Samples, buffer contents, and calibrator weights are stored locally in Core Data and restored on the next app launch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                metricRow(label: "Calibration action", value: calibrationActionStatus)
            }
        }
    }

    private var diagnosticsSection: some View {
        infoCard(title: "Diagnostics") {
            DisclosureGroup("Model and storage details") {
                VStack(alignment: .leading, spacing: 10) {
                    metricRow(label: "Features", value: "\(contracts.featureContract.featureOrder.count)")
                    metricRow(label: "Warm-up", value: "\(contracts.featureContract.guardrails.warmupWeeks) weeks")
                    metricRow(label: "RF balanced acc", value: formatPercent(contracts.releaseManifest.metrics.rfBalancedAccuracy))
                    metricRow(label: "Spend q25 / q75", value: "\(formatNumber(contracts.thresholds.q25Spend)) / \(formatNumber(contracts.thresholds.q75Spend))")
                    metricRow(label: "Local calibrator states", value: "\(calibrationStates.count)")
                    metricRow(label: "Release prefix", value: contracts.releaseManifest.selectedPrefix)
                    metricRow(label: "Model package", value: contracts.modelResourceExists ? "available" : "missing")
                    metricRow(label: "Golden set", value: contracts.goldenInferenceSetRecordCount.map { "\($0) records" } ?? "missing")
                }
                .padding(.top, 8)
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
                .fill(.white.opacity(0.87))
                .shadow(color: .black.opacity(0.05), radius: 12, y: 6)
        )
    }

    private func actionRow(
        title: String,
        description: String,
        buttonTitle: String,
        tint: Color,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(buttonTitle, role: role, action: action)
                .buttonStyle(.borderedProminent)
                .tint(tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.72))
        )
    }

    private func flowStepRow(
        number: Int,
        title: String,
        detail: String,
        status: String,
        tone: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(tone.opacity(0.14))
                    .frame(width: 34, height: 34)
                Text("\(number)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(tone)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 12)
                    statusPill(title: status, tone: tone)
                }
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.72))
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

    private func statusPill(title: String, tone: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tone)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(tone.opacity(0.12))
            )
    }

    private func probabilityBar(label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(formatPercent(value))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.06))
                    Capsule(style: .continuous)
                        .fill(Color(red: 0.18, green: 0.48, blue: 0.64))
                        .frame(width: proxy.size.width * max(0.0, min(1.0, value)))
                }
            }
            .frame(height: 10)
        }
    }

    private func historyWeekRow(_ week: WeeklyRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(shortDateFormatter.string(from: week.weekStart ?? .now))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("idx \(week.weekIndex?.intValue ?? 0)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            metricRow(label: "Inflow / outflow", value: "\(formatNumber(numericValue(week.inflow))) / \(formatNumber(numericValue(week.outflow)))")
            metricRow(
                label: "Actual outcome",
                value: week.hasActualOutcome
                    ? "\(formatNumber(numericValue(week.actualSpendAmount))) -> \(bucketName(week.actualSpendBucket?.intValue ?? 0))"
                    : "Pending"
            )
            metricRow(label: "Calibration label", value: calibrationLabelStatus(for: week))
            metricRow(label: "Recorded at", value: timestampFormatter.string(from: week.updatedAt ?? week.createdAt ?? .now))
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func auditSampleRow(_ sample: CalibrationSample) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(sample.weekStart.map(shortDateFormatter.string(from:)) ?? "Week \(sample.weekIndex)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("idx \(sample.weekIndex)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            metricRow(label: "Raw amount", value: formatNumber(sample.actualOutflow))
            metricRow(label: "Derived bucket", value: bucketName(sample.yTrue))
            metricRow(label: "Calibrator buffer", value: "Included")
            metricRow(label: "Saved at", value: sample.recordedAt == .distantPast ? "Legacy sample" : timestampFormatter.string(from: sample.recordedAt))
            metricRow(
                label: "RF probs",
                value: sample.pRF.map { formatPercent($0) }.joined(separator: " | ")
            )
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func formatNumber(_ value: Double) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatPercent(_ value: Double) -> String {
        percentageFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func numericValue(_ value: NSNumber?) -> Double {
        value?.doubleValue ?? 0
    }

    private var latestPrediction: PredictionSnapshot? {
        predictionSnapshots.first
    }

    private var latestCalibrationState: CalibrationStateRecord? {
        calibrationStates.first
    }

    private var orderedWeeklyRecords: [WeeklyRecord] {
        weeklyRecords.sorted { ($0.weekStart ?? .distantPast) > ($1.weekStart ?? .distantPast) }
    }

    private var pendingWeeks: [WeeklyRecord] {
        orderedWeeklyRecords.filter { !$0.hasActualOutcome }
    }

    private var closedWeeks: [WeeklyRecord] {
        orderedWeeklyRecords.filter(\.hasActualOutcome)
    }

    private var latestPendingWeek: WeeklyRecord? {
        pendingWeeks.first
    }

    private var labeledSamples: [CalibrationSample] {
        (calibrationSnapshot?.samples ?? []).sorted { $0.weekIndex > $1.weekIndex }
    }

    private var warmupWeeks: Int {
        contracts.featureContract.guardrails.warmupWeeks
    }

    private var calibrationCadence: Int {
        calibrationStatus?.updateEveryWeeks ?? calibrationSnapshot?.config.updateEveryWeeks ?? 2
    }

    private var canRetrainNow: Bool {
        calibrationStatus?.canRetrainNow ?? (labeledSamples.count >= warmupWeeks)
    }

    private var personalizationIsActive: Bool {
        calibrationStates.first?.isActive ?? calibrationStatus?.isActive ?? false
    }

    private var usesBlendedInference: Bool {
        personalizationIsActive && latestPrediction?.sourceMode == "blended"
    }

    private var currentInferenceModeTitle: String {
        if usesBlendedInference {
            return "Blended personalization"
        }
        if orderedWeeklyRecords.count < warmupWeeks {
            return "RF warm-up"
        }
        return "RF-only"
    }

    private var currentInferenceExplanation: String {
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

    private var nextRecommendedActionText: String {
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

    private var warmupSummaryText: String {
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

    private var nextAutomaticUpdateText: String {
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

    private var retrainAvailabilityText: String {
        canRetrainNow ? "Retrain available" : "Retrain locked"
    }

    private var lastCalibrationStateSaveText: String {
        guard let timestamp = latestCalibrationState?.updatedAt else {
            return "No calibration state yet"
        }
        return timestampFormatter.string(from: timestamp)
    }

    private var calibrationStateNote: String {
        latestCalibrationState?.notes ?? "No calibration events yet."
    }

    private var storedWeightsStatusText: String {
        guard let snapshot = calibrationSnapshot else {
            return "No state saved yet"
        }
        return snapshotLooksPersonalized(snapshot) ? "Personalized weights saved" : "Identity weights only"
    }

    private var parsedCloseOutflow: Double? {
        let normalized = closeOutflowInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }

    private var nextPendingWeekDate: Date? {
        let calendar = Calendar(identifier: .gregorian)
        let latestDate = orderedWeeklyRecords.compactMap(\.weekStart).max()
            ?? calendar.date(from: DateComponents(year: 2026, month: 4, day: 6))
        return latestDate.flatMap { calendar.date(byAdding: .weekOfYear, value: 1, to: $0) }
    }

    private var nextPendingWeekIndex: Int {
        (orderedWeeklyRecords.map { $0.weekIndex?.intValue ?? -1 }.max() ?? -1) + 1
    }

    private func saveOutcomePreviewLines(for week: WeeklyRecord, amount: Double) -> [String] {
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

    private func calibrationLabelStatus(for week: WeeklyRecord) -> String {
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

    private func historyCount(upTo week: WeeklyRecord) -> Int {
        orderedWeeklyRecords.filter { ($0.weekStart ?? .distantPast) <= (week.weekStart ?? .distantFuture) }.count
    }

    private func snapshotLooksPersonalized(_ snapshot: CalibrationStateSnapshot) -> Bool {
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

    private func bucketName(_ bucket: Int) -> String {
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

    private func spendBucket(for outflow: Double) -> Int {
        PersonalizationService.spendBucket(for: max(0.0, outflow), thresholds: contracts.thresholds)
    }

    @MainActor
    private func refreshPredictionSnapshot() async {
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
    private func submitOutcome(for week: WeeklyRecord) {
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
    private func seedDemoData() {
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
    private func addPendingWeek() {
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
    private func resetAllData() throws {
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
    private func retrainCalibration() {
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
    private func resetCalibration() {
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

private let numberFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 2
    formatter.minimumFractionDigits = 0
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

private let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
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

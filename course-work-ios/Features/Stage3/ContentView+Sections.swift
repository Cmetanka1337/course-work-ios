import SwiftUI

extension ContentView {
    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stage 3 weekly personalization")
                .font(.system(.title, design: .rounded).weight(.bold))
            Text("This flow keeps week capture simple: create a week, close it with the real outflow, and let the app build local personalization only when enough labeled history exists.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    var weeklyFlowSection: some View {
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

    var predictionOverviewSection: some View {
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

    var sectionPicker: some View {
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
    var activeSection: some View {
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

    var addWeekSection: some View {
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

    var closeWeekSection: some View {
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

    var historySection: some View {
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

    var calibrationSection: some View {
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

    var diagnosticsSection: some View {
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
}

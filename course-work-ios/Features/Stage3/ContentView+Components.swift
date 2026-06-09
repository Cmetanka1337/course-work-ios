import SwiftUI

extension ContentView {
    func infoCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
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

    func actionRow(
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

    func flowStepRow(
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

    func metricRow(label: String, value: String) -> some View {
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

    func statusPill(title: String, tone: Color) -> some View {
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

    func probabilityBar(label: String, value: Double) -> some View {
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

    func historyWeekRow(_ week: WeeklyRecord) -> some View {
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

    func auditSampleRow(_ sample: CalibrationSample) -> some View {
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
}

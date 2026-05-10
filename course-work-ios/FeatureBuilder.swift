import Foundation

struct WeeklyFeatureInput: Equatable {
    let weekStart: Date
    let weekIndex: Int
    let inflow: Double
    let outflow: Double
    let txnCount: Double
    let categoryDiversity: Double

    var net: Double {
        inflow - outflow
    }
}

enum FeatureBuilderError: LocalizedError {
    case emptyHistory
    case unsupportedFeatureName(String)

    var errorDescription: String? {
        switch self {
        case .emptyHistory:
            return "Cannot build features from empty history."
        case let .unsupportedFeatureName(name):
            return "Unsupported feature name in contract: \(name)"
        }
    }
}

struct FeatureBuilder {
    private let contract: FeatureContract
    private let thresholds: BucketThresholds
    private let calendar: Calendar
    private let isoCalendar: Calendar

    init(
        contract: FeatureContract,
        thresholds: BucketThresholds,
        calendar: Calendar = Calendar(identifier: .gregorian),
        isoCalendar: Calendar = Calendar(identifier: .iso8601)
    ) {
        self.contract = contract
        self.thresholds = thresholds
        self.calendar = calendar
        self.isoCalendar = isoCalendar
    }

    func buildFeatureVector(from history: [WeeklyFeatureInput]) throws -> [String: Double] {
        let ordered = history.sorted(by: { $0.weekStart < $1.weekStart })
        guard let current = ordered.last else {
            throw FeatureBuilderError.emptyHistory
        }

        let currentIndex = ordered.count - 1
        let inflows = ordered.map(\.inflow)
        let outflows = ordered.map(\.outflow)
        let nets = ordered.map(\.net)

        let lagInflow1 = lag(inflows, index: currentIndex, steps: 1)
        let lagOutflow1 = lag(outflows, index: currentIndex, steps: 1)
        let lagNet1 = lag(nets, index: currentIndex, steps: 1)
        let lagInflow2 = lag(inflows, index: currentIndex, steps: 2)
        let lagOutflow2 = lag(outflows, index: currentIndex, steps: 2)

        let shiftedInflows = Array(inflows.prefix(currentIndex))
        let shiftedOutflows = Array(outflows.prefix(currentIndex))
        let inflowWindow = rollingWindow(shiftedInflows, size: 8)
        let outflowWindow = rollingWindow(shiftedOutflows, size: 8)

        let weekOfYear = Double(isoCalendar.component(.weekOfYear, from: current.weekStart))
        let month = Double(calendar.component(.month, from: current.weekStart))
        let quarter = Double(Int((month - 1.0) / 3.0) + 1)
        let dayOfMonth = calendar.component(.day, from: current.weekStart)
        let weekOfMonth = Double(1 + (dayOfMonth - 1) / 7)
        let isMonthStartWeek = dayOfMonth <= 7 ? 1.0 : 0.0

        let weekEnd = calendar.date(byAdding: .day, value: 6, to: current.weekStart) ?? current.weekStart
        let daysInMonth = calendar.range(of: .day, in: .month, for: weekEnd)?.count ?? 31
        let dayOfWeekEndMonth = calendar.component(.day, from: weekEnd)
        let isMonthEndWeek = dayOfWeekEndMonth >= (daysInMonth - 6) ? 1.0 : 0.0

        let rawMap: [String: Double] = [
            "bucket_spend_t": Double(spendBucket(for: current.outflow)),
            "bucket_net_t": Double(netBucket(for: current.net)),
            "weekly_inflow_t": current.inflow,
            "weekly_outflow_t": current.outflow,
            "weekly_net_t": current.net,
            "txn_count_t": current.txnCount,
            "category_diversity_t": current.categoryDiversity,
            "weekly_inflow_t_minus_1": lagInflow1,
            "weekly_outflow_t_minus_1": lagOutflow1,
            "weekly_net_t_minus_1": lagNet1,
            "weekly_inflow_t_minus_2": lagInflow2,
            "weekly_outflow_t_minus_2": lagOutflow2,
            "outflow_inflow_ratio_t": current.inflow == 0 ? 0.0 : current.outflow / current.inflow,
            "week_of_year": weekOfYear,
            "month": month,
            "quarter": quarter,
            "week_of_month": weekOfMonth,
            "is_month_start_week": isMonthStartWeek,
            "is_month_end_week": isMonthEndWeek,
            "delta_inflow": current.inflow - lagInflow1,
            "delta_outflow": current.outflow - lagOutflow1,
            "inflow_outflow_ratio": clipped(
                current.inflow / (current.outflow + thresholds.eps),
                min: 0,
                max: thresholds.ratioClipMax
            ),
            "inflow_share": clipped(
                current.inflow / (current.inflow + current.outflow + thresholds.eps),
                min: 0,
                max: 1
            ),
            "inflow_rolling_mean_8w": mean(inflowWindow),
            "inflow_rolling_std_8w": sampleStd(inflowWindow),
            "outflow_rolling_mean_8w": mean(outflowWindow),
            "outflow_rolling_std_8w": sampleStd(outflowWindow),
            "inflow_frequency_8w": mean(inflowWindow.map { $0 > 0 ? 1.0 : 0.0 }),
            "outflow_frequency_8w": mean(outflowWindow.map { $0 > 0 ? 1.0 : 0.0 }),
            "weeks_since_inflow": weeksSinceLastPositive(shiftedInflows),
            "weeks_since_outflow": weeksSinceLastPositive(shiftedOutflows)
        ]

        var sanitized: [String: Double] = [:]
        sanitized.reserveCapacity(contract.featureOrder.count)

        for name in contract.featureOrder {
            guard let value = rawMap[name] else {
                throw FeatureBuilderError.unsupportedFeatureName(name)
            }
            sanitized[name] = sanitize(value)
        }

        return sanitized
    }

    private func lag(_ values: [Double], index: Int, steps: Int) -> Double {
        let lagIndex = index - steps
        guard lagIndex >= 0 else { return 0.0 }
        return values[lagIndex]
    }

    private func rollingWindow(_ values: [Double], size: Int) -> [Double] {
        guard size > 0 else { return [] }
        // Match pandas rolling(window=8, min_periods=8): emit empty until a full window exists.
        if values.count < size {
            return []
        }
        return Array(values.suffix(size))
    }

    private func spendBucket(for outflow: Double) -> Int {
        if outflow == 0 { return 0 }
        if outflow <= thresholds.q25Spend { return 1 }
        if outflow <= thresholds.q75Spend { return 2 }
        return 3
    }

    private func netBucket(for net: Double) -> Int {
        if net == 0 { return 0 }
        if net <= thresholds.q25Net { return 1 }
        if net <= thresholds.q75Net { return 2 }
        return 3
    }

    private func weeksSinceLastPositive(_ shifted: [Double]) -> Double {
        guard let lastPositiveIndex = shifted.lastIndex(where: { $0 > 0 }) else {
            return Double(thresholds.weeksSinceCap)
        }
        let distance = shifted.count - lastPositiveIndex
        return Double(min(distance, thresholds.weeksSinceCap))
    }

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.0 }
        return values.reduce(0.0, +) / Double(values.count)
    }

    private func sampleStd(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0.0 }
        let avg = mean(values)
        let variance = values.reduce(0.0) { partial, value in
            let diff = value - avg
            return partial + (diff * diff)
        } / Double(values.count - 1)

        if variance.isNaN || variance.isInfinite || variance < 0 {
            return 0.0
        }
        return sqrt(variance)
    }

    private func clipped(_ value: Double, min lower: Double, max upper: Double) -> Double {
        Swift.max(lower, Swift.min(upper, value))
    }

    private func sanitize(_ value: Double) -> Double {
        value.isFinite ? value : 0.0
    }
}

extension WeeklyRecord {
    var stage2FeatureInput: WeeklyFeatureInput? {
        guard let weekStart else { return nil }
        return WeeklyFeatureInput(
            weekStart: weekStart,
            weekIndex: Int(weekIndex?.intValue ?? 0),
            inflow: inflow?.doubleValue ?? 0.0,
            outflow: outflow?.doubleValue ?? 0.0,
            txnCount: txnCount?.doubleValue ?? 0.0,
            categoryDiversity: categoryDiversity?.doubleValue ?? 0.0
        )
    }
}

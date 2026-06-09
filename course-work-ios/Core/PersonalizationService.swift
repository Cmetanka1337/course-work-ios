import CoreData
import Foundation

struct CalibrationSample: Codable, Equatable {
    let weekIndex: Int
    let weekStart: Date?
    let pRF: [Double]
    let yTrue: Int
    let actualOutflow: Double
    let recordedAt: Date

    enum CodingKeys: String, CodingKey {
        case weekIndex
        case weekStart
        case pRF
        case yTrue
        case actualOutflow
        case recordedAt
    }

    init(
        weekIndex: Int,
        weekStart: Date? = nil,
        pRF: [Double],
        yTrue: Int,
        actualOutflow: Double,
        recordedAt: Date = .now
    ) {
        self.weekIndex = weekIndex
        self.weekStart = weekStart
        self.pRF = pRF
        self.yTrue = yTrue
        self.actualOutflow = actualOutflow
        self.recordedAt = recordedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weekIndex = try container.decode(Int.self, forKey: .weekIndex)
        weekStart = try container.decodeIfPresent(Date.self, forKey: .weekStart)
        pRF = try container.decode([Double].self, forKey: .pRF)
        yTrue = try container.decode(Int.self, forKey: .yTrue)
        actualOutflow = try container.decodeIfPresent(Double.self, forKey: .actualOutflow) ?? 0.0
        recordedAt = try container.decodeIfPresent(Date.self, forKey: .recordedAt) ?? .distantPast
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(weekIndex, forKey: .weekIndex)
        try container.encodeIfPresent(weekStart, forKey: .weekStart)
        try container.encode(pRF, forKey: .pRF)
        try container.encode(yTrue, forKey: .yTrue)
        try container.encode(actualOutflow, forKey: .actualOutflow)
        try container.encode(recordedAt, forKey: .recordedAt)
    }
}

struct CalibrationConfig: Equatable {
    let warmupWeeks: Int
    let updateEveryWeeks: Int
    let historyCap: Int
    let learningRate: Double
    let l2: Double
    let gradClip: Double
    let alpha: Double
    let epochs: Int
    let confidenceThreshold: Double
}

struct CalibrationStatus: Equatable {
    let isActive: Bool
    let labeledWeeks: Int
    let bufferSize: Int
    let warmupWeeks: Int
    let updateEveryWeeks: Int
    let weeksSinceLastUpdate: Int
    let updateCount: Int
    let canRetrainNow: Bool
}

struct CalibrationStateSnapshot {
    let config: CalibrationConfig
    let weights: [[Double]]
    let bias: [Double]
    var samples: [CalibrationSample]
}

enum WeeklyOutcomeCaptureResult: Equatable {
    case updatedOnlyWarmup(completedWeeks: Int, requiredWeeks: Int)
    case updatedAndQueuedForCalibration
    case updatedAndTrained
}

struct SoftmaxCalibrator {
    var weights: [[Double]]
    var bias: [Double]

    static func identity(classCount: Int = 4) -> SoftmaxCalibrator {
        let identity = (0..<classCount).map { row in
            (0..<classCount).map { column in
                row == column ? 1.0 : 0.0
            }
        }
        return SoftmaxCalibrator(weights: identity, bias: Array(repeating: 0.0, count: classCount))
    }

    func predict(_ pRF: [Double]) -> [Double] {
        let classCount = bias.count
        var logits = Array(repeating: 0.0, count: classCount)
        for row in 0..<classCount {
            var total = bias[row]
            for column in 0..<classCount {
                total += weights[row][column] * pRF[column]
            }
            logits[row] = total
        }
        return softmax(logits)
    }

    mutating func train(samples: [CalibrationSample], config: CalibrationConfig) {
        guard !samples.isEmpty else { return }
        let classCount = bias.count

        for _ in 0..<config.epochs {
            for sample in samples {
                let pAdj = predict(sample.pRF)
                var gradZ = Array(repeating: 0.0, count: classCount)
                for i in 0..<classCount {
                    let oneHot = i == sample.yTrue ? 1.0 : 0.0
                    gradZ[i] = pAdj[i] - oneHot
                }

                for i in 0..<classCount {
                    for j in 0..<classCount {
                        let rawGrad = gradZ[i] * sample.pRF[j] + (config.l2 * weights[i][j])
                        let clippedGrad = clip(rawGrad, min: -config.gradClip, max: config.gradClip)
                        weights[i][j] -= config.learningRate * clippedGrad
                    }
                }

                for i in 0..<classCount {
                    let clippedBiasGrad = clip(gradZ[i], min: -config.gradClip, max: config.gradClip)
                    bias[i] -= config.learningRate * clippedBiasGrad
                }
            }
        }
    }

    private func softmax(_ values: [Double]) -> [Double] {
        guard !values.isEmpty else { return [] }
        let maxValue = values.max() ?? 0.0
        let exps = values.map { Foundation.exp($0 - maxValue) }
        let sum = exps.reduce(0.0, +)
        guard sum > 0 else {
            return Array(repeating: 1.0 / Double(values.count), count: values.count)
        }
        return exps.map { $0 / sum }
    }

    private func clip(_ value: Double, min lower: Double, max upper: Double) -> Double {
        Swift.max(lower, Swift.min(upper, value))
    }
}

struct PersonalizationService {
    private let contracts: AppContractStore
    private let predictionService: PredictionService
    private let classOrder = [0, 1, 2, 3]
    private let identityWeights = SoftmaxCalibrator.identity().weights
    private let identityBias = SoftmaxCalibrator.identity().bias

    init(
        contracts: AppContractStore,
        predictor: ModelPredicting? = nil
    ) throws {
        self.contracts = contracts
        if let predictor {
            predictionService = PredictionService(
                contract: contracts.featureContract,
                thresholds: contracts.thresholds,
                predictor: predictor
            )
        } else {
            predictionService = try PredictionService(contracts: contracts)
        }
    }

    func evaluateAndPersistPrediction(
        for history: [WeeklyRecord],
        in context: NSManagedObjectContext
    ) throws -> PredictionRunResult {
        let baseResult = try predictionService.upsertPredictionSnapshot(for: history, in: context, sourceMode: "rf")
        guard case let .ready(baseComputation) = baseResult else {
            return baseResult
        }

        let state = try ensureCalibrationState(in: context)
        let snapshot = decodeSnapshot(from: state)
        guard canApplyCalibration(snapshot: snapshot, historyCount: history.count, isActive: state.isActive) else {
            return baseResult
        }

        let pRF = classOrder.map { baseComputation.probabilities[$0] ?? 0.0 }
        let calibrator = SoftmaxCalibrator(weights: snapshot.weights, bias: snapshot.bias)
        let pCal = calibrator.predict(pRF)
        let pFinal = zip(pRF, pCal).map { (1.0 - snapshot.config.alpha) * $0 + snapshot.config.alpha * $1 }

        guard let blendedArgmax = pFinal.enumerated().max(by: { $0.element < $1.element })?.offset else {
            return baseResult
        }

        let blendedConfidence = pFinal[blendedArgmax]
        let blendedLowConfidence = blendedConfidence < snapshot.config.confidenceThreshold

        let request: NSFetchRequest<PredictionSnapshot> = PredictionSnapshot.fetchRequest()
        request.fetchLimit = 1
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PredictionSnapshot.createdAt, ascending: false)]
        if let latest = try context.fetch(request).first {
            latest.sourceMode = "blended"
            latest.predictedClass = NSNumber(value: blendedArgmax)
            latest.confidence = NSNumber(value: blendedConfidence)
            latest.probability0 = NSNumber(value: pFinal[safe: 0] ?? 0.0)
            latest.probability1 = NSNumber(value: pFinal[safe: 1] ?? 0.0)
            latest.probability2 = NSNumber(value: pFinal[safe: 2] ?? 0.0)
            latest.probability3 = NSNumber(value: pFinal[safe: 3] ?? 0.0)
            latest.sumProbs = NSNumber(value: pFinal.reduce(0.0, +))
            latest.isLowConfidence = blendedLowConfidence
            let priorNotes = latest.notes ?? ""
            latest.notes = priorNotes + (priorNotes.isEmpty ? "" : "; ") + "blended=true"
        }
        try saveIfNeeded(context)

        let blendedComputation = PredictionComputation(
            predictedClass: blendedArgmax,
            confidence: blendedConfidence,
            probabilities: Dictionary(uniqueKeysWithValues: classOrder.enumerated().map { ($1, pFinal[$0]) }),
            votes: baseComputation.votes,
            featureVector: baseComputation.featureVector,
            diagnostics: baseComputation.diagnostics,
            isLowConfidence: blendedLowConfidence
        )
        return .ready(blendedComputation)
    }

    @discardableResult
    func closeWeek(
        _ week: WeeklyRecord,
        actualOutflow: Double,
        history: [WeeklyRecord],
        in context: NSManagedObjectContext
    ) throws -> WeeklyOutcomeCaptureResult {
        let normalizedOutflow = max(0.0, actualOutflow)
        week.actualSpendAmount = NSNumber(value: normalizedOutflow)
        week.actualSpendBucket = NSNumber(value: Self.spendBucket(for: normalizedOutflow, thresholds: contracts.thresholds))
        week.hasActualOutcome = true
        week.updatedAt = Date()
        try saveIfNeeded(context)

        let orderedHistory = history
            .compactMap { record -> (WeeklyRecord, Date)? in
                guard let weekStart = record.weekStart else { return nil }
                return (record, weekStart)
            }
            .sorted(by: { $0.1 < $1.1 })
            .map(\.0)
        let historyUpToWeek = orderedHistory.filter { ($0.weekStart ?? .distantPast) <= (week.weekStart ?? .distantFuture) }
        let warmupWeeks = contracts.featureContract.guardrails.warmupWeeks
        if historyUpToWeek.count < warmupWeeks {
            return .updatedOnlyWarmup(completedWeeks: historyUpToWeek.count, requiredWeeks: warmupWeeks)
        }

        let predictionResult = try predictionService.runPrediction(for: historyUpToWeek)
        guard case let .ready(computation) = predictionResult else {
            return .updatedOnlyWarmup(completedWeeks: historyUpToWeek.count, requiredWeeks: warmupWeeks)
        }

        let weekIndexValue = week.weekIndex?.intValue ?? 0
        let sample = CalibrationSample(
            weekIndex: weekIndexValue,
            weekStart: week.weekStart,
            pRF: classOrder.map { computation.probabilities[$0] ?? 0.0 },
            yTrue: week.actualSpendBucket?.intValue ?? 0,
            actualOutflow: normalizedOutflow,
            recordedAt: week.updatedAt ?? Date()
        )

        let state = try ensureCalibrationState(in: context)
        var snapshot = decodeSnapshot(from: state)
        snapshot.samples.removeAll(where: { $0.weekIndex == sample.weekIndex })
        snapshot.samples.append(sample)
        snapshot.samples.sort { $0.weekIndex < $1.weekIndex }
        if snapshot.samples.count > snapshot.config.historyCap {
            snapshot.samples = Array(snapshot.samples.suffix(snapshot.config.historyCap))
        }

        let cadence = max(1, snapshot.config.updateEveryWeeks)
        let updatedWeeksSinceLast = (state.weeksSinceLastUpdate?.intValue ?? 0) + 1
        state.weeksSinceLastUpdate = NSNumber(value: updatedWeeksSinceLast)

        let shouldTrain = snapshot.samples.count >= snapshot.config.warmupWeeks && updatedWeeksSinceLast >= cadence
        if shouldTrain {
            var calibrator = SoftmaxCalibrator(weights: snapshot.weights, bias: snapshot.bias)
            calibrator.train(samples: snapshot.samples, config: snapshot.config)
            snapshot = CalibrationStateSnapshot(
                config: snapshot.config,
                weights: calibrator.weights,
                bias: calibrator.bias,
                samples: snapshot.samples
            )
            state.weeksSinceLastUpdate = 0
            state.updateCount = NSNumber(value: (state.updateCount?.intValue ?? 0) + 1)
            state.isActive = true
            state.notes = "Trained on \(snapshot.samples.count) labeled samples."
            persist(snapshot: snapshot, into: state)
            state.updatedAt = Date()
            try saveIfNeeded(context)
            return .updatedAndTrained
        }

        state.isActive = (state.updateCount?.intValue ?? 0) > 0
        state.notes = "Queued \(snapshot.samples.count) labeled samples."
        persist(snapshot: snapshot, into: state)
        state.updatedAt = Date()
        try saveIfNeeded(context)
        return .updatedAndQueuedForCalibration
    }

    func fetchCalibrationStatus(in context: NSManagedObjectContext) throws -> CalibrationStatus {
        let state = try ensureCalibrationState(in: context)
        let snapshot = decodeSnapshot(from: state)
        let labeled = snapshot.samples.count
        let warmup = snapshot.config.warmupWeeks
        return CalibrationStatus(
            isActive: state.isActive,
            labeledWeeks: labeled,
            bufferSize: labeled,
            warmupWeeks: warmup,
            updateEveryWeeks: snapshot.config.updateEveryWeeks,
            weeksSinceLastUpdate: state.weeksSinceLastUpdate?.intValue ?? 0,
            updateCount: state.updateCount?.intValue ?? 0,
            canRetrainNow: labeled >= warmup
        )
    }

    func fetchCalibrationSnapshot(in context: NSManagedObjectContext) throws -> CalibrationStateSnapshot {
        let state = try ensureCalibrationState(in: context)
        return decodeSnapshot(from: state)
    }

    @discardableResult
    func retrainNow(in context: NSManagedObjectContext) throws -> Bool {
        let state = try ensureCalibrationState(in: context)
        var snapshot = decodeSnapshot(from: state)
        guard snapshot.samples.count >= snapshot.config.warmupWeeks else { return false }

        var calibrator = SoftmaxCalibrator(weights: snapshot.weights, bias: snapshot.bias)
        calibrator.train(samples: snapshot.samples, config: snapshot.config)
        snapshot = CalibrationStateSnapshot(
            config: snapshot.config,
            weights: calibrator.weights,
            bias: calibrator.bias,
            samples: snapshot.samples
        )
        persist(snapshot: snapshot, into: state)
        state.weeksSinceLastUpdate = 0
        state.updateCount = NSNumber(value: (state.updateCount?.intValue ?? 0) + 1)
        state.isActive = true
        state.notes = "Manual retrain on \(snapshot.samples.count) samples."
        state.updatedAt = Date()
        try saveIfNeeded(context)
        return true
    }

    func reset(in context: NSManagedObjectContext) throws {
        let state = try ensureCalibrationState(in: context)
        let config = decodeConfig(from: state)
        let resetSnapshot = CalibrationStateSnapshot(
            config: config,
            weights: SoftmaxCalibrator.identity().weights,
            bias: SoftmaxCalibrator.identity().bias,
            samples: []
        )
        persist(snapshot: resetSnapshot, into: state)
        state.weeksSinceLastUpdate = 0
        state.updateCount = 0
        state.isActive = false
        state.notes = "Reset to identity."
        state.updatedAt = Date()
        try saveIfNeeded(context)
    }

    static func spendBucket(for outflow: Double, thresholds: BucketThresholds) -> Int {
        if outflow == 0 { return 0 }
        if outflow <= thresholds.q25Spend { return 1 }
        if outflow <= thresholds.q75Spend { return 2 }
        return 3
    }

    private func canApplyCalibration(snapshot: CalibrationStateSnapshot, historyCount: Int, isActive: Bool) -> Bool {
        isActive &&
            snapshot.samples.count >= snapshot.config.warmupWeeks &&
            stateWeightsLookTrained(snapshot.weights, bias: snapshot.bias) &&
        historyCount >= snapshot.config.warmupWeeks &&
            !snapshot.weights.isEmpty &&
            snapshot.weights.count == classOrder.count &&
            stateVectorLooksValid(snapshot.bias) &&
            snapshot.config.alpha > 0 &&
            snapshot.config.alpha <= 1
    }

    private func stateWeightsLookTrained(_ weights: [[Double]], bias: [Double]) -> Bool {
        guard weights.count == identityWeights.count, bias.count == identityBias.count else {
            return false
        }

        let biasMatchesIdentity = zip(bias, identityBias).allSatisfy { abs($0 - $1) < 0.0000001 }
        let weightsMatchIdentity = zip(weights, identityWeights).allSatisfy { lhsRow, rhsRow in
            guard lhsRow.count == rhsRow.count else { return false }
            return zip(lhsRow, rhsRow).allSatisfy { abs($0 - $1) < 0.0000001 }
        }
        return !(biasMatchesIdentity && weightsMatchIdentity)
    }

    private func stateVectorLooksValid(_ vector: [Double]) -> Bool {
        vector.count == classOrder.count && vector.allSatisfy(\.isFinite)
    }

    private func ensureCalibrationState(in context: NSManagedObjectContext) throws -> CalibrationStateRecord {
        let request: NSFetchRequest<CalibrationStateRecord> = CalibrationStateRecord.fetchRequest()
        request.fetchLimit = 1
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CalibrationStateRecord.createdAt, ascending: true)]

        if let existing = try context.fetch(request).first {
            return existing
        }

        let now = Date()
        let identity = SoftmaxCalibrator.identity()
        let created = CalibrationStateRecord(context: context)
        created.id = UUID()
        created.createdAt = now
        created.updatedAt = now
        created.schemaVersion = "v1"
        created.warmupWeeks = NSNumber(value: contracts.featureContract.guardrails.warmupWeeks)
        created.updateEveryWeeks = 2
        created.historyCap = 20
        created.learningRate = 0.05
        created.l2 = 0.001
        created.gradClip = 5.0
        created.alpha = NSNumber(value: contracts.featureContract.guardrails.alphaAfterWarmup)
        created.epochs = 20
        created.weeksSinceLastUpdate = 0
        created.updateCount = 0
        created.weightsData = encodeMatrix(identity.weights)
        created.biasData = encodeVector(identity.bias)
        created.bufferData = encodeSamples([])
        created.isActive = false
        created.notes = "Initialized."
        try saveIfNeeded(context)
        return created
    }

    private func decodeSnapshot(from state: CalibrationStateRecord) -> CalibrationStateSnapshot {
        let config = decodeConfig(from: state)
        let weights = decodeMatrix(state.weightsData) ?? SoftmaxCalibrator.identity().weights
        let bias = decodeVector(state.biasData) ?? SoftmaxCalibrator.identity().bias
        let samples = decodeSamples(state.bufferData)

        let normalizedWeights = weights.count == classOrder.count
            ? weights.map { row in
                row.count == classOrder.count ? row : Array(row.prefix(classOrder.count)) + Array(repeating: 0.0, count: max(0, classOrder.count - row.count))
            }
            : SoftmaxCalibrator.identity().weights
        let normalizedBias = bias.count == classOrder.count
            ? bias
            : Array(bias.prefix(classOrder.count)) + Array(repeating: 0.0, count: max(0, classOrder.count - bias.count))

        return CalibrationStateSnapshot(
            config: config,
            weights: normalizedWeights,
            bias: normalizedBias,
            samples: samples
        )
    }

    private func decodeConfig(from state: CalibrationStateRecord) -> CalibrationConfig {
        CalibrationConfig(
            warmupWeeks: max(1, state.warmupWeeks?.intValue ?? contracts.featureContract.guardrails.warmupWeeks),
            updateEveryWeeks: max(1, state.updateEveryWeeks?.intValue ?? 2),
            historyCap: max(1, state.historyCap?.intValue ?? 20),
            learningRate: max(0.0001, state.learningRate?.doubleValue ?? 0.05),
            l2: max(0.0, state.l2?.doubleValue ?? 0.001),
            gradClip: max(0.0, state.gradClip?.doubleValue ?? 5.0),
            alpha: min(1.0, max(0.0, state.alpha?.doubleValue ?? contracts.featureContract.guardrails.alphaAfterWarmup)),
            epochs: max(1, state.epochs?.intValue ?? 20),
            confidenceThreshold: contracts.featureContract.guardrails.confidenceThreshold ?? 0.5
        )
    }

    private func persist(snapshot: CalibrationStateSnapshot, into state: CalibrationStateRecord) {
        state.weightsData = encodeMatrix(snapshot.weights)
        state.biasData = encodeVector(snapshot.bias)
        state.bufferData = encodeSamples(snapshot.samples)
    }

    private func encodeMatrix(_ matrix: [[Double]]) -> Data {
        (try? JSONEncoder().encode(matrix)) ?? Data()
    }

    private func decodeMatrix(_ data: Data?) -> [[Double]]? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode([[Double]].self, from: data)
    }

    private func encodeVector(_ vector: [Double]) -> Data {
        (try? JSONEncoder().encode(vector)) ?? Data()
    }

    private func decodeVector(_ data: Data?) -> [Double]? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode([Double].self, from: data)
    }

    private func encodeSamples(_ samples: [CalibrationSample]) -> Data {
        (try? JSONEncoder().encode(samples)) ?? Data("[]".utf8)
    }

    private func decodeSamples(_ data: Data?) -> [CalibrationSample] {
        guard let data, !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([CalibrationSample].self, from: data)) ?? []
    }

    private func saveIfNeeded(_ context: NSManagedObjectContext) throws {
        if context.hasChanges {
            try context.save()
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

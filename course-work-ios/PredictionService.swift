import CoreData
import CoreML
import Foundation

struct PredictionDiagnostics {
    let sumVotes: Double
    let sumProbs: Double
    let classLabelFromModel: Int?
    let argmaxClass: Int
    let classLabelMatchesArgmax: Bool
    let missingFeatureCount: Int
    let hasNonFiniteFeature: Bool
}

struct PredictionComputation {
    let predictedClass: Int
    let confidence: Double
    let probabilities: [Int: Double]
    let votes: [Int: Double]
    let featureVector: [String: Double]
    let diagnostics: PredictionDiagnostics
    let isLowConfidence: Bool
}

struct WarmupState {
    let completedWeeks: Int
    let requiredWeeks: Int
}

enum PredictionRunResult {
    case warmup(WarmupState)
    case ready(PredictionComputation)
}

enum PredictionServiceError: LocalizedError {
    case modelNotFound
    case missingClassProbability
    case invalidPredictionOutput

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "CoreML model resource not found in app bundle."
        case .missingClassProbability:
            return "Missing classProbability output in model prediction."
        case .invalidPredictionOutput:
            return "Invalid model output: could not determine predicted class."
        }
    }
}

protocol ModelPredicting {
    func predict(featureProvider: MLFeatureProvider) throws -> MLFeatureProvider
}

struct CoreMLPredictor: ModelPredicting {
    private let model: MLModel

    init(bundle: Bundle = .main) throws {
        if let compiledURL = bundle.url(forResource: "BerkaSpendBucketRFCompiled", withExtension: "mlmodelc") {
            model = try MLModel(contentsOf: compiledURL)
            return
        }

        if let packageURL = bundle.url(forResource: "BerkaSpendBucketRF", withExtension: "mlpackage") {
            model = try MLModel(contentsOf: packageURL)
            return
        }

        throw PredictionServiceError.modelNotFound
    }

    func predict(featureProvider: MLFeatureProvider) throws -> MLFeatureProvider {
        try model.prediction(from: featureProvider)
    }
}

final class PredictionService {
    private let contract: FeatureContract
    private let thresholds: BucketThresholds
    private let featureBuilder: FeatureBuilder
    private let predictor: ModelPredicting
    private let classOrder = [0, 1, 2, 3]
    private let confidenceThreshold: Double

    init(
        contract: FeatureContract,
        thresholds: BucketThresholds,
        predictor: ModelPredicting,
        confidenceThresholdFallback: Double = 0.5
    ) {
        self.contract = contract
        self.thresholds = thresholds
        self.predictor = predictor
        featureBuilder = FeatureBuilder(contract: contract, thresholds: thresholds)
        confidenceThreshold = contract.guardrails.confidenceThreshold ?? confidenceThresholdFallback
    }

    convenience init(contracts: AppContractStore, bundle: Bundle = .main) throws {
        try self.init(
            contract: contracts.featureContract,
            thresholds: contracts.thresholds,
            predictor: CoreMLPredictor(bundle: bundle)
        )
    }

    func runPrediction(for history: [WeeklyRecord]) throws -> PredictionRunResult {
        let inputs = history.compactMap(\.stage2FeatureInput).sorted { $0.weekStart < $1.weekStart }
        return try runPrediction(for: inputs)
    }

    func runPrediction(for history: [WeeklyFeatureInput]) throws -> PredictionRunResult {
        let warmupWeeks = contract.guardrails.warmupWeeks
        if history.count < warmupWeeks {
            return .warmup(.init(completedWeeks: history.count, requiredWeeks: warmupWeeks))
        }

        let features = try featureBuilder.buildFeatureVector(from: history)
        return .ready(try predict(featureVector: features))
    }

    func predict(featureVector: [String: Double]) throws -> PredictionComputation {
        let provider = try MLDictionaryFeatureProvider(dictionary: featureVector)
        let output = try predictor.predict(featureProvider: provider)

        let classLabel = extractClassLabel(from: output)
        guard let voteMap = extractClassVotes(from: output) else {
            throw PredictionServiceError.missingClassProbability
        }

        let normalizedVotes = normalized(voteMap: voteMap)
        let probabilities = normalizedVotes.probabilities
        let votes = normalizedVotes.votes

        guard let argmaxClass = classOrder.max(by: { (probabilities[$0] ?? 0.0) < (probabilities[$1] ?? 0.0) }) else {
            throw PredictionServiceError.invalidPredictionOutput
        }

        let confidence = probabilities[argmaxClass] ?? 0.0
        let missingFeatureCount = contract.featureOrder.filter { featureVector[$0] == nil }.count
        let hasNonFiniteFeature = featureVector.values.contains(where: { !$0.isFinite })

        let diagnostics = PredictionDiagnostics(
            sumVotes: votes.values.reduce(0, +),
            sumProbs: probabilities.values.reduce(0, +),
            classLabelFromModel: classLabel,
            argmaxClass: argmaxClass,
            classLabelMatchesArgmax: classLabel == argmaxClass,
            missingFeatureCount: missingFeatureCount,
            hasNonFiniteFeature: hasNonFiniteFeature
        )

        let computation = PredictionComputation(
            predictedClass: argmaxClass,
            confidence: confidence,
            probabilities: probabilities,
            votes: votes,
            featureVector: featureVector,
            diagnostics: diagnostics,
            isLowConfidence: confidence < confidenceThreshold
        )
        return computation
    }

    @discardableResult
    func upsertPredictionSnapshot(
        for history: [WeeklyRecord],
        in context: NSManagedObjectContext,
        sourceMode: String = "rf"
    ) throws -> PredictionRunResult {
        let runResult = try runPrediction(for: history)

        guard case let .ready(computation) = runResult else {
            return runResult
        }

        guard let latestInput = history.compactMap(\.stage2FeatureInput).max(by: { $0.weekStart < $1.weekStart }) else {
            return runResult
        }

        let request: NSFetchRequest<PredictionSnapshot> = PredictionSnapshot.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "weekIndex == %d", latestInput.weekIndex)

        let snapshot = (try context.fetch(request).first) ?? PredictionSnapshot(context: context)
        snapshot.id = snapshot.id ?? UUID()
        snapshot.weekStart = latestInput.weekStart
        snapshot.weekIndex = NSNumber(value: latestInput.weekIndex)
        snapshot.createdAt = Date()
        snapshot.modelVersion = "full_spend_tuned"
        snapshot.sourceMode = sourceMode
        snapshot.predictedClass = NSNumber(value: computation.predictedClass)
        snapshot.confidence = NSNumber(value: computation.confidence)
        snapshot.probability0 = NSNumber(value: computation.probabilities[0] ?? 0.0)
        snapshot.probability1 = NSNumber(value: computation.probabilities[1] ?? 0.0)
        snapshot.probability2 = NSNumber(value: computation.probabilities[2] ?? 0.0)
        snapshot.probability3 = NSNumber(value: computation.probabilities[3] ?? 0.0)
        snapshot.sumVotes = NSNumber(value: computation.diagnostics.sumVotes)
        snapshot.sumProbs = NSNumber(value: computation.diagnostics.sumProbs)
        snapshot.isLowConfidence = computation.isLowConfidence
        snapshot.featureVectorData = (try? JSONEncoder().encode(computation.featureVector)) ?? Data()
        snapshot.notes = debugNotes(for: computation.diagnostics)

        if context.hasChanges {
            try context.save()
        }

        return runResult
    }

    private func debugNotes(for diagnostics: PredictionDiagnostics) -> String {
        [
            "sumVotes=\(diagnostics.sumVotes)",
            "sumProbs=\(diagnostics.sumProbs)",
            "modelClassLabel=\(diagnostics.classLabelFromModel.map(String.init) ?? "nil")",
            "argmaxClass=\(diagnostics.argmaxClass)",
            "classLabelMatchesArgmax=\(diagnostics.classLabelMatchesArgmax)",
            "missingFeatures=\(diagnostics.missingFeatureCount)",
            "hasNonFiniteFeature=\(diagnostics.hasNonFiniteFeature)"
        ].joined(separator: "; ")
    }

    private func extractClassVotes(from output: MLFeatureProvider) -> [String: Double]? {
        guard let value = output.featureValue(for: "classProbability") else {
            for name in output.featureNames {
                guard let candidate = output.featureValue(for: name), candidate.type == .dictionary else { continue }
                return mapDictionary(candidate.dictionaryValue)
            }
            return nil
        }

        guard value.type == .dictionary else { return nil }
        return mapDictionary(value.dictionaryValue)
    }

    private func mapDictionary(_ dict: [AnyHashable: NSNumber]) -> [String: Double] {
        var result: [String: Double] = [:]
        for (key, value) in dict {
            result[String(describing: key)] = value.doubleValue
        }
        return result
    }

    private func extractClassLabel(from output: MLFeatureProvider) -> Int? {
        if let classLabel = output.featureValue(for: "classLabel") {
            if classLabel.type == .int64 {
                return Int(classLabel.int64Value)
            }
            if classLabel.type == .string {
                return Int(classLabel.stringValue)
            }
        }

        for name in output.featureNames {
            guard let feature = output.featureValue(for: name) else { continue }
            if feature.type == .int64 {
                return Int(feature.int64Value)
            }
            if feature.type == .string {
                return Int(feature.stringValue)
            }
        }
        return nil
    }

    private func normalized(voteMap: [String: Double]) -> (probabilities: [Int: Double], votes: [Int: Double]) {
        var votesByClass: [Int: Double] = [:]
        for classId in classOrder {
            let key = String(classId)
            votesByClass[classId] = voteMap[key] ?? 0.0
        }

        let sumVotes = votesByClass.values.reduce(0, +)
        let denominator = sumVotes > 0 ? sumVotes : 1.0

        var probabilities: [Int: Double] = [:]
        for classId in classOrder {
            probabilities[classId] = (votesByClass[classId] ?? 0.0) / denominator
        }

        return (probabilities, votesByClass)
    }
}

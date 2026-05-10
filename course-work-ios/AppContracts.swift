import Foundation

private final class BundleProbe {}

struct FeatureContract: Codable {
    struct Guardrails: Codable, Equatable {
        let warmupWeeks: Int
        let alphaAfterWarmup: Double
        let confidenceThreshold: Double?

        enum CodingKeys: String, CodingKey {
            case warmupWeeks = "warmup_weeks"
            case alphaAfterWarmup = "alpha_after_warmup"
            case confidenceThreshold = "confidence_threshold"
        }
    }

    let featureOrder: [String]
    let featureTypes: [String: String]
    let labelMapping: [String: String]
    let guardrails: Guardrails

    enum CodingKeys: String, CodingKey {
        case featureOrder = "feature_order"
        case featureTypes = "feature_types"
        case labelMapping = "label_mapping"
        case guardrails
    }

    static let fallback = FeatureContract(
        featureOrder: [],
        featureTypes: [:],
        labelMapping: [:],
        guardrails: .init(warmupWeeks: 0, alphaAfterWarmup: 0, confidenceThreshold: nil)
    )
}

struct BucketThresholds: Codable, Equatable {
    let q25Spend: Double
    let q75Spend: Double
    let q25Net: Double
    let q75Net: Double
    let eps: Double
    let weeksSinceCap: Int
    let ratioClipMax: Double

    enum CodingKeys: String, CodingKey {
        case q25Spend = "q25_spend"
        case q75Spend = "q75_spend"
        case q25Net = "q25_net"
        case q75Net = "q75_net"
        case eps
        case weeksSinceCap = "weeks_since_cap"
        case ratioClipMax = "ratio_clip_max"
    }

    static let fallback = BucketThresholds(
        q25Spend: 0,
        q75Spend: 0,
        q25Net: 0,
        q75Net: 0,
        eps: 0.000001,
        weeksSinceCap: 52,
        ratioClipMax: 10
    )
}

struct ReleaseManifest: Codable, Equatable {
    struct Metrics: Codable, Equatable {
        let rfF1Macro: Double
        let rfBalancedAccuracy: Double
        let stabilityRelativeDrop: Double
        let relativeGainVsPersistence: Double

        enum CodingKeys: String, CodingKey {
            case rfF1Macro = "rf_f1_macro"
            case rfBalancedAccuracy = "rf_balanced_accuracy"
            case stabilityRelativeDrop = "stability_relative_drop"
            case relativeGainVsPersistence = "relative_gain_vs_persistence"
        }
    }

    let executionTimestamp: String
    let selectedPrefix: String
    let target: String
    let runMode: String
    let featureCount: Int
    let metrics: Metrics
    let selectedModelResource: String
    let featurePassportResource: String
    let goldenInferenceSetResource: String

    enum CodingKeys: String, CodingKey {
        case executionTimestamp = "execution_timestamp"
        case selectedPrefix = "selected_prefix"
        case target
        case runMode = "run_mode"
        case featureCount = "feature_count"
        case metrics
        case selectedModelResource = "selected_model_resource"
        case featurePassportResource = "feature_passport_resource"
        case goldenInferenceSetResource = "golden_inference_set_resource"
    }

    static let fallback = ReleaseManifest(
        executionTimestamp: "",
        selectedPrefix: "",
        target: "",
        runMode: "",
        featureCount: 0,
        metrics: .init(rfF1Macro: 0, rfBalancedAccuracy: 0, stabilityRelativeDrop: 0, relativeGainVsPersistence: 0),
        selectedModelResource: "",
        featurePassportResource: "",
        goldenInferenceSetResource: ""
    )
}

struct AppContractStore {
    let featureContract: FeatureContract
    let thresholds: BucketThresholds
    let releaseManifest: ReleaseManifest
    let featurePassportText: String
    let featurePassportLineCount: Int?
    let goldenInferenceSetRecordCount: Int?
    let modelResourceExists: Bool
    let featurePassportExists: Bool
    let releaseManifestExists: Bool
    let goldenInferenceSetExists: Bool
    let issues: [String]

    init(bundle: Bundle = Bundle(for: BundleProbe.self)) {
        var issues: [String] = []

        featureContract = Self.loadDecodable(
            name: "feature_contract",
            extension: "json",
            bundle: bundle,
            fallback: FeatureContract.fallback,
            issues: &issues
        )
        thresholds = Self.loadDecodable(
            name: "thresholds",
            extension: "json",
            bundle: bundle,
            fallback: BucketThresholds.fallback,
            issues: &issues
        )
        releaseManifest = Self.loadDecodable(
            name: "release_manifest",
            extension: "json",
            bundle: bundle,
            fallback: ReleaseManifest.fallback,
            issues: &issues
        )

        let passport = Self.loadText(
            name: "berka_feature_passport_spend_bucket",
            extension: "md",
            bundle: bundle,
            issues: &issues
        )
        featurePassportText = passport ?? ""
        featurePassportLineCount = passport.map { $0.split { $0.isNewline }.count }

        let goldenData = Self.loadData(
            name: "golden_inference_set_full_spend_tuned",
            extension: "json",
            bundle: bundle,
            issues: &issues
        )
        goldenInferenceSetRecordCount = goldenData.flatMap(Self.goldenRecordCount)

        modelResourceExists = bundle.url(forResource: "BerkaSpendBucketRF", withExtension: "mlpackage") != nil
        featurePassportExists = passport != nil
        releaseManifestExists = bundle.url(forResource: "release_manifest", withExtension: "json") != nil
        goldenInferenceSetExists = goldenData != nil

        if !modelResourceExists {
            issues.append("Missing BerkaSpendBucketRF.mlpackage")
        }
        if !featurePassportExists {
            issues.append("Missing berka_feature_passport_spend_bucket.md")
        }
        if !releaseManifestExists {
            issues.append("Missing release_manifest.json")
        }
        if !goldenInferenceSetExists {
            issues.append("Missing golden_inference_set_full_spend_tuned.json")
        }

        self.issues = issues
    }

    var isComplete: Bool {
        issues.isEmpty
    }

    private static func loadDecodable<T: Decodable>(
        name: String,
        extension ext: String,
        bundle: Bundle,
        fallback: T,
        issues: inout [String]
    ) -> T {
        guard let data = loadData(name: name, extension: ext, bundle: bundle, issues: &issues) else {
            return fallback
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            issues.append("Failed to decode \(name).\(ext): \(error.localizedDescription)")
            return fallback
        }
    }

    private static func loadText(
        name: String,
        extension ext: String,
        bundle: Bundle,
        issues: inout [String]
    ) -> String? {
        guard let data = loadData(name: name, extension: ext, bundle: bundle, issues: &issues) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func loadData(
        name: String,
        extension ext: String,
        bundle: Bundle,
        issues: inout [String]
    ) -> Data? {
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            issues.append("Missing resource \(name).\(ext)")
            return nil
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            issues.append("Failed to load \(name).\(ext): \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated private static func goldenRecordCount(from data: Data) -> Int? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data),
            let payload = json as? [String: Any],
            let records = payload["records"] as? [Any]
        else {
            return nil
        }
        return records.count
    }
}

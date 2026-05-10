# iOS MVP Handoff for Personal Finance Forecasting

This document is the working handoff for future LLM agents on the iOS coursework app. It captures the project goal, the non-obvious technical constraints from the ML repo, the implementation plan, and the current progress so far.

## 1) Project Goal

Build a small, local-only iOS app for the coursework topic **"Adaptive personal finance forecasting"**.

The app should:
- predict the next-month spend bucket on device using the existing RF CoreML model,
- present predictions honestly with probabilities and confidence,
- collect weekly user data locally,
- later support an on-device softmax calibrator that adapts to the user,
- remain simple enough for a course demo, not a full production fintech product.

## 2) Important ML / Model Context

The ML side of the project lives in:
- `/Users/vsevolodburtik/CourseWork/pythonProject`

The iOS app must respect these facts:

### 2.1 Model output must be normalized
- CoreML `classProbability` from the RF model is not a true probability distribution.
- It is a vote count dictionary.
- The app must normalize it before using it for confidence, blending, or calibration:
  - `p[c] = votes[c] / sumVotes`
- For the current release candidate, `sumVotes` is expected to be around `420` because the forest uses `420` estimators.

### 2.2 Feature contract is strict
The feature contract is the source of truth for:
- feature order,
- feature names,
- label mapping,
- guardrails.

Relevant ML repo files:
- `/Users/vsevolodburtik/CourseWork/pythonProject/docs/berka_feature_passport_spend_bucket.md`
- `/Users/vsevolodburtik/CourseWork/pythonProject/artifacts/ios_bundle/feature_contract.json`

The contract has:
- `31` features,
- `warmup_weeks = 8`,
- `alpha_after_warmup = 0.2`,
- label mapping for `bucket_0..bucket_3`.

### 2.3 Thresholds must be frozen and train-derived
Ground-truth bucketization on iOS must use the same thresholds as training.

The exact values already exist in the ML repo:
- `/Users/vsevolodburtik/CourseWork/pythonProject/step1_berka_weekly_builder/outputs/classification/metadata.json`

Current values:
- `q25_spend_train = 14.6`
- `q75_spend_train = 7028.0`
- `q25_net_train = -4100.0`
- `q75_net_train = 3401.0`

The iOS app should read these values from a bundled artifact, not recompute them.

### 2.4 Calibrator contract
Relevant ML repo files:
- `/Users/vsevolodburtik/CourseWork/pythonProject/on_device_calibrator/calibrator.py`
- `/Users/vsevolodburtik/CourseWork/pythonProject/on_device_calibrator/run_personalization_simulation.py`
- `/Users/vsevolodburtik/CourseWork/pythonProject/artifacts/ios_bundle/SoftmaxCalibratorReference.swift`
- `/Users/vsevolodburtik/CourseWork/pythonProject/reports/on_device_calibrator/calibrator_simulation_report.md`

Calibrator defaults:
- warmup `8`
- update cadence `2` weeks
- history cap `20`
- learning rate `0.05`
- L2 `0.001`
- gradient clip `5.0`
- SGD epochs `20`
- blend alpha `0.2`

## 3) Current iOS Repo State

Current iOS repo:
- `/Users/vsevolodburtik/course-work-ios`

Key files already present or added:
- `/Users/vsevolodburtik/course-work-ios/course-work-ios/AppContracts.swift`
- `/Users/vsevolodburtik/course-work-ios/course-work-ios/ContentView.swift`
- `/Users/vsevolodburtik/course-work-ios/course-work-ios/Persistence.swift`
- `/Users/vsevolodburtik/course-work-ios/course-work-ios/course_work_iosApp.swift`
- `/Users/vsevolodburtik/course-work-ios/course-work-ios/FeatureBuilder.swift`
- `/Users/vsevolodburtik/course-work-ios/course-work-ios/PredictionService.swift`
- `/Users/vsevolodburtik/course-work-ios/course-work_ios.xcodeproj/project.pbxproj`
- `/Users/vsevolodburtik/course-work-ios/course-work-ios/course_work_ios.xcdatamodeld/course_work_ios.xcdatamodel/contents`
- `/Users/vsevolodburtik/course-work-ios/course-work-iosTests/course_work_iosTests.swift`

Bundle resources already added to the app target:
- `/Users/vsevolodburtik/course-work-ios/course-work-ios/berka_feature_passport_spend_bucket.md`
- `/Users/vsevolodburtik/course-work-ios/course-work-ios/feature_contract.json`
- `/Users/vsevolodburtik/course-work-ios/course-work-ios/thresholds.json`
- `/Users/vsevolodburtik/course-work-ios/course-work-ios/release_manifest.json`
- `/Users/vsevolodburtik/course-work-ios/course-work-ios/golden_inference_set_full_spend_tuned.json`

Model packaging currently works through:
- `/Users/vsevolodburtik/course-work-ios/BerkaSpendBucketRFCompiled.mlmodelc`

The app bundle is set up to copy that compiled model bundle during build.

## 4) What Has Been Implemented So Far

### Stage 1 is complete
Stage 1 was about freezing contracts and local storage.

Done:
- feature contract loaded from bundle,
- thresholds loaded from bundle,
- release manifest loaded from bundle,
- feature passport loaded from bundle,
- golden inference set loaded from bundle,
- CoreData schema replaced with domain entities,
- preview seed data added,
- stage-1 dashboard UI added,
- model packaging fixed so the app bundle can load the compiled CoreML model.

### Model loading issue was resolved
There was an earlier issue where the app showed:
- `Missing BerkaSpendBucketRF.mlpackage`

That was fixed by switching the app to the compiled model bundle:
- `BerkaSpendBucketRFCompiled.mlmodelc`

The built app bundle now contains the compiled model.

### Stage 2 has started
There is now an initial implementation for:
- `FeatureBuilder`
- `PredictionService`

These files are present in the repo and are the basis for:
- exact feature construction,
- RF inference,
- vote normalization,
- warm-up handling,
- prediction snapshot persistence.

## 5) Detailed Plan by Stage

## Stage 1 - Freeze Contracts and Local Storage

Goal:
Create a stable local foundation before any further ML UI or calibration work.

Tasks:
- keep `feature_contract.json` as the source of truth for feature order, label mapping, and guardrails,
- keep `thresholds.json` as the source of truth for spend/net bucket thresholds,
- bundle the provenance files needed for app logic and diagnostics,
- use CoreData with only the needed domain entities,
- keep `UserDefaults` for non-critical UI preferences only.

Expected entities:
- `WeeklyRecord`
- `PredictionSnapshot`
- `CalibrationStateRecord`

## Stage 2 - Prediction Pipeline and Feature Parity

Goal:
Make the RF model work end-to-end on device with correct feature engineering.

Tasks:
- implement `FeatureBuilder` with exact parity to the Python contract,
- reproduce calendar, lag, rolling, frequency, and `weeks_since_*` features,
- sanitize all `NaN` / `Inf` values,
- enforce the `8` week warm-up guardrail,
- implement `PredictionService` that:
  - loads the CoreML model,
  - normalizes vote counts into probabilities,
  - keeps class order `[0, 1, 2, 3]`,
  - calculates confidence,
  - stores diagnostics in `PredictionSnapshot`,
- add unit tests using the golden inference samples.

## Stage 3 - Ground Truth Capture and On-Device Calibrator

Goal:
Add local personalization without a backend.

Tasks:
- add a weekly close flow where the user enters actual outflow,
- convert the raw amount into the true bucket using the frozen thresholds,
- store labeled pairs `(p_rf, y_true, week_idx)` locally,
- port the calibrator math from Python 1:1,
- keep the calibrator state on device,
- use blended inference after warm-up:
  - `p_final = (1 - alpha) * p_rf + alpha * p_cal`
- expose reset / retrain controls in Settings.

## Stage 4 - Screens, Diagnostics, and Verification

Goal:
Turn the technical core into a small usable app.

Planned screens:
- Dashboard
- Add Week
- History
- Settings / Calibration

UI requirements:
- show the most likely bucket,
- show confidence,
- show probability bars,
- show `High spend risk = p(bucket 3)`,
- show low-confidence fallback behavior clearly,
- keep history compact and readable,
- show provenance and debug information in Settings.

Testing requirements:
- unit tests for `FeatureBuilder`,
- unit tests for `PredictionService`,
- unit tests for thresholds and calibrator math,
- one light smoke test is enough,
- do not overinvest in full UI-test coverage unless there is extra time.

## 6) Rules for Future LLM Agents

### Do
- treat the ML repo artifacts as the source of truth,
- preserve exact contracts and thresholds,
- keep changes small and easy to validate,
- prefer local, offline behavior,
- maintain honest confidence-aware UX,
- keep diagnostics visible during development.

### Do not
- do not invent thresholds,
- do not approximate the feature contract,
- do not use raw CoreML vote counts as probabilities,
- do not overengineer the app into a production fintech architecture,
- do not add backend dependencies,
- do not hide missing or low-confidence model behavior.

## 7) Current Progress

Overall progress:
- **Stage 1: complete**
- **Stage 2: started**
- **Stage 3: not started**
- **Stage 4: not started**

What is already working:
- app contracts are loaded from local resources,
- CoreData schema is in place,
- preview seed data exists,
- compiled CoreML model is bundled correctly,
- app build succeeds,
- stage-1 dashboard shows bundle and storage diagnostics.

What is in progress:
- feature parity validation,
- RF prediction pipeline implementation,
- final sanity checks for feature vectors and model outputs.

What remains next:
- finish Stage 2,
- then implement Stage 3 calibrator flow,
- then build the final 3-4 screen app experience.


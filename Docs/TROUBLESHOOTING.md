# Troubleshooting

## The app shows only rows and debug data
This is expected for the current Stage 3 MVP.

The project intentionally stops before the final Stage 4 UX, so the app still exposes diagnostic sections. Use:
- `Seed demo data`
- `Add pending week`
- `Save outcome`
- `Retrain now`

## A resource is reported missing
If `AppContractStore` complains about missing resources:
- rebuild the app,
- confirm the bundle contains `Resources/Contracts`,
- confirm the compiled model bundle is copied into the app bundle,
- do not rename the frozen contract files unless the code is updated too.

## Model loading issues
If the app says the model is missing:
- verify that `BerkaSpendBucketRFCompiled.mlmodelc` exists in the built app bundle,
- clean build folder and rebuild,
- make sure the copy script in the project still runs.

## Tests are slow or appear stuck
The project has both fast tests and a separate calibration smoke harness.

Recommended:
- run fast unit tests first,
- run `scripts/run_calibration_smoke.sh --skip-real-coreml` separately,
- avoid running a large parallel test suite on a weak simulator setup.

If the simulator machine starts lagging:
- close extra simulators,
- disable parallel testing,
- run a single test target instead of the full suite.

## `SIGABRT` in tests
This is usually caused by one of these:
- CoreData access on the wrong actor / queue,
- a failing assertion in a long-running smoke-like test,
- test environment not being isolated enough.

What helps:
- keep CoreData tests small,
- use in-memory stores where possible,
- separate smoke harnesses from ordinary unit tests,
- do not keep a single test running for minutes unless it is intentionally a smoke test.

## Calibration does not seem to change anything
Check the following:
- at least 8 labeled weeks exist,
- warm-up is complete,
- the current week was actually closed with a ground-truth amount,
- the calibrator has not been reset,
- retrain was triggered after enough samples accumulated.

## Confidence looks odd
Remember:
- CoreML `classProbability` is a vote-count dictionary,
- it must be normalized,
- confidence is derived from the normalized probabilities, not the raw votes.

## Useful commands
Fast build:
```bash
xcodebuild -scheme course-work-ios -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/course-work-ios-dd CODE_SIGNING_ALLOWED=NO build
```

Calibration smoke harness:
```bash
./scripts/run_calibration_smoke.sh --skip-real-coreml
```

Real CoreML replay smoke:
```bash
./scripts/run_calibration_smoke.sh --real-coreml-replay
```

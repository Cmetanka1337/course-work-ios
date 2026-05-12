#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="course-work-ios"
KEEP_ARTIFACTS=0
RUN_REAL_COREML=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-artifacts)
      KEEP_ARTIFACTS=1
      shift
      ;;
    --skip-real-coreml)
      RUN_REAL_COREML=0
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: scripts/run_calibration_smoke.sh [--keep-artifacts] [--skip-real-coreml]" >&2
      exit 2
      ;;
  esac
done

ARTIFACTS_DIR="$(mktemp -d /private/tmp/calibration-smoke.XXXXXX)"
DERIVED_DATA_PATH="$ARTIFACTS_DIR/DerivedData"
STORE_PATH="$ARTIFACTS_DIR/calibration-smoke.sqlite"
REPORT_PATH="$ARTIFACTS_DIR/calibration-smoke-report.txt"
BUILD_LOG="$ARTIFACTS_DIR/build.log"
TEST_LOG="$ARTIFACTS_DIR/test.log"

cleanup() {
  if [[ "$KEEP_ARTIFACTS" -eq 0 ]]; then
    rm -rf "$ARTIFACTS_DIR"
  else
    echo "Artifacts preserved at: $ARTIFACTS_DIR"
    echo "DerivedData preserved at: $DERIVED_DATA_PATH"
  fi
}
trap cleanup EXIT

DESTINATION_ID="$(
  xcodebuild -scheme "$SCHEME" -showdestinations 2>/dev/null |
    sed -n 's/.*platform:iOS Simulator,.*id:\([^,}]*\).*/\1/p' |
    grep -v placeholder |
    head -n 1
)"

if [[ -n "$DESTINATION_ID" ]]; then
  DESTINATION="platform=iOS Simulator,id=$DESTINATION_ID"
else
  DESTINATION="platform=iOS Simulator"
  echo "No concrete simulator ID found; falling back to: $DESTINATION"
fi

echo "Stage 3 Calibration Smoke Harness"
echo "scheme: $SCHEME"
echo "destination: $DESTINATION"
echo "artifacts: $ARTIFACTS_DIR"
echo ""

echo "Building test bundle..."
set +e
xcodebuild \
  -scheme "$SCHEME" \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing | tee "$BUILD_LOG"
BUILD_STATUS=${pipestatus[1]}
set -e
if [[ "$BUILD_STATUS" -ne 0 ]]; then
  echo "Build-for-testing failed. See: $BUILD_LOG" >&2
  exit "$BUILD_STATUS"
fi

echo ""
echo "Running calibration smoke harness..."
if [[ -n "$DESTINATION_ID" ]]; then
  echo "Booting simulator $DESTINATION_ID for test execution..."
  xcrun simctl boot "$DESTINATION_ID" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$DESTINATION_ID" -b
fi
echo ""
set +e
CALIBRATION_SMOKE_STORE_URL="$STORE_PATH" \
CALIBRATION_SMOKE_REPORT_PATH="$REPORT_PATH" \
CALIBRATION_SMOKE_RUN_REAL_COREML="$RUN_REAL_COREML" \
xcodebuild \
  -scheme "$SCHEME" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -destination-timeout 120 \
  -destination "$DESTINATION" \
  -parallel-testing-enabled NO \
  test-without-building \
  -only-testing:course-work-iosTests/CalibrationSmokeHarnessTests/testStage3CalibrationHistoricalReplaySmoke | tee "$TEST_LOG"
TEST_STATUS=${pipestatus[1]}
set -e

echo ""
echo "Smoke report"
if [[ -f "$REPORT_PATH" ]]; then
  cat "$REPORT_PATH"
else
  echo "Smoke report was not generated."
fi

if [[ "$TEST_STATUS" -ne 0 ]]; then
  echo ""
  echo "Smoke harness failed. See: $TEST_LOG" >&2
  exit "$TEST_STATUS"
fi

echo ""
echo "Smoke harness completed successfully."

# Demo Flow

This is the quickest presentation flow for the coursework app.

## Goal
Show that the app:
- loads the model and contracts correctly,
- produces normalized probabilities,
- stores weekly data locally,
- updates calibration state on device,
- remains understandable even without the final Stage 4 UX.

## Recommended live demo script
### 1. Start on the dashboard
Show:
- the predicted bucket,
- confidence,
- probability bars,
- calibration / warm-up status,
- any diagnostics that confirm the model is loaded.

### 2. Seed demo data
Use `Seed demo data` so the app has a few weeks of history and the screen is not empty.

### 3. Add a pending week
Create one new week that will later be closed with a manual outflow amount.

### 4. Close the week with a known amount
Use a simple amount that maps clearly to a bucket:
- `0.0` -> bucket 0
- `10.0` -> bucket 1
- `500.0` -> bucket 2
- `10000.0` -> bucket 3

### 5. Repeat the loop
Add and close a few more weeks. The fastest useful set is:
- `0.0`
- `10.0`
- `500.0`
- `10000.0`
- repeat one or two values

### 6. Show calibration progress
Point out:
- labeled weeks count,
- whether warm-up is completed,
- whether inference is RF-only or blended,
- whether retrain is available.

### 7. Retrain manually
When enough labeled weeks exist, trigger `Retrain now` and show that calibration state updates locally.

## What to say during the demo
- The model is fully local.
- Raw CoreML votes are normalized before they are used as probabilities.
- The app does not pretend to know the future with certainty; it shows confidence.
- The calibrator learns from weekly ground truth entered on the device.
- The project intentionally stops at Stage 3, so the focus is on correctness and transparency rather than a polished consumer UX.

## Suggested presentation order
1. Project purpose.
2. Model and contract reliability.
3. Local weekly data flow.
4. Calibration loop.
5. Honest probability presentation.
6. Limitations and next steps.

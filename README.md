# Adaptive Personal Finance Forecasting

An iOS coursework project that demonstrates on-device personal finance forecasting with an RF CoreML model and a lightweight on-device calibrator

### Що це за проєкт
Це невеликий локальний iOS-застосунок для курсової на тему **"Адаптивний засіб прогнозування персональних фінансів"**.

Проєкт показує:
- on-device прогнозування наступного bucket витрат;
- нормалізацію CoreML `classProbability` у справжні ймовірності;
- локальне збереження тижневих даних;
- on-device softmax calibrator, який може адаптуватися під користувача;
- чесну подачу результатів через confidence та probability bars.

### Що вже реалізовано
- Stage 1: контракти, thresholds, bundle resources, CoreData schema.
- Stage 2: feature builder, prediction pipeline, normalized probabilities.
- Stage 3: weekly close flow, calibration state, blended inference, reset/retrain controls.
- Демонстраційна діагностична UI-оболонка замість повного production UX.

### Структура репозиторію
```text
course-work-ios/
├── course-work-ios/
│   ├── App/
│   ├── Core/
│   ├── Features/
│   │   └── Stage3/
│   │       ├── ContentView.swift
│   │       ├── ContentView+Components.swift
│   │       ├── ContentView+DerivedState.swift
│   │       ├── ContentView+Sections.swift
│   │       ├── Stage3Formatters.swift
│   │       └── Stage3Section.swift
│   ├── Resources/
│   └── Assets.xcassets/
├── course-work-iosTests/
├── course-work-iosUITests/
├── Docs/
├── scripts/
└── BerkaSpendBucketRFCompiled.mlmodelc/
```

### Як запустити
1. Відкрити `course-work-ios.xcodeproj` у Xcode.
2. Зібрати застосунок на симуляторі.
3. Запустити app і перейти до diagnostic / stage-3 екрана.

### Як протестувати руками
Найшвидший сценарій:
1. Натиснути `Seed demo data`.
2. Додати pending week.
3. Закрити тиждень через `Save outcome`.
4. Повторити кілька разів з різними значеннями:
   - `0.0` -> bucket 0
   - `10.0` -> bucket 1
   - `500.0` -> bucket 2
   - `10000.0` -> bucket 3
5. Подивитися, як змінюються:
   - labeled weeks,
   - calibration status,
   - prediction output,
   - blended vs RF-only режим.

### Тести
Для швидкої перевірки:
- unit tests для логіки та calibrator math;
- calibration smoke harness через `scripts/run_calibration_smoke.sh`.

Рекомендовано запускати smoke окремо від звичайних unit tests:
```bash
./scripts/run_calibration_smoke.sh --skip-real-coreml
```

### Важливі зауваги
- Не змінювати feature order.
- Не змінювати thresholds.
- Не використовувати raw vote counts як probabilities.
- Проєкт зупинено на Stage 3 deliberately: це MVP для демонстрації, а не повний production UX.

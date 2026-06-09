import SwiftUI
import CoreData

@main
struct course_work_iosApp: App {
    let persistenceController: PersistenceController
    let contracts = AppContractStore()

    init() {
        if AppRuntime.isRunningTests {
            persistenceController = PersistenceController(inMemory: true)
        } else {
            persistenceController = .shared
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(contracts: contracts)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}

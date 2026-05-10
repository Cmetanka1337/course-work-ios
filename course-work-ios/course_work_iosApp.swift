import SwiftUI
import CoreData

@main
struct course_work_iosApp: App {
    let persistenceController = PersistenceController.shared
    let contracts = AppContractStore()

    var body: some Scene {
        WindowGroup {
            ContentView(contracts: contracts)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}

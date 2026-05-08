//
//  course_work_iosApp.swift
//  course-work-ios
//
//  Created by Всеволод Буртик on 08.05.2026.
//

import SwiftUI
import CoreData

@main
struct course_work_iosApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}

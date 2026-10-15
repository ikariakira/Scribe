import SwiftUI

@main
struct LectureScribeApp: App {
    @State private var store = LectureStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(store)
        }
    }
}

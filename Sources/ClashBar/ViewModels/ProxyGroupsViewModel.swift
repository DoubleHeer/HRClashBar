import Foundation
import SwiftUI

@MainActor
final class ProxyGroupsViewModel: ObservableObject {
    @Published var currentTab: RootTab = .proxy

    func syncCurrentTab(_ tab: RootTab) {
        self.currentTab = tab
    }

}

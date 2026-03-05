import Foundation

enum LibrarySelection: Hashable {
    case location(UUID)
    case route(UUID)

    var locationID: UUID? {
        if case .location(let id) = self {
            return id
        }
        return nil
    }

    var routeID: UUID? {
        if case .route(let id) = self {
            return id
        }
        return nil
    }
}

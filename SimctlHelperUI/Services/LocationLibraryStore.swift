import Foundation

nonisolated final class LocationLibraryStore {
    static let shared = LocationLibraryStore()

    private let fileManager: FileManager
    private let baseDirectoryURL: URL?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, baseDirectoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.baseDirectoryURL = baseDirectoryURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        self.decoder = JSONDecoder()
    }

    var storageIdentifier: String {
        baseDirectoryURL?.path ?? "shared"
    }

    private var libraryURL: URL {
        let appSupportURL = baseDirectoryURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupportURL
            .appendingPathComponent("SimctlHelperUI", isDirectory: true)
            .appendingPathComponent("location-library.json")
    }

    func load() throws -> LocationLibrary {
        let fileURL = libraryURL
        guard fileManager.fileExists(atPath: fileURL.path) else {
            let defaults = LocationLibrary.default
            try save(defaults)
            return defaults
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(LocationLibrary.self, from: data)
    }

    func decodeLibrary(from data: Data) throws -> LocationLibrary {
        try decoder.decode(LocationLibrary.self, from: data)
    }

    func encodeLibrary(_ library: LocationLibrary) throws -> Data {
        try encoder.encode(library)
    }

    func save(_ library: LocationLibrary) throws {
        let fileURL = libraryURL
        let directoryURL = fileURL.deletingLastPathComponent()

        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        let data = try encodeLibrary(library)
        try data.write(to: fileURL, options: [.atomic])
    }
}

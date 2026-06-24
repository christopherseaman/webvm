import Foundation

/// Preconfigured Headscale networking, baked into the app bundle at stage time
/// (ios/stage.sh writes HeadscaleConfig.json from ios/.network.env). When absent
/// or blank, both values are nil and the app falls back to interactive Tailscale
/// login — so this is non-breaking.
struct NetworkConfig: Decodable {
    let controlUrl: String?
    let authKey: String?

    static let empty = NetworkConfig(controlUrl: nil, authKey: nil)

    var isConfigured: Bool { controlUrl != nil || authKey != nil }

    static func load() -> NetworkConfig {
        guard let url = Bundle.main.url(forResource: "HeadscaleConfig", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(NetworkConfig.self, from: data)
        else { return .empty }
        return NetworkConfig(controlUrl: clean(decoded.controlUrl), authKey: clean(decoded.authKey))
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

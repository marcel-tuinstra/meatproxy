import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FactoryCore

/// An alert worth telling you about: a server or site that went down or warns, a certificate about to expire, or one
/// that is fine again.
public struct AlertEvent: Equatable, Sendable {
    public enum Kind: String, Sendable { case down, warn, recovered }
    /// the server id or the site's address
    public var key: String
    public var name: String
    public var kind: Kind
    public var text: String
    public var at: Date
    public var title: String {
        switch kind {
        case .down: "\(name) is down"
        case .warn: "\(name) needs a look"
        case .recovered: "\(name) is fine again"
        }
    }
}

/// Turns checks into alerts without crying wolf: a bad state must be seen twice in a row before it alerts, it alerts
/// again only when it gets worse (a warning that goes down), and a recovery is told only after an alert.
public final class AlertTracker: @unchecked Sendable {
    private struct Track { var state: ServerState = .ok; var bad = 0; var alerted: ServerState? }
    private var tracks: [String: Track] = [:]
    private let lock = NSLock()
    public static let confirmations = 2
    public init() {}

    public func observe(_ key: String, name: String, state: ServerState, detail: String?, now: Date = Date()) -> AlertEvent? {
        lock.lock(); defer { lock.unlock() }
        var t = tracks[key] ?? Track()
        defer { tracks[key] = t }
        if state == .ok {
            t.bad = 0; t.state = .ok
            guard t.alerted != nil else { return nil }
            t.alerted = nil
            return AlertEvent(key: key, name: name, kind: .recovered, text: detail ?? "All checks pass.", at: now)
        }
        t.bad = t.state == state || t.state != .ok ? t.bad + 1 : 1
        t.state = state
        guard t.bad >= Self.confirmations else { return nil }
        // already told: only a step down (a warning that went down) is news
        if let a = t.alerted, !(a == .warn && state == .down) { return nil }
        t.alerted = state
        return AlertEvent(key: key, name: name, kind: state == .down ? .down : .warn, text: detail ?? "", at: now)
    }

    /// Something that is no longer checked is forgotten (a removed server or site).
    public func forget(except keys: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        tracks = tracks.filter { keys.contains($0.key) }
    }
}

/// One look at a public address: does it answer, and how long its TLS certificate is still valid.
public struct SiteCheck: Equatable, Sendable {
    public var url: String
    public var status: Int?
    public var certDaysLeft: Int?
    public var error: String?
    public var checkedAt: Date
    public static let certWarnDays = 14

    public var state: ServerState {
        if error != nil { return .down }
        if let s = status, !(200..<400).contains(s) { return .down }
        if let d = certDaysLeft, d < Self.certWarnDays { return .warn }
        return .ok
    }
    public var detail: String {
        if let error { return error }
        var parts = [status.map { "HTTP \($0)" } ?? "no answer"]
        if let d = certDaysLeft { parts.append(d < Self.certWarnDays ? "certificate expires in \(d) days" : "certificate \(d) days") }
        return parts.joined(separator: " · ")
    }
}

/// Checks a public address: one GET (redirects followed, 15 s), and the leaf certificate's expiry from the TLS handshake.
public enum SiteProbe {
    public static func check(_ url: String, now: Date = Date()) async -> SiteCheck {
        guard let u = URL(string: url) else { return SiteCheck(url: url, error: "not an address", checkedAt: now) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        #if canImport(Security)
        let catcher = CertCatcher()
        let session = URLSession(configuration: config, delegate: catcher, delegateQueue: nil)
        #else
        // Foundation outside Apple's platforms does not show the server's certificate: the answer is checked, and an
        // invalid certificate still fails the request, but its expiry date stays unknown
        let session = URLSession(configuration: config)
        #endif
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: u); req.httpMethod = "GET"; req.setValue("Meatproxy uptime check", forHTTPHeaderField: "User-Agent")
        do {
            let (_, resp) = try await session.data(for: req)
            #if canImport(Security)
            let days = catcher.notAfter.map { Int(floor($0.timeIntervalSince(now) / 86400)) }
            #else
            let days: Int? = nil
            #endif
            return SiteCheck(url: url, status: (resp as? HTTPURLResponse)?.statusCode, certDaysLeft: days, checkedAt: now)
        } catch {
            return SiteCheck(url: url, error: (error as NSError).localizedDescription, checkedAt: now)
        }
    }

    #if canImport(Security)
    private final class CertCatcher: NSObject, URLSessionDelegate, @unchecked Sendable {
        var notAfter: Date?
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else { return completionHandler(.performDefaultHandling, nil) }
            if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
               let values = SecCertificateCopyValues(leaf, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any],
               let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any], let n = entry[kSecPropertyKeyValue] as? NSNumber {
                notAfter = Date(timeIntervalSinceReferenceDate: n.doubleValue)
            }
            // the system still judges the certificate: an invalid one fails the request as it should
            completionHandler(.performDefaultHandling, nil)
        }
    }
    #endif
}

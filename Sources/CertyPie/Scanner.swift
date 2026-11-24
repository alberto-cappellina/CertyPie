import Foundation
import AppKit
import Security

enum ItemKind: String {
    case certificate = "Certificato"
    case profile = "Provisioning profile"

    var label: String { NSLocalizedString(rawValue == "Certificato" ? "Certificate" : "Provisioning profile", comment: "") }
}

struct ExpiryItem: Identifiable, Hashable {
    let id: String
    let kind: ItemKind
    let name: String
    let detail: String
    let expiry: Date

    /// Whole days from now to expiry (negative if already expired).
    var daysLeft: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
    }
    var isExpired: Bool { expiry <= Date() }
}

enum Scanner {
    static func scan() -> [ExpiryItem] {
        (scanCertificates() + scanProfiles()).sorted { $0.expiry < $1.expiry }
    }

    // MARK: Certificates (signing identities = cert + private key in keychain)

    private static let signingPrefixes = [
        "Apple Development", "Apple Distribution", "iPhone Developer", "iPhone Distribution",
        "Mac Developer", "Developer ID", "3rd Party Mac Developer", "Apple Push Services",
    ]

    static func scanCertificates() -> [ExpiryItem] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity] else { return [] }

        var items: [ExpiryItem] = []
        var seenIDs = Set<String>()
        for identity in identities {
            var certRef: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess, let cert = certRef,
                  let cn = SecCertificateCopySubjectSummary(cert) as String?,
                  signingPrefixes.contains(where: { cn.hasPrefix($0) }),
                  let expiry = notAfter(of: cert) else { continue }
            let serial = (SecCertificateCopySerialNumberData(cert, nil) as Data?)?
                .map { String(format: "%02x", $0) }.joined() ?? UUID().uuidString
            guard seenIDs.insert(serial).inserted else { continue }  // same cert in two keychains
            items.append(ExpiryItem(id: "cert-\(serial)", kind: .certificate, name: cn,
                                    detail: "Keychain", expiry: expiry))
        }
        return items
    }

    private static func notAfter(of cert: SecCertificate) -> Date? {
        let oid = kSecOIDX509V1ValidityNotAfter
        guard let values = SecCertificateCopyValues(cert, [oid] as CFArray, nil) as? [CFString: Any],
              let entry = values[oid] as? [CFString: Any],
              let number = entry[kSecPropertyKeyValue] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: number.doubleValue)
    }

    // MARK: Provisioning profiles

    static var profileDirs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/MobileDevice/Provisioning Profiles"),
            home.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles"),
        ]
    }

    /// Folder Xcode currently uses: the one with profiles, else first existing, else the legacy path.
    static func openProfilesFolder() {
        let fm = FileManager.default
        func count(_ u: URL) -> Int { (try? fm.contentsOfDirectory(atPath: u.path).count) ?? 0 }
        let dir = profileDirs.max(by: { count($0) < count($1) }) ?? profileDirs[0]
        // Only open real folders (never a symlink target that is an app or document).
        let resolved = dir.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue,
              !NSWorkspace.shared.isFilePackage(atPath: resolved.path) else { return }
        NSWorkspace.shared.open(resolved)
    }

    /// Real profiles are a few KB; anything bigger is ignored.
    private static let maxProfileSize = 1_000_000

    static func scanProfiles() -> [ExpiryItem] {
        // Keyed by UUID; on duplicates keep the earliest expiry (a forged copy must not hide a real one).
        var byUUID: [String: ExpiryItem] = [:]
        for dir in profileDirs {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])) ?? []
            for url in files where ["mobileprovision", "provisionprofile"].contains(url.pathExtension) {
                // Skip FIFOs, devices, directories and oversized files.
                let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard rv?.isRegularFile == true, let size = rv?.fileSize, size > 0, size <= maxProfileSize,
                      let plist = decodeProfile(url),
                      let expiry = plist["ExpirationDate"] as? Date else { continue }
                let uuid = (plist["UUID"] as? String) ?? url.lastPathComponent
                let name = (plist["Name"] as? String) ?? url.lastPathComponent
                var detail = (plist["TeamName"] as? String) ?? ""
                if let ents = plist["Entitlements"] as? [String: Any],
                   let appID = ents["application-identifier"] as? String {
                    // strip team prefix "ABCDE12345."
                    let bundle = appID.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? appID
                    detail = detail.isEmpty ? bundle : "\(bundle) · \(detail)"
                }
                let item = ExpiryItem(id: "prof-\(uuid)", kind: .profile, name: name, detail: detail, expiry: expiry)
                if let existing = byUUID[uuid], existing.expiry <= item.expiry { continue }
                byUUID[uuid] = item
            }
        }
        return Array(byUUID.values)
    }

    private static func decodeProfile(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let dec = decoder else { return nil }
        guard !data.isEmpty else { return nil }
        let status: OSStatus = data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(dec, base, buf.count)
        }
        let ok = status == errSecSuccess
        guard ok, CMSDecoderFinalizeMessage(dec) == errSecSuccess else { return nil }
        var content: CFData?
        guard CMSDecoderCopyContent(dec, &content) == errSecSuccess, let c = content else { return nil }
        return (try? PropertyListSerialization.propertyList(from: c as Data, format: nil)) as? [String: Any]
    }
}

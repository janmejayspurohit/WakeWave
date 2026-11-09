// Prints the base64 Ed25519 signature of a file, made with the base64 private key in
// $UPDATE_SIGNING_KEY. Refuses to sign unless that key is one of updatePublicKeys in WakeWave.swift,
// since installed apps would reject the update.
//   UPDATE_SIGNING_KEY=... swift scripts/sign-update.swift WakeWave.dmg > WakeWave.dmg.sig
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let env = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"] ?? ""
guard CommandLine.arguments.count == 2 else { fail("usage: UPDATE_SIGNING_KEY=<base64 key> swift sign-update.swift FILE") }
guard let raw = Data(base64Encoded: env.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    fail("UPDATE_SIGNING_KEY is missing or is not a base64 32-byte Ed25519 private key")
}
let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../WakeWave.swift")
let swift = (try? String(contentsOf: source, encoding: .utf8)) ?? ""
let list = swift.components(separatedBy: "let updatePublicKeys = [").dropFirst().first?.components(separatedBy: "]").first ?? ""
let trusted = list.components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
guard trusted.contains(key.publicKey.rawRepresentation.base64EncodedString()) else {
    fail("UPDATE_SIGNING_KEY does not match any of updatePublicKeys in WakeWave.swift")
}
guard let file = FileManager.default.contents(atPath: CommandLine.arguments[1]) else { fail("cannot read \(CommandLine.arguments[1])") }
print(try key.signature(for: file).base64EncodedString())

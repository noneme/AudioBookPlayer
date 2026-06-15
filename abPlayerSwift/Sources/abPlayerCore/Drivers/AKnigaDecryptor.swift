import Foundation
import JavaScriptCore

public protocol AKnigaDecrypting: Sendable {
    func decrypt(hres: String, securityKey: String) throws -> String?
}

public final class AKnigaDecryptor: AKnigaDecrypting, @unchecked Sendable {
    public enum Error: Swift.Error {
        case scriptNotFound
        case jsContextFailed
        case decryptionFailed
    }

    public init() {}

    public func decrypt(hres: String, securityKey: String) throws -> String? {
        guard let url = Bundle.module.url(forResource: "akniga_decrypt", withExtension: "js") else {
            throw Error.scriptNotFound
        }
        let script = try String(contentsOf: url, encoding: .utf8)

        guard let context = JSContext() else {
            throw Error.jsContextFailed
        }

        context.exceptionHandler = { _, exception in
            if let exception {
                NSLog("AKnigaDecryptor JS exception: \(exception)")
            }
        }

        context.setObject(securityKey, forKeyedSubscript: "LIVESTREET_SECURITY_KEY" as NSString)
        context.evaluateScript(script)

        guard let plh = context.objectForKeyedSubscript("plh") else {
            throw Error.decryptionFailed
        }

        let output = plh.invokeMethod("getHres", withArguments: [hres])
        if output?.isNull == true || output?.isUndefined == true {
            return nil
        }
        return output?.toString()
    }
}

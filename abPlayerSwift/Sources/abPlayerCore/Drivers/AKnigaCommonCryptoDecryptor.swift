import CommonCrypto
import Foundation

public final class AKnigaCommonCryptoDecryptor: AKnigaDecrypting, @unchecked Sendable {
    public init() {}

    public func decrypt(hres: String, securityKey: String) throws -> String? {
        if let value = decryptWithPrimaryPassword(hres) {
            return value
        }
        return decryptWithFallbackPassword(hres)
    }

    private func decryptWithPrimaryPassword(_ hres: String) -> String? {
        decrypt(hres: hres, password: primaryPassword())
    }

    private func decryptWithFallbackPassword(_ hres: String) -> String? {
        decrypt(hres: hres, password: "EKxtcg46V")
    }

    private func decrypt(hres: String, password: String) -> String? {
        guard let data = hres.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let ctBase64 = json["ct"],
              let ciphertext = Data(base64Encoded: ctBase64),
              let saltHex = json["s"]
        else {
            return nil
        }

        let salt = hexToBytes(saltHex)
        guard salt.count == 8 else { return nil }

        let (key, iv) = evpBytesToKey(password: Array(password.utf8), salt: salt, keyLen: 32, ivLen: 16)
        let finalIV: [UInt8]
        if let ivHex = json["iv"] {
            finalIV = hexToBytes(ivHex)
        } else {
            finalIV = iv
        }

        guard let plaintext = aesDecrypt(data: Array(ciphertext), key: key, iv: finalIV) else {
            return nil
        }

        return String(bytes: plaintext, encoding: .utf8)
    }

    private func primaryPassword() -> String {
        let base = "ymXEKzvUkuo5G0"
        let piStr = String("\(Double.pi)".prefix(18))
        let evenMap: [Int: Character] = [0: "A", 2: "B", 4: "C", 6: "D", 8: "E"]

        var password = base
        for ch in piStr {
            if let digit = ch.wholeNumberValue {
                if digit % 2 == 0 {
                    password.append(evenMap[digit]!)
                } else {
                    password.append(String(digit))
                }
            } else {
                password.append(ch)
            }
        }
        return password
    }

    private func evpBytesToKey(password: [UInt8], salt: [UInt8], keyLen: Int, ivLen: Int) -> ([UInt8], [UInt8]) {
        var derived: [UInt8] = []
        var block: [UInt8] = []
        let total = keyLen + ivLen

        while derived.count < total {
            let input = block + password + salt
            block = md5(input)
            derived.append(contentsOf: block)
        }

        let key = Array(derived[0 ..< keyLen])
        let iv = Array(derived[keyLen ..< keyLen + ivLen])
        return (key, iv)
    }

    private func md5(_ input: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        input.withUnsafeBufferPointer { ptr in
            _ = CC_MD5(ptr.baseAddress, CC_LONG(input.count), &digest)
        }
        return digest
    }

    private func aesDecrypt(data: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var outputCount = 0

        let status = key.withUnsafeBufferPointer { keyPtr in
            iv.withUnsafeBufferPointer { ivPtr in
                data.withUnsafeBufferPointer { dataPtr in
                    buffer.withUnsafeMutableBufferPointer { outPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress,
                            key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress,
                            data.count,
                            outPtr.baseAddress,
                            bufferSize,
                            &outputCount
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return Array(buffer[0 ..< outputCount])
    }

    private func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index ..< next], radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        return bytes
    }
}

public struct AKnigaCompositeDecryptor: AKnigaDecrypting, Sendable {
    private let primary: AKnigaDecrypting
    private let fallback: AKnigaDecrypting

    public init(
        primary: AKnigaDecrypting = AKnigaDecryptor(),
        fallback: AKnigaDecrypting = AKnigaCommonCryptoDecryptor()
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    public func decrypt(hres: String, securityKey: String) throws -> String? {
        if let first = try? primary.decrypt(hres: hres, securityKey: securityKey) {
            return first
        }
        return try fallback.decrypt(hres: hres, securityKey: securityKey)
    }
}

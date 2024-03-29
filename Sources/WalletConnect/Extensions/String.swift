// 

import Foundation

extension String {
    func toHexEncodedString(uppercase: Bool = true, prefix: String = "", separator: String = "") -> String {
        return unicodeScalars.map { prefix + .init($0.value, radix: 16, uppercase: uppercase) } .joined(separator: separator)
    }
}

extension String: GenericPasswordConvertible {
    
    init<D>(rawRepresentation data: D) throws where D : ContiguousBytes {
        let bytes = data.withUnsafeBytes { Data(Array($0)) }
        guard let string = String(data: bytes, encoding: .utf8) else {
            fatalError() // FIXME: Throw error
        }
        self = string
    }
    
    var rawRepresentation: Data {
        self.data(using: .utf8) ?? Data()
    }
}

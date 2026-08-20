import Foundation

/// 서버와 주고받는 표현을 한 곳에 모아 둔다.
///
/// `Date` 를 Swift 기본 `Codable` 에 맡기면 **2001-01-01 기준 초**라는 숫자가 나간다.
/// 다른 언어에서 온 서버 코드가 그 숫자를 Unix epoch 로 읽거나 쓰면 값이 어긋나는데,
/// 타입이 맞으니 에러 없이 통과한다. 그래서 숫자 대신 ISO8601 문자열로 못박는다.
/// 와이어 위에서 사람이 읽을 수 있으면 애초에 헷갈릴 일이 없다.
enum HomecomingWire {

    static func string(from date: Date) -> String {
        plain.string(from: date)
    }

    /// 소수점 초가 있든 없든 받는다. 보내는 쪽 언어마다 기본값이 다르다.
    static func date(from string: String) -> Date? {
        plain.date(from: string) ?? fractional.date(from: string)
    }

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - 디코딩 보조

extension KeyedDecodingContainer {

    /// ISO8601 문자열을 `Date` 로. 형식이 어긋나면 어느 키에서 틀렸는지 남기고 던진다.
    func decodeWireDate(forKey key: Key) throws -> Date {
        let raw = try decode(String.self, forKey: key)
        guard let date = HomecomingWire.date(from: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "ISO8601 형식이 아닙니다: \(raw)"
            )
        }
        return date
    }

    func decodeWireDateIfPresent(forKey key: Key) throws -> Date? {
        guard let raw = try decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let date = HomecomingWire.date(from: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "ISO8601 형식이 아닙니다: \(raw)"
            )
        }
        return date
    }
}

extension KeyedEncodingContainer {

    mutating func encodeWire(_ date: Date, forKey key: Key) throws {
        try encode(HomecomingWire.string(from: date), forKey: key)
    }

    mutating func encodeWireIfPresent(_ date: Date?, forKey key: Key) throws {
        guard let date else { return }
        try encode(HomecomingWire.string(from: date), forKey: key)
    }
}

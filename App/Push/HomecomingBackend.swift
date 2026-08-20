import ActivityKit
import Foundation

/// 서버에 토큰을 올리는 통로.
///
/// 앱이 서버에 주는 것은 토큰뿐이고, 갱신을 실제로 쏘는 쪽은 서버다.
/// 앱이 잠들거나 종료돼도 Live Activity 가 계속 살아 있으려면 이 경로가 있어야 한다.
protocol HomecomingBackend: Sendable {

    /// APNs 기기 토큰. 일반 푸시용.
    func register(deviceToken: Data) async throws

    /// push-to-start 토큰. 이걸 들고 있으면 서버가 **앱 없이** 액티비티를 시작시킬 수 있다.
    /// 가족 기기에 귀가 알림을 띄우는 건 전적으로 이 토큰에 달려 있다.
    func register(pushToStartToken: Data) async throws

    /// 특정 액티비티의 갱신 토큰. 액티비티마다 다르고, 도중에 재발급될 수 있다.
    func register(activityID: String, updateToken: Data, sessionID: String?) async throws

    /// 액티비티가 끝났음을 알린다. 서버가 죽은 토큰에 계속 쏘지 않도록.
    func unregister(activityID: String) async throws
}

// MARK: - 실제 서버

struct RemoteHomecomingBackend: HomecomingBackend {

    let baseURL: URL
    var session: URLSession = .shared

    /// 사용자를 식별하는 값. 실서비스에서는 로그인 토큰으로 대체된다.
    var auth: HomecomingAuth

    func register(deviceToken: Data) async throws {
        try await post("push/device", ["deviceToken": deviceToken.hexString])
    }

    func register(pushToStartToken: Data) async throws {
        try await post("push/start-token", ["token": pushToStartToken.hexString])
    }

    func register(activityID: String, updateToken: Data, sessionID: String?) async throws {
        try await post("push/activity", [
            "activityId": activityID,
            "token": updateToken.hexString,
            "sessionId": sessionID ?? ""
        ])
    }

    func unregister(activityID: String) async throws {
        try await post("push/activity/end", ["activityId": activityID])
    }

    private func post(_ path: String, _ body: [String: String]) async throws {
        // 인증은 `auth.send` 가 붙인다. 여기서 직접 붙이지 않는다 —
        // 예전에 이 함수만 그 한 줄이 빠져 있어서 푸시 토큰 등록이 전부 401 이었다.
        let (_, http) = try await auth.send(baseURL: baseURL, session: session) {
            var request = URLRequest(url: baseURL.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ETAError.badResponse(http.statusCode)
        }
    }
}

// MARK: - 서버가 아직 없을 때

/// 토큰을 콘솔에 찍기만 한다.
/// 서버 붙이기 전에 토큰이 제대로 나오는지 확인하고, 그 값으로 APNs 를 손으로 찔러 보는 용도.
struct ConsoleHomecomingBackend: HomecomingBackend {

    func register(deviceToken: Data) async throws {
        print("[귀가마중] APNs device token: \(deviceToken.hexString)")
    }

    func register(pushToStartToken: Data) async throws {
        print("[귀가마중] push-to-start token: \(pushToStartToken.hexString)")
    }

    func register(activityID: String, updateToken: Data, sessionID: String?) async throws {
        print("[귀가마중] activity \(activityID) (세션 \(sessionID ?? "-")) update token: \(updateToken.hexString)")
    }

    func unregister(activityID: String) async throws {
        print("[귀가마중] activity \(activityID) 종료")
    }
}

// MARK: - 보조

extension Data {
    /// APNs 토큰은 16진 문자열로 주고받는다.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// 저장해 둔 토큰을 다시 올릴 때 쓴다.
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

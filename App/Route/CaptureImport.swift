import CoreLocation
import Foundation
import Vision

/// 길찾기 앱 캡처를 읽어 경로 구간을 만든다.
///
/// **경로 하나를 만드는 데 입력이 25번이었다.** 대중교통 앱은 그 값을 이미 화면에
/// 다 갖고 있다 — 정류장 이름·기둥번호·노선번호·구간 시간. 그걸 옮겨 적는 일을
/// 없애는 것이 이 타입이다.
///
/// **글자 읽기는 폰에서 끝낸다.** 길찾기 캡처는 집 주소가 든 이미지다. 이미지를
/// 밖으로 보내는 설계는 이 저장소의 결과 안 맞는다.
///
/// **문법 풀이는 서버가 한다.** 길찾기 앱이 화면을 바꾸면 문법이 깨지는데, 서버면
/// 배포 한 번이고 앱이면 재설치다. 서버 시험 234개가 그 문법을 재고 있다.
/// 올리기 전에 **주소 꼴 줄은 뺀다** — 출발지 주소는 화면에만 쓰인다.
enum CaptureImport {

    /// 캡처에서 읽어 낸 것.
    struct Result {
        /// 편집기에 그대로 넣을 구간.
        var steps: [RouteTracer.Step]
        /// 사람에게 알려야 할 것. 못 찾은 정류장, 안 이어지는 장, 어긋난 총 시간.
        var notes: [String]
        /// 캡처의 출발지 주소. **좌표로 안 바꾼다** — 글자로만 보여 준다.
        ///
        /// 재 봤다(2026-08-28): `CLGeocoder` 는 도로명 주소에도
        /// `kCLErrorDomain 8` 이고, `MKLocalSearch` 는 근처 가게를 준다
        /// (`국회의사당`·`KB국민은행`·`Hyundai Card Building`). 2026-08-20 에
        /// 그렇게 고른 GS25 가 가족 잠금화면에 `GS25까지 9분` 으로 떴다.
        var originHint: String?

        /// 좌표를 못 채운 이동 구간 수. 요약 띠가 이 수를 적는다.
        ///
        /// 마지막 구간은 세지 않는다 — 도착지는 집이고 편집기가 채운다.
        var unresolved: Int {
            steps.dropLast().filter { $0.mode.moves && $0.to == nil }.count
        }
    }

    enum Failure: LocalizedError {
        case noText
        case unavailable

        var errorDescription: String? {
            switch self {
            case .noText:
                return "캡처에서 글자를 못 읽었습니다. 구간 상세 화면인지 확인해 주세요."
            case .unavailable:
                return "서버가 연결되지 않아 캡처를 풀 수 없습니다."
            }
        }
    }

    /// 캡처 여러 장을 읽어 구간을 만든다. `images` 는 사람이 고른 순서다.
    static func read(images: [Data], using store: RouteStore) async throws -> Result {
        var pages: [[String]] = []
        var origin: String?
        for data in images {
            let lines = await recognize(data)
            if origin == nil { origin = lines.first(where: isAddress) }
            // **주소 줄은 안 올린다.** 서버가 못 걸러도 안전하도록 서버 쪽에도
            // 같은 줄을 버리는 규칙이 있지만, 아예 안 보내는 것이 낫다.
            pages.append(lines.filter { !isAddress($0) })
        }
        guard pages.contains(where: { !$0.isEmpty }) else { throw Failure.noText }

        let parsed = try await store.parseCapture(pages: pages)
        return Result(steps: parsed.steps.map(step(from:)),
                      notes: parsed.notes,
                      originHint: origin)
    }

    // MARK: - 글자 읽기

    /// 한 장에서 줄을 **위에서 아래로** 뽑는다.
    ///
    /// `usesLanguageCorrection` 을 끈다. 켜면 `19132`·`6713` 같은 번호를 말로
    /// 고치려 든다 — 기둥번호와 노선번호가 이 기능의 전부라 치명적이다.
    static func recognize(_ data: Data) async -> [String] {
        await withCheckedContinuation { done in
            let request = VNRecognizeTextRequest { request, _ in
                let found = request.results as? [VNRecognizedTextObservation] ?? []
                // 자료 순서는 신뢰할 수 없다. 화면에 보이는 순서로 세운다 —
                // 문법이 "승차 줄 다음 줄이 기둥번호" 처럼 순서에 기댄다.
                let sorted = found.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                done.resume(returning: sorted.compactMap {
                    $0.topCandidates(1).first?.string
                })
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ko-KR", "en-US"]
            request.usesLanguageCorrection = false
            do {
                try VNImageRequestHandler(data: data, options: [:]).perform([request])
            } catch {
                HomecomingLog.push.warning("캡처 글자 읽기 실패: \(error.localizedDescription, privacy: .public)")
                done.resume(returning: [])
            }
        }
    }

    /// 주소로 보이는 줄인지. `서울 ○○구 ○○대로 00-0` · `경기 ○○시 ○○로 00`
    ///
    /// **좁게 잡는다.** 헐겁게 잡으면 정류장 이름 줄이 걸려서 경로가 깨진다 —
    /// `로` 하나만 봐도 되겠다 싶지만 그러면 `…로터리` 가 걸린다. 세 가지가 다
    /// 있어야 주소로 본다.
    ///
    ///     시·도로 시작한다      `서울` · `경기`
    ///     행정구역이 있다        `…구` · `…시` · `…군`
    ///     길 이름과 번지가 있다   `…로` 또는 `…길` + 숫자
    ///
    /// 빼서 잃는 것은 없다 — 이 줄은 문법에 안 쓰인다. 서버에도 같은 줄을
    /// 버리는 규칙이 있어, 여기서 놓쳐도 값이 틀리지는 않는다.
    static func isAddress(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.count >= 8 else { return false }
        let heads = ["서울", "경기", "인천", "부산", "대구", "대전", "광주", "울산",
                     "세종", "강원", "충북", "충남", "전북", "전남", "경북", "경남",
                     "제주"]
        guard heads.contains(where: { text.hasPrefix($0) }),
              text.rangeOfCharacter(from: .decimalDigits) != nil else { return false }

        let words = text.split(separator: " ")
        let hasDistrict = words.dropFirst().contains {
            $0.hasSuffix("구") || $0.hasSuffix("시") || $0.hasSuffix("군")
        }
        let hasRoad = words.contains { $0.hasSuffix("로") || $0.hasSuffix("길") }
        return hasDistrict && hasRoad
    }

    // MARK: - 구간으로

    private static func step(from parsed: ParsedCaptureStep) -> RouteTracer.Step {
        var to: CLLocationCoordinate2D?
        if let lat = parsed.lat, let lon = parsed.lon {
            to = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        let numbers = parsed.busNos ?? []
        return RouteTracer.Step(
            mode: RouteLeg.Mode(rawValue: parsed.mode) ?? .walk,
            toName: parsed.toName,
            to: to,
            // 0분 구간은 편집기가 못 다룬다. 대기가 0으로 나오는 경우가 있다
            // (총 시간이 구간 합보다 적을 때) — 그때는 사람이 채운다.
            minutes: max(0, parsed.minutes),
            busNo: numbers.first,
            busNos: numbers
        )
    }
}

/// 서버가 돌려주는 구간 하나. 와이어 모양이다.
struct ParsedCaptureStep: Decodable {
    let mode: String
    let toName: String
    let minutes: Int
    let lat: Double?
    let lon: Double?
    let busNos: [String]?
}

/// `POST /capture/parse` 의 응답.
struct ParsedCapture: Decodable {
    let steps: [ParsedCaptureStep]
    let notes: [String]
}

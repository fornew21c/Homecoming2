# Homecoming2

귀가하는 사람의 위치를 가족이 실시간으로 보는 iOS 앱 + 서버.
`Homecoming` 을 복사해 만든 **별개 앱**이다(번들 `com.kona.homecoming2`).

## 먼저 읽을 것

- **[`docs/HANDOFF-2026-08-27-stops.md`](docs/HANDOFF-2026-08-27-stops.md)** —
  **여기서 시작한다.** 경기도 GBIS 개통, 이름만으로 정류장 정하기,
  `곧 도착`·heartbeat 버그, 시험이 진짜 DB 를 지우던 것
- **[`docs/HANDOFF-2026-08-27.md`](docs/HANDOFF-2026-08-27.md)** — 그날 오전.
  서울 버스가 열렸다, 서 있는 동안의 자동 갱신, GitHub 공개,
  그리고 `rm -rf Server` 사고
- **[`docs/HANDOFF-2026-08-26-bus.md`](docs/HANDOFF-2026-08-26-bus.md)** —
  버스 실시간 도착을 붙인 기록. 시험이 통과하는데 화면이 비던 두 사건
- **[`docs/HANDOFF-2026-08-26.md`](docs/HANDOFF-2026-08-26.md)** — 그날 오전.
  지하철 폴리라인, 8/25 실주행 사건을 끝까지 따라간 기록
- **[`docs/HANDOFF-2026-08-21.md`](docs/HANDOFF-2026-08-21.md)** — 그 전날 한 일,
  공공데이터 일일 한도 1,000회 등
- **[`docs/HANDOFF-2026-08-20.md`](docs/HANDOFF-2026-08-20.md)** — 배포 정보, 이 환경의
  함정(사내망 TLS 등), 그 전까지 한 일
- **[`docs/superpowers/specs/2026-08-20-progress-unification-design.md`](docs/superpowers/specs/2026-08-20-progress-unification-design.md)**
  — 카드와 지도의 진행도를 한 벌로 합쳤다(구현·검증 완료). 진행도를 건드리기 전에 읽는다

## 이 저장소를 다룰 때

**용어는 `귀가` 다.** 퇴근이 아니다 — 직장에서만 집에 가는 것이 아니라
회식·모임에서도 귀가한다. 화면 문구는 이미 전부 `귀가` 이고 주석에만 "퇴근" 이 남아 있다.

**값을 짐작해서 넣지 않는다.** 좌표·코드·소요시간은 저장소나 공공데이터에서 확인한다.
비교 주장(`A 가 B 보다 크다`)을 하기 전에 재본다. 확인할 수 없으면 그렇다고 말한다.
이 코드의 주석들이 그 규율로 쓰여 있다 — "실제로 이렇게 틀렸다" 는 기록이 붙어 있고,
틀린 값을 화면에 그리는 것을 아무것도 안 그리는 것보다 나쁘게 본다.

**`Homecoming.xcodeproj` 는 생성물이다.** 파일을 더하면
`ruby Tools/generate_project.rb` 로 재생성한다. 번들 ID·표시명의 원본은 그 스크립트다.

**경로의 좌표열은 저장할 때 박힌다.** 그리기 로직을 고쳐도 이미 저장된 경로에는
반영되지 않는다 — 앱에서 경로를 다시 저장해야 한다.

**와이어 프로토콜은 추가만 한다.** `ContentState` 에 필드를 더하면 **네 곳**을
같이 고쳐야 한다 — 빠뜨리면 값이 조용히 사라진다.

1. `CodingKeys` · 2. `init(from:)` · 3. `encode(to:)`
   (`Shared/HomecomingAttributes.swift` 의 경고 주석 참고)
4. **`App/HomecomingActivityManager.swift` 의 `update(...)`** — 이 함수가
   `ContentState` 를 **처음부터 다시 만든다.** 필드를 안 쓰는 것이 곧 지우는 것이라,
   서버만 아는 값은 `previous` 에서 옮겨 담아야 "그대로 둔다" 가 된다.

**네 번째를 빠뜨리면 시험은 다 통과하고 화면만 빈다.** 2026-08-26 에 실제로 그랬다 —
서버가 `999번 15:59 도착` 을 보내는데 앱 화면에 아무것도 없었고, 로컬 갱신 한 번이
지우고 있었다. 그 전에도 `travelledMeters`·`delaySeconds` 가 같은 함정에 빠졌다.

## 검증

시뮬레이터는 사내망 TLS 때문에 배포 서버(HTTPS)에 못 붙는다. 로컬 서버를 띄우고
`-homecomingBackend http://localhost:8811` 로 실행한다. 실기기는 정상이다.

진행도(노선도의 점 · 지도의 색 분리)를 고쳤으면 **다시 잰다.** 두 화면이 같은
자리를 가리키는지 앱 원본을 컴파일해 견준다. 지금 남은 차이는 28.4km 에서 7m 이고
그건 자 차이다(앱 측지선 · 서버 구). **자른 길이를 앱 자로 되재면 안 된다** — 요청한
값과 같은 것이 당연해서 0m 가 나온다. 자른 자리를 서버 자로 되재야 값이 나온다.

**지하철 구간은 역을 거쳐 그린다.** 두 역 직선으로 그리던 것이 실제 선로에서
1,994m 벌어져 이탈로 오판됐다(2026-08-25). 역 좌표는 `Server/data/subway-lines.json`
에 구워 두고 `GET /subway/leg` 가 준다 — `docs/HANDOFF-2026-08-26.md` 참고.

**버스 실시간 도착은 시험으로 안 잡힌다.** 시험 환경에 `TAGO_KEY` 가 없어 조회가
즉시 빠져나가므로, 값이 안 나오는 것도 `content_state` 가 9초 걸리는 것도 다
통과한다. **화면을 봐야 한다** — `docs/HANDOFF-2026-08-26-bus.md` 의 검증 순서를
따른다.

```bash
python3 Tools/verify-progress-sync.py          # 카드 vs 지도, 실제 경로 28.4km
python3 -m unittest discover -s Server        # 서버 시험 151개
```

```bash
source Server/.env.local                       # 공공데이터 키
python3 Server/homecoming_server.py --port 8811
railway up --detach --service homecoming2      # 배포. **저장소 루트에서 쏜다** —
                                               # `railway up` 은 지금 디렉터리를 올린다
```

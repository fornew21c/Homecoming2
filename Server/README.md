# 귀가마중 서버

`docs/API-SPEC.md` 의 참조 구현. 파일 하나, 의존성 없음.

백엔드 팀이 자기 스택으로 옮기기 전까지 **실제로 돌려서 앱을 끝까지 시험**하는 데 쓴다.

## 실행

```bash
python3 Server/homecoming_server.py
```

APNs 를 붙이려면(가족 기기에 실제로 알림이 뜨게 하려면):

```bash
export HOMECOMING_APNS_KEY=/path/AuthKey_XXXXXXXXXX.p8
export HOMECOMING_APNS_KEY_ID=XXXXXXXXXX
export HOMECOMING_TEAM_ID=YYYYYYYYYY
python3 Server/homecoming_server.py
```

설정이 없으면 푸시를 보내지 않고 로그만 남긴다. 페어링·세션 흐름은 그대로 돌아가므로
서버 로직만 먼저 확인할 수 있다.

| 환경변수 | 기본값 | 뜻 |
|---|---|---|
| `HOMECOMING_APNS_KEY` | — | `.p8` 인증 키 경로 |
| `HOMECOMING_APNS_KEY_ID` | — | 키 ID |
| `HOMECOMING_TEAM_ID` | — | 팀 ID |
| `HOMECOMING_APNS_ENV` | sandbox | `production` 이면 운영 APNs |
| `HOMECOMING_BUNDLE_ID` | `com.kona.homecoming2` | APNs 토픽의 근거 |
| `HOMECOMING_DB` | `Server/homecoming.sqlite` | SQLite 파일 |

## 앱에서 붙기

```bash
# 시뮬레이터
xcrun simctl launch <udid> com.kona.homecoming2 -homecomingBackend "http://localhost:8787"

# 실기기 (같은 Wi-Fi. Info.plist 의 NSAllowsLocalNetworking 이 .local 을 허용한다)
xcrun devicectl device process launch --device <id> com.kona.homecoming2 -- \
  -homecomingBackend "http://$(scutil --get LocalHostName).local:8787"
```

기기 한 대로 귀가자와 가족 양쪽을 시험하려면 토큰을 주입한다. 화면을 탭할 수단이
없는 실기기 검증에서 계정을 갈아 끼우는 유일한 길이다.

```bash
TOKEN=$(curl -sS -X POST http://127.0.0.1:8787/device/register \
  -H 'Content-Type: application/json' -d '{}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
xcrun simctl launch <udid> com.kona.homecoming2 -homecomingToken "$TOKEN"
```

`-homecomingResetIdentity` 는 키체인의 자격을 버리고 새 계정으로 등록한다.

## 설계 메모

**서버가 하는 일은 하나다** — 귀가자 한 명의 위치를 받아,
그 사람을 지켜보는 가족 **모두의 화면을 같은 값으로** 갱신한다.
`content-state` 를 한 번 계산해 수신자마다 그대로 보낸다. 다른 것은 `audience` 뿐이다.

- **귀가자당 활성 세션은 하나.** 앱이 재시작돼도 세션이 늘지 않는다
- **단계는 뒤로 가지 않는다.** GPS 가 튀어도 "곧 도착"이 "이동 중"으로 내려가지 않는다
- **도착 반경 하한 100m.** iOS 지오펜스가 그 아래에서 신뢰도가 떨어지는 것과 같은 이유
- **관측 접근 속도로 ETA 를 보정한다.** 앱과 같은 생각이다 — 지면 속도가 아니라
  집에 가까워지는 속도를 본다. 근거가 얕으면(90초·150m 미만) 쓰지 않는다
- **`end` 는 도착 화면을 20초 보여 준 뒤에 보낸다.** 다이나믹 아일랜드는 `end` 를 받는
  순간 알림을 치우기 때문이다. 가족이 실제로 보는 건 그 몇 초다
- **410 은 죽은 토큰.** 받는 즉시 지운다
- **한 수신자의 실패가 다른 수신자를 막지 않는다**

## 위치 이력 보관

위치는 이 서비스가 다루는 가장 민감한 데이터다. 누가 언제 어디 있었는지의 기록이고
유출되면 되돌릴 방법이 없다. 그래서 **필요한 만큼만, 필요한 동안만** 갖는다.

| 시점 | 남는 것 |
|---|---|
| 귀가 중 | 최근 **20건**. 그 이상은 들어올 때마다 잘라낸다 |
| 도착·중지 | 그 세션의 위치 **전부 삭제** |
| 24시간 뒤 | 끝난 세션 행 자체 삭제 (집 좌표도 함께) |

서버가 필요로 하는 건 접근 속도 계산뿐이고 그건 최근 몇 개면 된다.
경로 전체를 쌓아 둘 이유가 없다. **진행 중에도 최근 것만 남으므로,
서버가 털려도 새어 나가는 건 마지막 몇 분이다.**

세션이 제대로 끝나지 않는 경우(서버 재기동, 앱 종료)를 대비해 기동 시 한 번,
이후 한 시간마다 정리한다. 만료된 초대 코드도 같이 걷어낸다.

값은 `FIX_WINDOW`, `SESSION_RETENTION_HOURS` 로 바꾼다.

`sqlite3` 는 자동 커밋 + WAL 로 연다. 그러지 않으면 쓰기 한 번이 트랜잭션을 열어 둔 채
남아 다른 요청을 통째로 막는다(`database is locked`). 실제로 그렇게 한 번 막혔다.

## 인증

`GET /health` 와 `POST /device/register` 를 뺀 모든 요청에 토큰이 필요하다.

```
Authorization: Bearer <token>
```

기기가 처음 켜질 때 `POST /device/register` 로 계정과 토큰을 한 번 받는다.
토큰은 `os.urandom(32)` 에서 나오고, `accounts.auth_token` 에는 **sha256 만** 남는다.
평문은 발급 응답에만 실려 나간다. DB 한 번 새는 것이 모든 기기를 흉내낼 권한이 새는
것이어서는 안 된다. 32바이트 난수라 사전 공격이 통하지 않으므로 솔트와 반복 해싱은
필요 없다.

서버는 평문을 갖고 있지 않으니 잃어버린 토큰을 되찾아 줄 수 없다. 앱은 `401` 을
받으면 자격을 버리고 다시 등록한다 — 그게 없으면 서버 쪽에서 토큰이 사라지는 순간
앱이 같은 죽은 토큰을 영원히 다시 보내면서 영구히 멈춘다.

예전에는 `X-Account-Id` 헤더를 그대로 믿었다. 계정 id 는 가족 목록에서 읽히는
값이라, 남의 id 를 적으면 그 사람의 귀가를 조작할 수 있었다. 지금 서버는 그 헤더를
읽지 않는다.

세션은 소유자만 만진다(`owned_session`). 남의 세션이면 `403` 이 아니라 `404` 다 —
`403` 은 그 세션이 존재한다는 걸 알려 주는 셈이라, 남의 귀가가 진행 중인지 떠보는
데 쓸 수 있다.

여전히 로그인은 아니다. 계정이 **기기 하나**에 묶여 있어 기기를 바꾸면 이어지지 않는다.

다만 앱을 다시 설치하는 것은 괜찮다. iOS 는 앱을 지워도 키체인을 지우지 않아서
같은 계정으로 돌아오고 가족 연결도 살아 있다. 실기기에서 확인했다.

## 아직 없는 것

- **로그인** — 계정이 기기에 묶여 있다. 기기를 바꾸면 이어지지 않는다
- **HTTPS** — 이 서버 자체는 평문 HTTP 만 한다. 앞에 Caddy 를 세워 종단한다.
  `Deploy/` 를 보라. 배포에서는 `--host 127.0.0.1` 로 묶어 바깥에 직접 열지 않는다
- **토큰 회전** — 발급된 토큰은 만료가 없다. 기기를 잃어버렸을 때 그 토큰만 끊는
  수단이 없다
- **요청 제한** — `POST /device/register` 는 인증 없이 열려 있다. 반복해서 부르면
  계정 행이 무한히 늘어난다
- **대중교통 실데이터** — `guess_transport()` 가 거리로 짐작한다.
  TMAP·카카오·ODsay 를 붙일 자리가 거기다
- `[P2]` 안심 확인, 이상 상황 판정


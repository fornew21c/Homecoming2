# 배포

서버를 인터넷에 올린다. **맥에서만 돌면 집 Wi-Fi 를 벗어나는 순간 가족 화면이 멈춘다.**
그런데 이 앱은 정의상 밖에 있을 때 쓰는 앱이다.

두 가지 길이 있다. 지금 쓰는 것은 **Railway** 다.

| | 언제 |
|---|---|
| [Railway](#railway) | 지금 이걸 쓴다. HTTPS·도메인·인증서를 플랫폼이 준다 |
| [직접 VM](#직접-vm) | 서버를 소유하고 싶을 때. systemd + Caddy |

## Railway

`Dockerfile` 과 `railway.json` 이 저장소 루트에 있다.

```bash
railway link            # 프로젝트 연결(없으면 새로 만든다)
railway up              # 빌드 + 배포
railway domain          # 공개 주소 발급
```

### 반드시 해야 하는 것 셋

**1. 볼륨.** 대시보드에서 볼륨을 만들어 `/data` 에 붙이고,

```
HOMECOMING_DB=/data/homecoming.sqlite
```

이걸 안 하면 **배포할 때마다 계정·가족연결·저장한 경로가 전부 날아간다.**
컨테이너 파일 시스템은 배포마다 새로 만들어진다. 가족은 매번 다시 페어링해야 한다.

**2. APNs 키를 내용으로.** 올릴 파일 시스템이 없으니 `.p8` 내용을 그대로 넣는다.

```bash
railway variables --set "HOMECOMING_APNS_KEY_P8=$(cat AuthKey_XXXXXXXXXX.p8)"
railway variables --set "HOMECOMING_APNS_KEY_ID=XXXXXXXXXX"
railway variables --set "HOMECOMING_TEAM_ID=YYYYYYYYYY"
railway variables --set "HOMECOMING_APNS_ENV=sandbox"
```

**3. 복제본은 하나로 둔다.** `railway.json` 의 `numReplicas: 1` 이 그것이다.
SQLite 에 쓰는 프로세스가 둘이면 DB 가 깨진다. 이 앱은 가족 몇 세대를 감당하는 데
한 개로 남는다 — 늘려야 할 만큼 커지면 그때는 SQLite 를 떠날 때다.

### 알고 있어야 하는 것

- **데이터가 국내에 없다.** Railway 리전은 미국·유럽·싱가포르다. 개인 프로젝트에는
  문제가 아니지만, 앱스토어에 올리며 위치정보사업 신고를 할 때 서버 소재지를 묻는다
- 포트는 Railway 가 `PORT` 로 주입한다. 서버가 그걸 읽는다
- TLS 는 Railway 가 끝낸다. 컨테이너 안은 평문 HTTP 다

## 직접 VM

Railway 대신 서버를 소유하고 싶을 때. 여기서는 HTTPS 를 직접 세워야 한다.

### 왜 서버가 있어야 하는가

가족 기기의 잠금화면 카드를 갱신하는 유일한 방법이 APNs 이고, APNs 로 쏘는 주체는
서버다. 귀가자 폰이 아무리 정확히 계산해도 그 값은 자기 화면에만 남는다.

서버가 맥에 있으면 **집 Wi-Fi 를 벗어난 순간 갱신이 끊긴다.** 실제로 그렇게 막혔다 —
가족 폰에 카드는 떴는데(그건 애플에서 폰으로 가니까) 첫 값에서 멈춰 있었다.

## 필요한 것

| | |
|---|---|
| VM | 아무 리눅스. 이 서버는 파이썬 표준 라이브러리와 SQLite 만 쓴다 — 가장 싼 것으로 충분하다 |
| 도메인 | APNs 와 무관하지만 **인증서에 필요하다.** IP 로는 인증서를 못 받는다 |
| APNs `.p8` 키 | Apple Developer → Keys. Team ID 와 Key ID 도 같이 |

파이썬 3.9 이상. 패키지 설치는 없다.

## 처음 준비

한 번만 한다. 자동화하지 않았다 — 한 번 하는 일을 스크립트로 감싸면 잘못 돌 때
무엇이 잘못됐는지 알기 어렵다.

```bash
# 1. 서버 계정. 로그인도 셸도 필요 없다.
sudo useradd --system --home /opt/homecoming --shell /usr/sbin/nologin homecoming

# 2. 디렉터리. 코드는 읽기 전용, DB 만 쓰기 가능.
sudo install -d -o homecoming -g homecoming /opt/homecoming
sudo install -d -o homecoming -g homecoming /var/lib/homecoming
sudo install -d -o homecoming -g homecoming -m 0700 /opt/homecoming/secrets

# 3. APNs 키. 이 파일이 새면 누구나 이 앱 이름으로 알림을 쏠 수 있다.
sudo install -o homecoming -g homecoming -m 0400 \
  AuthKey_XXXXXXXXXX.p8 /opt/homecoming/secrets/

# 4. 비밀값. 유닛 파일에 적지 않는다 — 유닛은 저장소에 들어가고
#    `systemctl cat` 으로 누구나 읽는다.
sudo tee /etc/homecoming.env >/dev/null <<'ENV'
HOMECOMING_APNS_KEY=/opt/homecoming/secrets/AuthKey_XXXXXXXXXX.p8
HOMECOMING_APNS_KEY_ID=XXXXXXXXXX
HOMECOMING_TEAM_ID=YYYYYYYYYY
HOMECOMING_APNS_ENV=sandbox
HOMECOMING_DB=/var/lib/homecoming/homecoming.sqlite
ENV
sudo chmod 0600 /etc/homecoming.env

# 5. 서비스
sudo cp Deploy/homecoming.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now homecoming

# 6. HTTPS. Caddyfile 의 도메인과 메일 주소를 먼저 바꿔라.
sudo apt install caddy
sudo cp Deploy/Caddyfile /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

이후 배포는 한 줄이다.

```bash
Deploy/deploy.sh homecoming.example.com
```

## 앱 쪽

`App/Info.plist` 의 `HomecomingBackendBaseURL` 을 그 주소로 바꾼다. 지금은 비어 있고,
비어 있으면 앱은 **서버 없이** 돈다 — 귀가 알림이 본인 기기에만 뜨고 가족은 못 본다.

```xml
<key>HomecomingBackendBaseURL</key>
<string>https://homecoming.example.com</string>
```

`http://` 로 두지 마라. iOS 의 ATS 가 막고, 막지 않더라도 토큰이 평문으로 흐른다.

## APNs sandbox 와 production

Xcode 에서 직접 설치한 빌드는 **sandbox** 토큰을 받고, TestFlight·App Store 빌드는
**production** 토큰을 받는다. 서버가 반대쪽으로 쏘면 APNs 가 `BadDeviceToken` 을
돌려주고 알림은 조용히 사라진다.

`HOMECOMING_APNS_ENV` 를 빌드 종류에 맞춰라. 한 서버가 둘을 동시에 섬기지는 못한다 —
TestFlight 로 넘어갈 때 이 값을 `production` 으로 바꾼다.

## 확인할 것

`deploy.sh` 가 매번 본다.

- `https://<호스트>/health` 가 `{"ok": true, "apns": true}` 를 준다
  `"apns": false` 면 서버는 돌지만 알림이 한 건도 가지 않는다
- 토큰 없이 `/route` 를 부르면 `401`

## 백업

DB 에는 계정, 가족 연결, 저장된 경로가 있다. 잃으면 모든 가족이 다시 페어링해야 하고
경로를 다시 만들어야 한다. 위치 이력은 진행 중 최근 20건뿐이라 백업할 것이 아니다.

```bash
sudo -u homecoming sqlite3 /var/lib/homecoming/homecoming.sqlite ".backup '/tmp/homecoming.bak'"
```

`cp` 로 복사하면 안 된다. WAL 로 열려 있어서 쓰기 도중의 조각을 뜰 수 있다.

**백업 파일에는 가족 관계와 집 좌표가 들어 있다.** 아무 데나 두지 마라.

## 아직 안 하는 것

- **토큰 회전** — 발급된 토큰은 만료가 없다. 기기를 잃어버렸을 때 그 토큰만 끊는
  수단이 없다(계정을 지우면 페어링도 끊긴다)
- **요청 제한** — `POST /device/register` 는 인증 없이 열려 있다. 누가 반복해서
  부르면 계정 행이 무한히 늘어난다. 지금은 아무도 모르는 주소라는 것에 의존한다
- **감시** — 서버가 죽으면 아무도 모른다. `systemd` 가 다시 띄우지만, 계속 죽는
  상태를 알려 주는 것은 없다

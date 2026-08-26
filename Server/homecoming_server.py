#!/usr/bin/env python3
"""귀가마중 서버 — docs/API-SPEC.md 참조 구현.

의존성이 없다. 파이썬 3 표준 라이브러리와 sqlite3 만 쓰고,
APNs 는 HTTP/2 가 필요해 curl 을 부른다(표준 라이브러리에 HTTP/2 클라이언트가 없다).

    export HOMECOMING_APNS_KEY=/path/AuthKey_XXXXXXXXXX.p8
    export HOMECOMING_APNS_KEY_ID=XXXXXXXXXX
    export HOMECOMING_TEAM_ID=YYYYYYYYYY
    python3 Server/homecoming_server.py

APNs 설정이 없으면 푸시를 보내지 않고 로그만 남긴다. 페어링·세션 흐름은 그대로 돈다.

이 서버가 하는 일은 하나로 요약된다:
**귀가자 한 명의 위치를 받아, 그 사람을 지켜보는 가족 모두의 화면을 같은 값으로 갱신한다.**
가족 기기는 아무것도 계산하지 않는다.
"""

import argparse
import hashlib
import base64
import json
import math
import os
import pathlib
import ssl
import sqlite3
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from concurrent import futures
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# --------------------------------------------------------------------- 설정

BUNDLE_ID = os.environ.get("HOMECOMING_BUNDLE_ID", "com.kona.homecoming2")
APNS_KEY_ID = os.environ.get("HOMECOMING_APNS_KEY_ID")


def apns_key_path():
    """`.p8` 키 파일의 경로. 없으면 None.

    두 가지로 받는다.

      `HOMECOMING_APNS_KEY`      파일 경로. 맥에서 돌릴 때 쓴다
      `HOMECOMING_APNS_KEY_P8`   키 내용 자체. **배포에서 쓴다**

    내용을 받는 길이 필요한 이유 — Railway 같은 곳에는 파일을 올릴 자리가 없다.
    비밀은 환경변수로만 들어간다. 받은 내용은 프로세스가 읽을 수 있는 곳에
    0600 으로 한 번 쓰고 그 경로를 쓴다. `openssl` 이 파일을 요구하기 때문이다.
    """
    direct = os.environ.get("HOMECOMING_APNS_KEY")
    if direct:
        return direct

    contents = os.environ.get("HOMECOMING_APNS_KEY_P8")
    if not contents:
        return None

    # 여러 줄을 환경변수에 넣기 번거로운 곳이 있어 `\n` 도 받아 준다.
    if "\\n" in contents and "\n" not in contents:
        contents = contents.replace("\\n", "\n")

    path = os.path.join(tempfile.gettempdir(), "homecoming-apns.p8")
    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as handle:
        handle.write(contents if contents.endswith("\n") else contents + "\n")
    return path


APNS_KEY = apns_key_path()
TEAM_ID = os.environ.get("HOMECOMING_TEAM_ID")
APNS_HOST = (
    "api.push.apple.com"
    if os.environ.get("HOMECOMING_APNS_ENV") == "production"
    else "api.sandbox.push.apple.com"
)
# DB 위치. **배포에서는 반드시 영구 디스크를 가리켜야 한다.**
# 컨테이너의 기본 파일 시스템은 배포할 때마다 사라진다 — 그러면 계정과 가족
# 연결과 저장한 경로가 매 배포마다 날아가고, 가족은 다시 페어링해야 한다.
DB_PATH = os.environ.get("HOMECOMING_DB", "Server/homecoming.sqlite")

INVITE_TTL_MINUTES = 30

# 도착 반경 하한. iOS 지오펜스가 100m 아래에서 신뢰도가 떨어지는 것과 같은 이유로
# 서버 판정도 그보다 좁게 잡지 않는다.
MIN_ARRIVAL_RADIUS = 100

# 이 시간을 넘도록 위치가 없으면 관측 속도를 믿지 않는다.
FIX_FRESHNESS_SECONDS = 180

# 관측 접근 속도를 믿을 수 있는 구간(m/초).
#
# 하한이 왜 필요한지 — 대중교통 귀가는 구간마다 방향이 다르다. 실제 경로로
# 시험해 보니 환승로터리에서 서강대역까지 7분 걷는 동안 집(19km 밖)에는 겨우
# 300m 가까워졌다. 그 순간 접근 속도가 0.3 m/초로 잡히고, 남은 거리 전체를
# 그걸로 나누면 **도착예정이 18.8시간**으로 나온다. 가족 잠금화면에 그게 떴다.
#
# 접근 속도가 걷는 것보다 느리면 그 관측은 남은 여정의 예측에 쓸 수 없다.
# 우회 중이거나 환승 중이라는 뜻이다. 그럴 때는 교통수단 기반 추정으로 되돌린다.
# 상한은 반대쪽 — GPS 가 크게 튀면 좁힌 거리가 뻥튀어 도착예정이 0에 붙는다.
MIN_OBSERVED_SPEED = 1.0        # 3.6km/h. 걷는 속도 바로 아래
MAX_OBSERVED_SPEED = 30.0       # 108km/h. 이보다 빠르면 튐이다

# 관측값이 교통수단 기반 추정을 이 배수 넘게 뒤집지는 못한다.
#
# 하한만으로는 부족했다. 1.11 m/초는 하한을 넘지만 남은 19km 를 나누면 4.7시간이다.
# 한 구간의 접근 속도를 남은 여정 전체에 곱하는 게 애초에 무리다. 관측은 추정을
# 다듬는 것이고, 자릿수를 바꿀 권한은 없다. 실제 정체라면 3배까지는 열어 둔다.
#
# 근본적으로는 저장된 경로의 구간별 실측 시간을 쓰는 게 답이다. 그때 이 상수는 사라진다.
ETA_OBSERVED_LIMIT = 3.0

# 저장된 경로에서 이만큼 벗어나면 그 경로로 가는 게 아니라고 본다.
#
# 넉넉하게 잡는 이유 — 지하철 구간은 역 좌표를 직선으로 이은 것이라 실제 선로와
# 수백 미터 어긋난다. 버스도 우회 운행이 있다. 좁게 잡으면 정상 귀가를 이탈로
# 오판하고, 그러면 저장된 시간을 버리고 거리 추정으로 되돌아가서 더 나빠진다.
OFF_ROUTE_METERS = 1000

# 이탈했다가 이 안으로 들어오면 경로로 돌아온 것으로 본다.
#
# **이탈 문턱과 같은 값을 쓰면 경계에서 깜박인다.** 1000m 근처에서 GPS 가 흔들리면
# 매 보고마다 이탈과 복귀가 번갈아 뜨고, 그때마다 남은거리의 자(경로 ↔ 직선)가
# 바뀌어 화면이 앞뒤로 튄다. 그래서 들어오는 문턱을 나가는 문턱보다 좁게 둔다.
#
# 600m 인 이유 — 지하철 구간은 역 좌표를 직선으로 이은 것이라 실제 선로와 수백
# 미터 어긋난다. 그보다는 넉넉하고 이탈 문턱보다는 확실히 좁아야 한다.
OFF_ROUTE_REJOIN_METERS = 600

# 지연은 평활화해서 쌓는다. 새 관측을 이 비율만큼만 반영한다.
#
# 위치가 흔들리면 지연도 흔들린다. 지하철 정확도 150m 에 시속 33km 면 그것만으로
# ±16초다. 매 위치마다 지연이 튀면 가족 화면이 고장 난 것처럼 보인다.
# 진짜 지연은 몇 건에 걸쳐 확정되고, 한 건의 튐은 4분의 1만 반영된다.
DELAY_SMOOTHING = 0.25

# --- 위치 이력 보관 ---------------------------------------------------------
#
# 위치는 이 서비스가 다루는 가장 민감한 데이터다. 누가 언제 어디 있었는지의 기록이고,
# 유출되면 되돌릴 방법이 없다. 그래서 **필요한 만큼만, 필요한 동안만** 갖는다.
#
# 필요한 것은 접근 속도 계산뿐이고 그건 최근 몇 개면 된다. 경로 전체를 쌓아 둘 이유가 없다.
# 진행 중에도 최근 것만 남기므로, 서버가 털려도 새어 나가는 건 마지막 몇 분이다.

# 세션이 도는 동안 세션당 유지할 위치 개수. 속도 계산은 12개만 읽는다.
FIX_WINDOW = 20

# 끝난 세션 기록을 지우기까지의 시간. 종료 직후 알림 정리에 잠깐 필요해서 0 이 아니다.
SESSION_RETENTION_HOURS = 24

# 진행 중인 세션을 재사용할 수 있는 최대 나이(시간).
#
# **귀가자당 활성 세션은 하나다.** 앱이 재시작돼도 세션이 늘어나지 않게 하려고
# 같은 경로면 진행 중인 것을 돌려준다. 그런데 나이를 안 보면 이렇게 된다 —
# 앱이 죽어 세션을 못 닫으면 그 세션이 영구히 "진행 중" 으로 남고, 다음에 같은
# 경로로 귀가를 시작할 때 **몇 시간 전에 시작된 세션이 재사용된다.** 경과 시간이
# 그만큼 잡히므로 도착예정과 지연이 통째로 망가진다.
#
# 2026-08-19 에 실제로 그렇게 됐다(`이미 진행 중인 세션 2a7a3c973cef 재사용`).
# 그날 오후에 시험으로 열어 둔 세션이 그대로 살아 있었다.
#
# 6시간인 이유 — 어떤 귀가도 이보다 길지 않다(이 경로가 82분이다). 그리고 하루보다
# 짧아야 "어제 세션이 오늘 재사용" 을 막는다.
SESSION_REUSE_MAX_HOURS = 6


def token_digest(token):
    """토큰을 저장할 형태로 바꾼다.

    **평문으로 두면 DB 한 번 새는 것이 모든 기기를 흉내낼 권한이 새는 것이다.**
    비밀번호와 달리 이 토큰은 32바이트 난수라 사전 공격이 통하지 않으므로
    솔트와 반복 해싱이 필요 없다. sha256 한 번으로 충분하다.

    서버는 평문을 저장하지 않으므로 잃어버린 토큰을 되찾아 줄 수 없다.
    그건 의도다 — 되찾아 줄 수 있으면 남도 되찾아 갈 수 있다.
    """
    return hashlib.sha256(token.encode()).hexdigest()


def log(*parts):
    print(f"[{datetime.now().strftime('%H:%M:%S')}]", *parts, flush=True)


def iso(dt):
    """명세가 요구하는 형식. Swift 가 이 문자열을 그대로 Date 로 읽는다."""
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def now():
    return datetime.now(timezone.utc)


def parse_iso(text):
    """ISO8601 문자열 → datetime. 소수점 초가 있든 없든 받는다.

    앱은 `Shared/HomecomingWire.swift` 에서 소수점 없이 보내지만 받을 때는 둘 다
    받아 준다. 서버도 같아야 한다. 여기서 None 을 돌려주면 호출한 쪽이 조용히
    `now()` 로 대체해서 관측 접근 속도가 통째로 어긋난다. 에러가 안 나니 안 보인다.
    """
    if not text:
        return None
    stamp = text.replace("Z", "+0000")
    for shape in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S.%f%z"):
        try:
            return datetime.strptime(stamp, shape)
        except ValueError:
            continue
    return None


def haversine(a_lat, a_lon, b_lat, b_lon):
    r = 6_371_000
    p1, p2 = math.radians(a_lat), math.radians(b_lat)
    dp = math.radians(b_lat - a_lat)
    dl = math.radians(b_lon - a_lon)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


# ----------------------------------------------------------------- 저장소

SCHEMA = """
CREATE TABLE IF NOT EXISTS accounts (
    id           TEXT PRIMARY KEY,
    device_token TEXT,
    start_token  TEXT,
    updated_at   TEXT,
    -- 이 기기 토큰의 sha256. **평문이 아니다.**
    -- 요청은 Authorization: Bearer <평문 토큰> 으로 오고, 서버가 해시해서 맞춰 본다.
    --
    -- 이게 없을 때는 X-Account-Id 헤더에 적힌 걸 그대로 믿었다. 헤더 한 줄만 바꾸면
    -- 남의 실시간 위치를 읽고 남의 세션을 끝낼 수 있었다. 위치 공유 앱에서 그건 구멍이다.
    auth_token   TEXT,
    -- 이 계정이 마지막으로 요청을 보낸 시각.
    --
    -- **기기가 서버에 닿는지를 보는 유일한 신호다.** 실기기 검증에서 카드가 뜨고도
    -- 첫 값에서 멈춘 적이 있는데, 원인은 폰이 다른 Wi-Fi 라 맥에 토큰을 못 올린
    -- 것이었다. "토큰이 없다" 와 "아예 못 닿는다" 는 증상이 같아서 한참 헤맸다.
    last_seen    TEXT
);

-- 자주 가는 귀가 경로.
--
-- 매일 같은 버스-지하철-버스를 탄다면 도착예정은 계산할 값이 아니라 **아는 값**이다.
-- 대중교통 앱이 "1시간 21분" 이라고 알려 준다. 그게 total_seconds 다.
--
-- 위치는 예측에 쓰지 않는다. 두 가지만 한다 —
--   어느 구간에 있는가 (구간은 km 단위라 정확도 150m 로도 충분하다)
--   기대 시각보다 얼마나 밀렸는가 (그 차이가 그대로 도착예정에 더해진다)
--
-- legs 는 JSON 배열이다. 구간마다 mode, startsAt, seconds, points.
-- 관계형으로 쪼개도 늘 통째로 읽고 통째로 쓴다. 쪼갤 이유가 없다.
CREATE TABLE IF NOT EXISTS routes (
    id            TEXT PRIMARY KEY,
    account_id    TEXT NOT NULL,
    name          TEXT NOT NULL,
    home_lat      REAL NOT NULL,
    home_lon      REAL NOT NULL,
    home_radius   REAL NOT NULL,
    home_name     TEXT,
    total_seconds INTEGER NOT NULL,
    legs          TEXT NOT NULL,
    created_at    TEXT NOT NULL
);

-- 유일 색인(routes_account_name)은 여기 두지 않는다. 이미 중복이 쌓인 DB 에서는
-- 생성이 실패하므로, migrate() 가 중복을 걷어낸 뒤에 붙인다.

CREATE TABLE IF NOT EXISTS links (
    traveler      TEXT NOT NULL,
    watcher       TEXT NOT NULL,
    watcher_name  TEXT NOT NULL,
    traveler_name TEXT NOT NULL,
    PRIMARY KEY (traveler, watcher)
);

CREATE TABLE IF NOT EXISTS invites (
    code          TEXT PRIMARY KEY,
    traveler      TEXT NOT NULL,
    traveler_name TEXT NOT NULL,
    expires_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    id               TEXT PRIMARY KEY,
    traveler         TEXT NOT NULL,
    traveler_name    TEXT NOT NULL,
    home_lat         REAL NOT NULL,
    home_lon         REAL NOT NULL,
    home_radius      REAL NOT NULL,
    home_name        TEXT NOT NULL,
    total_meters     INTEGER NOT NULL,
    remaining_meters INTEGER NOT NULL,
    stage            TEXT NOT NULL,
    transport        TEXT NOT NULL,
    expected_arrival TEXT NOT NULL,
    detail           TEXT,
    started_at       TEXT NOT NULL,
    ended_at         TEXT,
    end_reason       TEXT,
    -- 저장된 경로로 도는 귀가면 그 경로 id. 없으면 거리 기반 추정으로 돈다.
    route_id         TEXT,
    -- 경로 기준으로 몇 초 밀렸는가. 버스를 놓치면 여기 쌓인다.
    delay_seconds    INTEGER NOT NULL DEFAULT 0,
    -- 저장된 경로에서 크게 벗어났으면 1. 그때부터 거리 기반으로 되돌린다.
    off_route        INTEGER NOT NULL DEFAULT 0,
    -- 이 세션에서 가족 화면에 **실제로 닿은** 갱신 횟수.
    --
    -- 검증 도구가 "갱신이 갔는가" 를 판정할 근거다. 도착하면 액티비티 행을 지우므로
    -- 끝난 뒤에 액티비티 수를 세면 항상 0 이고, 통과한 실행이 실패처럼 보인다.
    updates_sent     INTEGER NOT NULL DEFAULT 0,
    -- 경로 위에서 여기까지 왔다(초). 뒤로 가지 않는다 — 단계와 같은 이유다.
    -- GPS 가 흔들리면 가장 가까운 좌표가 앞뒤로 튀는데, 그대로 두면 지연이 깜박인다.
    route_progress   INTEGER NOT NULL DEFAULT 0,
    -- 지금 값들이 **언제의 위치로** 만들어졌는가. 화면이 낡음을 스스로 말하는 근거다.
    --
    -- 푸시를 받은 시각으로는 판단할 수 없다. APNs 가 갱신을 붙잡고 있다가 내려보내면
    -- 폰은 방금 받았지만 내용은 27분 전 자리다(2026-08-18 실주행). 그래서 측정 시각을
    -- 상태에 실어 보낸다.
    measured_at      TEXT,
    -- 마지막으로 보고된 귀가자 위치. 가족 화면의 지도가 이 값으로 점을 찍는다.
    --
    -- `fixes` 에서 읽지 않는 이유: close_session() 이 end_activities() 보다 먼저
    -- fixes 를 지운다. 그래서 도착 푸시만 좌표 없이 나가고, 가족 지도가 도착하는
    -- 순간에만 비었다. 마지막 자리는 세션이 직접 들고 있어야 한다.
    last_lat         REAL,
    last_lon         REAL,
    -- 경로 없이 시작한 귀가에서 **귀가자가 적은** 예상 소요시간(초).
    --
    -- 저장된 경로의 `total_seconds` 와 같은 자리를 맡는다 — 도착예정의 근거다.
    -- 경로가 없으면 계산할 근거가 없어서 사람에게 묻는다. 관측 속도로 짐작하면
    -- 지하철처럼 집 쪽으로 곧장 가지 않는 길에서 크게 틀린다.
    planned_seconds  INTEGER
);

CREATE TABLE IF NOT EXISTS activities (
    activity_id TEXT PRIMARY KEY,
    session_id  TEXT NOT NULL,
    account_id  TEXT NOT NULL,
    token       TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS fixes (
    session_id TEXT NOT NULL,
    lat        REAL NOT NULL,
    lon        REAL NOT NULL,
    at         TEXT NOT NULL,
    remaining  REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS fixes_session ON fixes (session_id, at);
"""

_local = threading.local()


def db():
    """스레드마다 연결 하나.

    `isolation_level=None` 은 자동 커밋이다. 이게 없으면 쓰기 한 번이
    트랜잭션을 열어 둔 채 남아 다른 요청을 통째로 막는다(database is locked).
    WAL 은 읽기와 쓰기가 서로를 기다리지 않게 해 준다.
    """
    if not hasattr(_local, "conn"):
        os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
        _local.conn = sqlite3.connect(DB_PATH, check_same_thread=False, isolation_level=None)
        _local.conn.row_factory = sqlite3.Row
        _local.conn.execute("PRAGMA journal_mode = WAL")
        _local.conn.execute("PRAGMA busy_timeout = 5000")
        _local.conn.executescript(SCHEMA)
        migrate(_local.conn)
    return _local.conn


# 이미 만들어진 표에는 CREATE TABLE IF NOT EXISTS 가 열을 붙여 주지 않는다.
# 지우고 다시 만들면 진행 중인 귀가와 페어링이 날아간다. 그래서 하나씩 붙인다.
ADDED_COLUMNS = [
    ("sessions", "route_id", "TEXT"),
    ("sessions", "delay_seconds", "INTEGER NOT NULL DEFAULT 0"),
    ("sessions", "off_route", "INTEGER NOT NULL DEFAULT 0"),
    ("sessions", "route_progress", "INTEGER NOT NULL DEFAULT 0"),
    ("accounts", "auth_token", "TEXT"),
    ("accounts", "last_seen", "TEXT"),
    # 이 컬럼이 붙는 순간이 해싱 이전과 이후의 경계다. migrate() 를 보라.
    ("accounts", "token_hashed", "INTEGER NOT NULL DEFAULT 0"),
    ("sessions", "updates_sent", "INTEGER NOT NULL DEFAULT 0"),
    ("sessions", "measured_at", "TEXT"),
    ("sessions", "last_lat", "REAL"),
    ("sessions", "last_lon", "REAL"),
    ("sessions", "planned_seconds", "INTEGER"),
]


def migrate(conn):
    added = set()
    for table, column, kind in ADDED_COLUMNS:
        have = {row["name"] for row in conn.execute(f"PRAGMA table_info({table})")}
        if column not in have:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {kind}")
            log(f"  스키마 추가 {table}.{column}")
            added.add((table, column))

    if ("accounts", "token_hashed") in added:
        retire_plaintext_tokens(conn)

    dedupe_routes(conn)


def retire_plaintext_tokens(conn):
    """해싱 이전에 발급한 토큰을 버린다.

    옛 토큰은 평문으로 저장돼 있었다. 그걸 해시로 옮길 수는 없다 — 평문 토큰과
    sha256 이 **둘 다 64자 16진수**라 어느 쪽인지 구분할 방법이 없다. 잘못 해시하면
    이미 해시된 것을 두 번 해시해서 조용히 못 쓰게 만든다.

    그래서 지우고 다시 받게 한다. 앱은 401 을 받으면 자격을 버리고 재등록한다
    (`HomecomingAuth.recoverFromUnauthorized`). 페어링은 계정에 붙어 있으므로
    계정 자체는 남기고 토큰만 비운다 — 가족 연결이 살아 있다.
    """
    count = conn.execute(
        "UPDATE accounts SET auth_token = NULL, token_hashed = 1 WHERE auth_token IS NOT NULL"
    ).rowcount
    if count:
        log(f"  평문 토큰 {count}건 폐기 — 해당 기기는 다시 등록한다")


def dedupe_routes(conn):
    """같은 계정에 같은 이름의 경로가 여럿이면 가장 최근 것만 남긴다.

    유일 색인을 나중에 붙였으니 이미 쌓인 중복을 먼저 걷어야 한다. 지우기 전에
    그 경로를 쓰던 세션을 남는 경로로 옮긴다 — 안 하면 진행 중인 귀가가 조용히
    거리 기반 추정으로 떨어진다.
    """
    groups = conn.execute(
        "SELECT account_id, name, COUNT(*) AS n FROM routes "
        "GROUP BY account_id, name HAVING n > 1"
    ).fetchall()
    for group in groups:
        rows = conn.execute(
            "SELECT id FROM routes WHERE account_id = ? AND name = ? "
            "ORDER BY created_at DESC, id DESC",
            (group["account_id"], group["name"]),
        ).fetchall()
        keep, drop = rows[0]["id"], [r["id"] for r in rows[1:]]
        marks = ",".join("?" * len(drop))
        conn.execute(f"UPDATE sessions SET route_id = ? WHERE route_id IN ({marks})",
                     [keep] + drop)
        conn.execute(f"DELETE FROM routes WHERE id IN ({marks})", drop)
        log(f"  중복 경로 정리 '{group['name']}' {len(drop)}개 → {keep}")

    # 한 사람이 같은 이름의 경로를 두 개 가질 이유가 없다. 중복을 걷어낸 다음에 잠근다.
    conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS routes_account_name "
                 "ON routes (account_id, name)")


# -------------------------------------------------------------------- APNs

_jwt_cache = {"token": None, "at": 0}
_jwt_lock = threading.Lock()


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der):
    """openssl 의 DER 서명을 JWT 가 요구하는 r||s 64바이트로."""
    index = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)

    def read_int(pos):
        length = der[pos + 1]
        value = der[pos + 2: pos + 2 + length].lstrip(b"\x00")
        return value.rjust(32, b"\x00"), pos + 2 + length

    r, index = read_int(index)
    s, _ = read_int(index)
    return r + s


def apns_jwt():
    """APNs 인증 토큰. 유효기간이 1시간이라 50분마다 새로 만든다."""
    with _jwt_lock:
        if _jwt_cache["token"] and time.time() - _jwt_cache["at"] < 50 * 60:
            return _jwt_cache["token"]

        header = {"alg": "ES256", "kid": APNS_KEY_ID}
        claims = {"iss": TEAM_ID, "iat": int(time.time())}
        signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(claims).encode())}"

        signed = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", APNS_KEY],
            input=signing_input.encode(), capture_output=True,
        )
        if signed.returncode != 0:
            raise RuntimeError(f"APNs 서명 실패: {signed.stderr.decode()}")

        token = f"{signing_input}.{b64url(der_to_raw(signed.stdout))}"
        _jwt_cache.update(token=token, at=time.time())
        return token


# APNs 로 쏘는 데 필요한 바깥 도구.
#
#   curl     HTTP/2 로 APNs 에 붙는다. 파이썬 표준 라이브러리는 HTTP/2 를 못 한다
#   openssl  ES256 서명
#
# **키만 보고 "설정됨" 이라고 하면 안 된다.** 첫 배포에서 컨테이너에 curl 이 없어
# 푸시 스레드가 FileNotFoundError 로 죽었는데 `/health` 는 `apns: true` 를
# 돌려주고 있었다. 서버는 멀쩡해 보이고 알림만 한 건도 안 갔다.
APNS_TOOLS = ("curl", "openssl")


def missing_tools():
    """APNs 에 쏘는 데 필요한데 없는 도구."""
    return [name for name in APNS_TOOLS if shutil.which(name) is None]


# 공공데이터포털 정류소 조회. 키가 없으면 조용히 빈 목록을 준다 —
# 이 기능이 없어도 경로는 지도에서 찍어 만들 수 있다.
TAGO_KEY = os.environ.get("HOMECOMING_TAGO_KEY")
TAGO_STOPS = "https://apis.data.go.kr/1613000/BusSttnInfoInqireService/getCrdntPrxmtSttnList"


# --- 버스 노선의 실제 경로 -------------------------------------------------
#
# **왜 필요한가** — 앱은 버스 구간을 MapKit 자동차 경로로 그린다(`RouteTracer`).
# 애플이 대중교통 좌표열을 주지 않기 때문인데, 자동차는 최단으로 가고 버스는
# 정류장을 훑으며 돈다. 999번(고양) 구간에서 그 차이가 화면에 드러났다.
#
# 공공데이터에 노선의 **경유 정류장 순서**가 있다. 그걸 받아 정류장을 이으면
# 실제 노선에 가까워진다. 좌표는 그 응답에 없어서 좌표 조회를 한 번 더 한다.
#
# **세 가지가 문서에 없던 값이라 여기 적어 둔다**(2026-08-20 실측):
#   `opr_ymd` 가 최근이면 자료가 없다. 20260601 은 되고 20260731 이후는
#   NO_DATA_FOUND 다. 월 단위 스냅샷으로 보인다.
#   `BusRoutespecificStopInformation` 은 `sgg_cd` 가 없으면 52 를 준다.
#   노선번호로 `rte_id` 를 찾는 파라미터가 없다. 시도를 통째로 훑어야 한다.
BUS_ROUTES = "https://apis.data.go.kr/1613000/BusRoute/getBusRoute"
BUS_ROUTE_STOPS = ("https://apis.data.go.kr/1613000/BusRoutespecificStopInformation"
                   "/getBusRoutespecificStopInformation")

# 노선표를 훑을 시도. 이 앱의 귀가가 서울에서 경기로 넘어간다.
BUS_CTPV = ["41", "11"]

# 운영일자 후보. 최근 것부터 보고 자료가 있는 첫 값을 쓴다.
BUS_OPR_YMD_CANDIDATES = ["20260601", "20260501", "20260401"]


def new_style_get(url, params):
    """신규 계열 공공데이터 호출. 실패하면 None."""
    query = urllib.parse.urlencode({"serviceKey": TAGO_KEY, **params})
    try:
        with urllib.request.urlopen(f"{url}?{query}", timeout=15,
                                    context=outbound_tls()) as response:
            body = json.loads(response.read().decode("utf-8"))
    except Exception as error:                                  # noqa: BLE001
        log(f"  버스 노선 조회 실패: {error!r}")
        return None
    # 신규 계열은 성공에 대문자 `Response`, 오류에 `Error` 를 쓴다.
    if "Error" in body:
        return None
    rows = ((body.get("Response") or {}).get("body") or {}).get("items") or {}
    rows = rows.get("item") if isinstance(rows, dict) else None
    if rows is None:
        return None
    return rows if isinstance(rows, list) else [rows]


_bus_routes = {}          # 시도코드 → {노선번호: [노선id, ...]}
_bus_opr_ymd = None
_bus_route_stops = {}     # (노선번호, 시도) → 정류장 이름 순서


# **시군구 코드는 자료에 물어서 얻는다.**
#
# 경유정류장 API 는 `sgg_cd` 를 요구하는데, 그 값을 좌표나 노선번호에서 얻는 길이
# 없다. 노선표의 `sgg_cd` 는 경기 4,671개 노선 전부 `41000`(도 단위 자리표시자)이고,
# 시군구 목록 API(`BusLcInfoInqireService`)는 이 키에 권한이 없다(403).
#
# **그런데 `getBusStop` 응답에 `sgg_nm` 이 온다** — 코드를 넣어 보면 자료가 그게 어느
# 시군구인지 말해 준다(2026-08-21). 그래서 코드 공간을 훑는 것이 짐작이 아니라 확인이
# 된다. 훑기는 `Tools/sgg-sweep.py` 가 하루 예산 안에서 이어서 한다 — 경기
# 41000~41999 를 다 훑어 아래 35개를 얻었다(2026-08-25 완료). 서울(11000~11999)은
# 훑는 중인데 251개까지 **하나도 없다**. 서울 시내버스는 이 자료에 없다.
#
# **여기 적기 전에 경유정류장 API 로 한 번 더 확인한다.** `getBusStop` 에 코드가
# 있다는 것이 이 API 에서도 된다는 뜻은 아니어서다. 2026-08-25 에 성남 세 구로
# 확인했다 — 41131 위례자이 · 41133 신흥역.종합시장 · 41135 율동공원이 그대로 왔고,
# 실제 노선(66번, `rte_id` 41255002)에서 수정구 17 + 분당구 30 = 47개가 `sttn_seq`
# 0~46 으로 **빈 자리 없이** 이어졌다.
#
# 목록에 없는 지역은 빈 결과가 되고, 앱은 자동차 경로로 그리며 그 사실을 화면에
# 적는다 — 조용히 틀리지는 않는다. 노선이 목록 밖으로 나가면 정류장이 뭉텅 빠진 채
# 오는데, 그건 아래 `bus_route_stop_names` 가 이어짐을 검사해 걸러낸다.
#
# **비용.** 코드 하나가 요청 하나다. 35개를 동시 4로 물으면 7.6초 걸린다(요청당
# 평균 0.83초, 2026-08-25 실측). 경로를 만들 때만 나가고 프로세스가 사는 동안
# 캐시된다 — 귀가 중에는 저장된 좌표열을 쓰므로 요청이 없다.
BUS_SGG = {
    "41": [
        "41111", "41113", "41115", "41117",   # 수원시 장안구 · 권선구 · 팔달구 · 영통구
        "41131", "41133", "41135",            # 성남시 수정구 · 중원구 · 분당구
        "41150",                              # 의정부시
        "41171", "41173",                     # 안양시 만안구 · 동안구
        "41192", "41194", "41196",            # 부천시 원미구 · 소사구 · 오정구
        "41210",                              # 광명시
        "41220",                              # 평택시
        "41250",                              # 동두천시
        "41271", "41273",                     # 안산시 상록구 · 단원구
        "41281", "41285", "41287",            # 고양시 덕양구 · 일산동구 · 일산서구
        "41290",                              # 과천시
        "41310",                              # 구리시
        "41360",                              # 남양주시
        "41370",                              # 오산시
        "41390",                              # 시흥시
        "41410",                              # 군포시
        "41430",                              # 의왕시
        "41450",                              # 하남시
        "41461", "41463", "41465",            # 용인시 처인구 · 기흥구 · 수지구
        "41480",                              # 파주시
        "41500",                              # 이천시
        "41550",                              # 안성시
    ],
}


# ------------------------------------------------------------------ 지하철

SUBWAY_LINES_PATH = pathlib.Path(__file__).resolve().parent / "data" / "subway-lines.json"
_subway_lines = None

# 고른 구간이 **되돌아가는지** 보는 문턱. 경로 길이 / 두 끝 직선거리.
#
# 역번호는 노선 전체가 아니라 블록 안에서만 순서다. 경의중앙선은 지선(서울역·신촌)과
# 옛 코드 블록이 섞여 있어서 전체를 한 줄로 세우면 되돌아간다. 블록을 넘어 고르면
# 노선 밖으로 나갔다 돌아오느라 이 비가 폭발한다 — 지평 → 신촌은 58km 를 건너뛴다.
#
# 정상 구간은 1에 가깝다: 서강대 → 풍산이 19.5km / 18.7km = **1.04**(2026-08-26 실측).
# 2.0 은 여유다 — 실제 노선도 곧게만 가지는 않는다.
SUBWAY_DETOUR_LIMIT = 2.0

# **비만으로는 못 잡는다.** 건너뛴 방향이 가려는 방향과 같으면 비가 안 커진다 —
# 지평 → 서울역(경의선) → 신촌은 58km 를 건너뛰는데도 비가 1.02 다(시험이 잡아냈다).
# 그래서 이웃 간격도 본다. 지하철 역 사이가 이만큼 떨어지지는 않는다.
#
# 2026-08-26 실측 분포(이웃 쌍 1,053개): 중앙값 1,093m · 95% 5,618m · 98% 13,965m.
# 정상인데 긴 구간이 있다 — 인천국제공항선 청라국제도시→영종 10.1km, 동해선
# 일광→부산원동 13.6km. 그건 살리고 블록 점프(25km 이상)만 걸러야 해서 15km 로 둔다.
SUBWAY_MAX_GAP_METERS = 15_000


def subway_lines():
    """구워 둔 역 표. 한 번 읽고 들고 있는다."""
    global _subway_lines
    if _subway_lines is None:
        try:
            _subway_lines = json.loads(SUBWAY_LINES_PATH.read_text(encoding="utf-8"))
        except OSError:
            log("  지하철 역 표가 없다 — 지하철 구간은 직선으로 그려진다")
            _subway_lines = {}
    return _subway_lines


def _station_key(name):
    """이름을 맞추기 위한 정규화. 공백·가운뎃점을 빼고 끝의 `역` 을 뗀다.

    앱의 경로는 `서강대학교`·`풍산역` 인데 자료의 역사명은 `서강대역`·`풍산역` 이다.
    버스의 `stops_by_name` 이 같은 문제를 같은 방법으로 풀었다.
    """
    key = "".join((name or "").split()).replace("·", "").replace(".", "")
    return key[:-1] if key.endswith("역") and len(key) > 1 else key


def _find_station(stations, name):
    """정규화해서 같은 것을 먼저, 없으면 포함 관계를 **양쪽으로** 본다.

    한쪽만 보면 안 된다. 실제로 걸렸다(2026-08-26) — 경로에 적힌 이름이
    `서강대학교` 인데 자료의 역사명은 `서강대역` 이라, "자료 이름이 찾는 이름을
    포함하는가" 만 보면 `서강대학교` ⊄ `서강대` 라서 못 찾는다.

    반대 방향(찾는 이름이 자료 이름을 포함)은 헐거워서 짧은 역 이름에 잘못 걸릴 수
    있다(`서울대입구` 안에 `서울` 이 있다). 그래서 **가장 긴 것**을 고른다.
    """
    want = _station_key(name)
    if not want:
        return None
    for index, station in enumerate(stations):
        if _station_key(station["이름"]) == want:
            return index
    for index, station in enumerate(stations):
        if want in _station_key(station["이름"]):
            return index
    best = None
    for index, station in enumerate(stations):
        key = _station_key(station["이름"])
        if key and key in want and (best is None or len(key) > best[1]):
            best = (index, len(key))
    return best[0] if best else None


def subway_leg_stops(from_name, to_name):
    """두 역 사이의 역들을 순서대로. 돌려주는 것 — (노선명, [{name, lat, lon}]).

    못 찾으면 `(None, [])` 다. **오류가 아니다** — 앱은 그때 지금처럼 두 역 직선으로
    그리고 그 사실을 화면에 적는다. 짐작해서 엉뚱한 역을 넣지 않는다. 틀린 폴리라인은
    직선보다 나쁘다 — 직선은 최소한 틀린 줄 알지만 그건 맞는 것처럼 보인다.
    """
    best = None
    for line in subway_lines().values():
        stations = line["역"]
        start = _find_station(stations, from_name)
        end = _find_station(stations, to_name)
        if start is None or end is None or start == end:
            continue
        span = stations[start:end + 1] if start < end else stations[end:start + 1][::-1]
        if best is None or len(span) < len(best[1]):
            best = (line["이름"], span)
    if best is None:
        return None, []

    name, span = best
    gaps = [haversine(span[i]["lat"], span[i]["lon"],
                      span[i + 1]["lat"], span[i + 1]["lon"])
            for i in range(len(span) - 1)]
    if max(gaps) > SUBWAY_MAX_GAP_METERS:
        log(f"  지하철 {name} {from_name} → {to_name}: 역 사이가 "
            f"{int(max(gaps))}m 벌어진다 — 자료 없음으로 둔다")
        return None, []

    along = sum(gaps)
    straight = haversine(span[0]["lat"], span[0]["lon"], span[-1]["lat"], span[-1]["lon"])
    if straight <= 0 or along / straight > SUBWAY_DETOUR_LIMIT:
        log(f"  지하철 {name} {from_name} → {to_name}: 이어지지 않는다 "
            f"(경로 {int(along)}m / 직선 {int(straight)}m) — 자료 없음으로 둔다")
        return None, []

    return name, [{"name": s["이름"], "lat": s["lat"], "lon": s["lon"]} for s in span]


def bus_opr_ymd():
    """자료가 있는 운영일자. 한 번 찾아 두고 다시 찾지 않는다."""
    global _bus_opr_ymd
    if _bus_opr_ymd:
        return _bus_opr_ymd
    for ymd in BUS_OPR_YMD_CANDIDATES:
        if new_style_get(BUS_ROUTES, {"opr_ymd": ymd, "ctpv_cd": "41",
                                      "numOfRows": 1, "pageNo": 1}):
            _bus_opr_ymd = ymd
            log(f"  버스 노선 자료 운영일자 {ymd}")
            return ymd
    return None


def bus_route_ids(ctpv, route_no):
    """그 시도에서 이 노선번호를 쓰는 노선 id 들.

    노선번호로 거르는 파라미터가 없어서 시도를 통째로 받는다(경기 4,671개).
    무거운 요청이라 프로세스가 사는 동안 들고 있는다 — 노선표는 자주 안 바뀐다.
    """
    if ctpv not in _bus_routes:
        ymd = bus_opr_ymd()
        if not ymd:
            return []
        table = {}
        for page in range(1, 12):
            rows = new_style_get(BUS_ROUTES, {"opr_ymd": ymd, "ctpv_cd": ctpv,
                                              "numOfRows": 1000, "pageNo": page})
            if not rows:
                break
            for row in rows:
                no = str(row.get("rte_no") or "").strip()
                if no and row.get("rte_id"):
                    table.setdefault(no, []).append(row["rte_id"])
            if len(rows) < 1000:
                break
        _bus_routes[ctpv] = table
        log(f"  버스 노선표 {ctpv}: {len(table)}개 노선번호")
    return _bus_routes[ctpv].get(str(route_no), [])


def bus_route_stop_names(ctpv, route_no, here_names):
    """그 노선의 경유 정류장 이름을 순서대로.

    **정류장이 시군구별로 쪼개져 온다.** 999번은 일산동구 42개·덕양구 32개·
    일산서구 18개로 나뉘어 나왔다. 그래서 시군구마다 받아 `sttn_seq` 로 합친다.

    같은 노선번호가 여러 도시에 있다(999 는 고양과 수원에 있다). 그래서
    **출발 정류장을 지나는 노선**만 받아들인다 — 아니면 엉뚱한 좌표열이 나온다.
    """
    key = (str(route_no), ctpv)
    if key in _bus_route_stops:
        return _bus_route_stops[key]

    for rte_id in bus_route_ids(ctpv, route_no):
        merged = {}
        # 시군구마다 한 번씩 물어야 한다(노선이 구를 넘나든다). 순차로 하면
        # 요청 하나가 2~5초라 금세 20초가 된다 — 앱이 기다리는 시간이다.
        # 동시 요청은 4개까지만 둔다. 16개로 훑었을 때 공공데이터가 조용히
        # 실패를 섞어 보내 결과를 믿을 수 없었다(2026-08-20).
        def fetch(sgg, _rte=rte_id, _ctpv=ctpv):
            return new_style_get(BUS_ROUTE_STOPS, {
                "opr_ymd": bus_opr_ymd(), "ctpv_cd": _ctpv, "sgg_cd": sgg,
                "rte_id": _rte, "numOfRows": 500, "pageNo": 1})

        with futures.ThreadPoolExecutor(max_workers=4) as pool:
            for rows in pool.map(fetch, BUS_SGG.get(ctpv, [])):
                for row in rows or []:
                    seq, name = row.get("sttn_seq"), row.get("sttn_nm")
                    if seq is not None and name:
                        merged[int(seq)] = name
        if not merged:
            continue
        # **구멍 난 목록은 버린다.** 노선이 `BUS_SGG` 밖의 시군구를 지나면 그 구간의
        # 정류장이 통째로 빠진 채 온다 — 3500번(분당→서울)은 `sttn_seq` 0~82 중
        # 46개만 오고 37자리가 비었다(2026-08-25 확인). 그대로 이으면 빠진 구간을
        # 가로지르는 직선이 되고, 화면은 그걸 **실제 노선인 것처럼** 그린다.
        #
        # 자동차 폴백은 최소한 화면이 말해 준다("노선 자료 없음"). 말 없이 틀린
        # 길을 그리는 것이 그보다 나쁘다. 그래서 이어지지 않으면 없는 것으로 친다.
        span = range(min(merged), max(merged) + 1)
        if len(merged) != len(span):
            log(f"  버스 {route_no}: 경유 정류장이 이어지지 않는다 "
                f"({len(merged)}/{len(span)}개) — 자료 없음으로 둔다")
            continue
        names = [merged[k] for k in sorted(merged)]
        if here_names & set(names):
            _bus_route_stops[key] = names
            return names
    _bus_route_stops[key] = []
    return []


TAGO_BY_NAME = "https://apis.data.go.kr/1613000/BusSttnInfoInqireService/getSttnNoList"

_stops_by_name = {}


def stops_by_name(city, name):
    """그 도시에서 이름으로 정류장 찾기. 좌표가 함께 온다.

    **근접 조회 대신 이걸 쓴다.** 근접 조회는 반경이 고정이라 한 정류장 주변에서
    17개밖에 안 나오고, 500m 옆 정류장이 그 안에 없다(애니골입구가 그랬다).
    노선의 정류장 이름은 이미 알고 있으니 이름으로 묻는 것이 맞다.

    **부분 일치가 온다.** `애니골입구` 를 물으면 `약산마을.애니골입구` 가 온다.
    그래서 정규화해서 같은 것을 먼저 쓰고, 없으면 포함하는 것을 쓴다.
    """
    key = (city, name)
    if key in _stops_by_name:
        return _stops_by_name[key]
    if not TAGO_KEY or not city:
        return []

    query = urllib.parse.urlencode({
        "serviceKey": TAGO_KEY, "cityCode": city, "nodeNm": name,
        "numOfRows": 30, "pageNo": 1, "_type": "json",
    })
    rows = []
    for attempt in range(5):                 # 간헐적으로 오류 봉투가 온다. 여러 번 본다.
        try:
            with urllib.request.urlopen(f"{TAGO_BY_NAME}?{query}", timeout=10,
                                        context=outbound_tls()) as response:
                body = json.loads(response.read().decode("utf-8"))["response"]["body"]
            items = body.get("items") or {}
            found = items.get("item") if isinstance(items, dict) else None
            rows = (found if isinstance(found, list) else [found]) if found else []
            break
        except Exception:                                       # noqa: BLE001
            time.sleep(0.4 * (attempt + 1))

    out = [{"name": r["nodenm"], "lat": float(r["gpslati"]), "lon": float(r["gpslong"])}
           for r in rows if r and r.get("nodenm") and r.get("gpslati")]
    exact = [s for s in out if n_eq(s["name"], name)]
    result = exact or out
    # **빈 결과는 캐시하지 않는다.** 이 API 는 정상 요청에도 오류 봉투를 섞어
    # 보내는데, 그때의 빈손을 기억해 버리면 그 정류장이 영구히 빠진다. 실제로
    # `애니골입구` 한 곳이 그렇게 사라져 경유점이 7개에서 6개가 됐다.
    if result:
        _stops_by_name[key] = result
    return result


def bus_leg_waypoints(route_no, from_lat, from_lon, to_name, from_name=None):
    """버스 한 구간이 지나는 정류장 좌표열 — 탄 자리 다음부터 내릴 자리 앞까지.

    같은 이름이 길 양쪽에 있다(`풍산역` 은 다섯 곳이다). **직전 정류장에서 가장
    가까운 후보를 고른다** — 순서가 있으니 이어지는 쪽이 그 방향이다. 순환 노선의
    상행·하행도 이걸로 갈린다.

    빈 배열은 실패가 아니라 "그릴 것이 없다" 다. 부르는 쪽은 그때 자동차 경로로
    그린다 — 그게 지금까지의 동작이다.
    """
    here = nearby_stops(from_lat, from_lon, 20)
    if not here:
        return [], []
    here_names = {s["name"] for s in here}
    city = next((s["city"] for s in here if s.get("city")), None)

    for ctpv in BUS_CTPV:
        names = bus_route_stop_names(ctpv, route_no, here_names)
        if not names:
            continue
        # **탄 정류장을 이름으로 집는다.** 좌표 근처의 아무 정류장으로 기점을
        # 잡으면 한 정류장 앞에서 시작해, 첫 경유점이 탄 자리 자신으로 나온다
        # (풍산역 근처에 `밤가시7.8단지.광림교회` 가 있어서 실제로 그랬다).
        # 이름을 모르면(옛 클라이언트) 근처 정류장으로 폴백한다.
        # 이름으로 먼저 집고, 없으면 좌표 근처로 집는다.
        #
        # **이름이 노선 자료와 다를 수 있다.** 사용자가 구간 이름을 직접 적기
        # 때문이다 — `풍산역 정류장` 이라고 적었는데 노선 자료는 `풍산역` 이다.
        # 이름 매칭만 하면 그 구간이 통째로 폴백돼 자동차 경로가 된다.
        start = next((i for i, n in enumerate(names) if from_name and n_eq(n, from_name)), None)
        if start is None:
            start = next((i for i, n in enumerate(names) if n in here_names), None)
        if start is None:
            continue
        end = next((i for i in range(start + 1, len(names)) if n_eq(names[i], to_name)), None)
        if end is None:
            continue

        wanted = names[start + 1:end]
        # 이름마다 좌표를 물어야 한다. 어느 후보를 고를지는 순서대로 뒤에서
        # 정하고, **조회만 먼저 병렬로 채운다** — 순차로 하면 이름 일곱 개에
        # 20초가 넘고, 그 사이 앱이 먼저 끊어 자동차 경로로 저장된다.
        with futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda n: stops_by_name(city, n), set(wanted)))

        points, missing, lat, lon = [], [], from_lat, from_lon
        for name in wanted:
            cands = stops_by_name(city, name)
            if not cands:
                # 한 점 빠지는 것이 구간을 버리는 것보다 낫다. 다만 **조용히
                # 빠뜨리지는 않는다** — 부르는 쪽이 판단할 수 있게 이름을 돌려준다.
                missing.append(name)
                continue
            best = min(cands, key=lambda s: haversine(lat, lon, s["lat"], s["lon"]))
            lat, lon = best["lat"], best["lon"]
            points.append([round(lat, 5), round(lon, 5)])
        return points, missing
    return [], []


# --- 버스 실시간 도착 ------------------------------------------------------
#
# **왜 필요한가** — 경로에 적힌 `버스 10분` 은 저장할 때 잰 예정이다. 지금 그
# 버스가 어디 있다는 뜻이 아니라, 풍산역에 내리면 다른 지도 앱을 켜게 된다.
#
# **서비스가 따로다.** 정류소·노선과 같은 TAGO 인데 활용신청을 따로 받는다.
# 신청 전에는 같은 키로도 `403 SERVICE_KEY_IS_NOT_REGISTERED_ERROR` 가 온다
# (2026-08-26 에 실제로 겪었다 — 키가 죽은 줄 알기 쉽다).
#   https://www.data.go.kr/data/15098530/openapi.do
#
# **한도는 개발계정 10,000/일.** 정류소·노선 서비스(1,000)보다 열 배다.
#
# **서울 시내버스는 없다.** 163번 타는 곳(37.528330,126.917660) 좌표로 정류장을
# 조회하면 빈 결과다(2026-08-26 실측). 노선 자료의 구멍과 같은 자리다. 서울은
# 서울시 TOPIS(`ws.bus.go.kr`)에 있는데 별도 신청이 필요하다 — 지금 키로는 401 이다.
BUS_ARRIVAL = ("https://apis.data.go.kr/1613000/ArvlInfoInqireService"
               "/getSttnAcctoArvlPrearngeInfoList")

# 승차 좌표 → (도시코드, 정류장 id). 정류장은 세션 중에 바뀌지 않으니 영구 캐시다.
_arrival_stops = {}

# (도시코드, 정류장 id) → (잰 시각, 응답 줄들). 30초.
_arrival_rows = {}

# 도착정보를 얼마나 오래 재사용하는가. 짧을수록 정확하지만 호출이 는다.
# 30초면 승차 15분 전부터 한 구간에 최대 30회다(아래 `ARRIVAL_LEAD_SECONDS` 참고).
ARRIVAL_CACHE_SECONDS = 30


def tago_arrival_body(city_code, node_id):
    """정류장 도착정보 조회의 응답 본문. 실패하면 None.

    **HTTP 를 따로 뗀 이유는 시험이다.** `tago_stop_body` 와 같은 이유다 —
    시험이 이 함수만 갈아 끼우면 나머지 정규화 로직을 망 없이 잴 수 있다.
    """
    query = urllib.parse.urlencode({
        "serviceKey": TAGO_KEY, "cityCode": city_code, "nodeId": node_id,
        "numOfRows": 100, "pageNo": 1, "_type": "json",
    })
    try:
        with urllib.request.urlopen(f"{BUS_ARRIVAL}?{query}", timeout=8,
                                    context=outbound_tls()) as response:
            return json.loads(response.read().decode("utf-8"))["response"]["body"]
    except Exception as error:                              # noqa: BLE001
        log(f"  버스 도착정보 조회 실패: {error!r}")
        return None


def tago_arrival_rows(city_code, node_id):
    """그 정류장에 오는 버스들. 실패하면 빈 목록.

    **빈 목록은 실패가 아니다.** 막차가 끊겼거나, 자료에 없는 정류장이거나,
    호출이 실패한 것이다. 부르는 쪽은 그때 값을 안 싣고 화면은 줄을 안 그린다 —
    `/bus/leg` · `/subway/leg` 와 같은 계약이다.
    """
    if not TAGO_KEY:
        return []
    body = tago_arrival_body(city_code, node_id)
    if body is None:
        return []
    items = body.get("items") or {}
    rows = items.get("item") if isinstance(items, dict) else None
    if rows is None:
        return []
    return rows if isinstance(rows, list) else [rows]


def arrival_rows_cached(city_code, node_id, at):
    """`tago_arrival_rows` 를 30초 동안 재사용한다."""
    key = (city_code, node_id)
    cached = _arrival_rows.get(key)
    if cached and (at - cached[0]).total_seconds() < ARRIVAL_CACHE_SECONDS:
        return cached[1]
    rows = tago_arrival_rows(city_code, node_id)
    _arrival_rows[key] = (at, rows)
    return rows


def arrival_stop(lat, lon):
    """승차 좌표에 가장 가까운 정류장 → (도시코드, id). 못 찾으면 None.

    **같은 이름이 여럿이다.** 풍산역이라는 이름의 정류장이 다섯 곳이고 방향별로
    갈린다. 목록 순서를 믿지 않고 거리로 고른다 — 승차 좌표에서 잰 값이다
    (2026-08-26, `haversine`):

        GGB219000638     15.1m   ← 고르는 것
        GGB219001069     35.8m
        GGB219001032     51.6m
        GGB219000608    119.9m
        GGB219000606    133.9m

    **이 함수는 `route_no` 를 모른다.** 그 노선이 서는 정류장인지 안 보고 가장
    가까운 것만 고른다. `bus_leg_waypoints` 와 다른 점이 여기다 — 그쪽은 노선의
    경유 정류장 목록으로 후보를 먼저 거른 뒤 방향을 가린다.

    그래서 **승차 좌표로만 불러야 한다** — 경로에 저장된 버스 구간의 첫 점이다.
    다른 좌표(지금 GPS 같은)로 부르면 길 건너 반대 방향 정류장을 고를 수 있고,
    그 정류장에 같은 번호가 반대로 서면 틀린 시각이 나간다. 승차 좌표는 그 노선을
    실제로 탄 자리라 그 위험이 없다.

    노선이 안 서는 정류장을 골랐을 때는 `bus_arrival` 이 그 노선을 못 찾아
    None 이 된다. 틀린 값을 그리는 것보다 안 그리는 쪽이다.
    """
    key = (round(lat, 5), round(lon, 5))
    if key in _arrival_stops:
        return _arrival_stops[key]
    best = None
    for stop in nearby_stops(lat, lon, 20):
        if not stop.get("id") or stop.get("city") is None:
            continue
        gap = haversine(lat, lon, float(stop["lat"]), float(stop["lon"]))
        if best is None or gap < best[0]:
            best = (gap, (stop["city"], stop["id"]))
    found = best[1] if best else None
    if found:
        _arrival_stops[key] = found
    return found


def bus_arrival(lat, lon, route_no, now=None):
    """그 자리에서 탈 `route_no` 버스가 언제 오는가. 모르면 None.

    **절대시각을 돌려준다.** `몇 초 뒤` 가 아니다 — 화면이 그 글자를 그대로 들고
    있으면 갱신이 끊긴 동안 거짓말이 되기 때문이다. 정류장에 서서 기다리는 동안은
    위치 보고가 멈춘다(`distanceFilter` 가 150m 인데 풍산역에서 정류장까지가
    78m 다). 그 몇 분이 하필 이 값이 가장 필요한 순간이다.

    `expectedArrival` 이 이미 같은 규율로 쓰인다 — 절대시각을 주면 위젯이 스스로
    센다.
    """
    # 인자 이름이 모듈의 `now()` 를 가린다. 인자 이름을 바꾸면 부르는 쪽이
    # 헷갈리므로 여기서 `datetime` 을 직접 쓴다.
    at = now or datetime.now(timezone.utc)
    stop = arrival_stop(lat, lon)
    if not stop:
        return None
    city_code, node_id = stop
    want = str(route_no).strip()
    best = None
    for row in arrival_rows_cached(city_code, node_id, at):
        if str(row.get("routeno") or "").strip() != want:
            continue
        try:
            seconds = int(row.get("arrtime"))
        except (TypeError, ValueError):
            continue
        # 이미 지난 차다. 음수를 그대로 더하면 과거 시각이 나가고 화면이 0 에서
        # 멈춘 채로 남는다.
        if seconds < 0:
            continue
        if best is None or seconds < best[0]:
            best = (seconds, row)
    if best is None:
        return None
    seconds, row = best
    try:
        stops_left = int(row.get("arrprevstationcnt"))
    except (TypeError, ValueError):
        stops_left = None
    return {"no": want, "at": at + timedelta(seconds=seconds), "stops": stops_left}


def n_eq(a, b):
    """정류장 이름 비교. 표기 차이를 흡수한다.

    같은 정류장을 자료마다 다르게 적는다 — `아파트단지` 와 `아파트단지`,
    `환승로터리` 와 `환승로터리`. 점·쉼표·공백을 지우고 견준다.
    """
    trans = str.maketrans("", "", " .,·")
    return (a or "").translate(trans) == (b or "").translate(trans)


def outbound_tls():
    """바깥으로 나갈 때 쓸 TLS 문맥.

    개발용 맥이 TLS 를 검사하는 회사 프록시를 지난다. 그 프록시가 자체서명 루트로
    다시 서명해서 내밀기 때문에 파이썬 기본 검증이 깨진다. 그 루트는 맥 시스템
    키체인에 있으니, 맥에서 돌 때만 거기서 뽑아 함께 믿는다.

    **검증을 끄지 않는다.** 이 요청에는 서비스 키가 실려 나간다.
    배포 환경(리눅스 컨테이너)에서는 이 함수가 기본 문맥을 그대로 준다.
    """
    keychains = ["/System/Library/Keychains/SystemRootCertificates.keychain",
                 "/Library/Keychains/System.keychain"]
    chunks = []
    for keychain in keychains:
        if not os.path.exists(keychain):
            continue
        try:
            chunks.append(subprocess.run(
                ["security", "find-certificate", "-a", "-p", keychain],
                capture_output=True, text=True, timeout=20, check=True,
            ).stdout)
        except (OSError, subprocess.SubprocessError):
            continue
    if not chunks:
        return ssl.create_default_context()

    path = os.path.join(tempfile.gettempdir(), "homecoming-ca.pem")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(chunks))
    try:
        return ssl.create_default_context(cafile=path)
    except ssl.SSLError:
        return ssl.create_default_context()


# 서울시 버스정류소. 이름과 좌표를 함께 아는 유일한 자료다.
#
# 공공데이터포털의 버스정류장 API 는 이름은 주는데 좌표가 없고, TAGO 는 좌표를
# 주는데 서울 시내버스가 없다. 둘을 이어 붙일 공통 키도 없다. 그래서 서울 열린
# 데이터광장의 파일을 그대로 싣는다 — `Tools/seoul-stops.py` 로 만든다.
#
# 파일이 API 보다 나은 자리다. 요청 제한이 없고, 뜰 때 한 번 읽으면 검색이 즉시
# 끝난다. 정류장 위치는 자주 바뀌지 않는다.
SEOUL_STOPS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "data", "seoul-stops.json")


def load_seoul_stops():
    try:
        with open(SEOUL_STOPS_PATH, encoding="utf-8") as handle:
            rows = json.load(handle)
    except (OSError, ValueError) as error:
        log(f"  서울 정류소 자료 없음: {error!r}")
        return []
    return rows


SEOUL_STOPS = load_seoul_stops()


def seoul_nearby(lat, lon, limit=8, within=600):
    """이 좌표에서 `within` 미터 안의 서울 정류소, 가까운 순."""
    found = []
    for name, stop_lat, stop_lon, ars in SEOUL_STOPS:
        # 먼저 사각형으로 걸러 낸다. 1만 건에 haversine 을 다 돌릴 이유가 없다.
        if abs(stop_lat - lat) > 0.01 or abs(stop_lon - lon) > 0.013:
            continue
        distance = haversine(lat, lon, stop_lat, stop_lon)
        if distance <= within:
            found.append((distance, name, stop_lat, stop_lon, ars))
    found.sort()
    return [{"name": n, "lat": la, "lon": lo, "ars": ars, "meters": int(d)}
            for d, n, la, lo, ars in found[:limit]]


def seoul_search(text, limit=8):
    """이름으로 찾는다. 같은 이름이 방향별로 여럿이라 가까운 것부터가 아니라
    그냥 순서대로 준다 — 어느 쪽인지는 지도에서 고른다."""
    needle = text.strip()
    if len(needle) < 2:
        return []
    found = [s for s in SEOUL_STOPS if needle in s[0]]
    return [{"name": n, "lat": la, "lon": lo, "ars": ars}
            for n, la, lo, ars in found[:limit]]


def tago_stop_body(lat, lon, limit):
    """좌표 근접 정류소 조회의 응답 본문. 실패하면 None.

    **한 번 실패로 포기하지 않는다.** 이 API 는 정상 요청에도 오류 봉투를
    섞어 보낸다(`KeyError('response')` 로 드러난다). 한 번 실패하면 정류장이
    통째로 안 보이고, 사용자에게는 "그 자리에 정류장이 없다" 로 읽힌다.

    **HTTP 를 따로 뗀 이유는 시험이다.** 시험이 이 함수만 갈아 끼우면 나머지
    고르기 로직을 망 없이 잴 수 있다.
    """
    query = urllib.parse.urlencode({
        "serviceKey": TAGO_KEY, "gpsLati": lat, "gpsLong": lon,
        # 20 미만을 넣으면 간헐적으로 오류 봉투가 온다(실측). 반경이 고정이라
        # 크게 넣어도 결과가 늘지 않으니(17개가 상한이었다) 손해가 없다.
        "numOfRows": max(20, limit), "pageNo": 1, "_type": "json",
    })
    for attempt in range(3):
        try:
            with urllib.request.urlopen(f"{TAGO_STOPS}?{query}", timeout=8,
                                        context=outbound_tls()) as response:
                return json.loads(response.read().decode("utf-8"))["response"]["body"]
        except Exception as error:                          # noqa: BLE001
            if attempt == 2:
                log(f"  정류소 조회 실패({attempt + 1}회): {error!r}")
                return None
            time.sleep(0.5)
    return None


def nearby_stops(lat, lon, limit=8):
    """이 좌표 근처의 버스정류장. 이름과 좌표를 그대로 준다.

    `cityCode` 를 안 넣어도 된다 — 좌표만으로 찾아 준다. 도시코드 표를 들고 다닐
    필요가 없다는 뜻이라, 이 API 를 쓸 수 있게 만드는 결정적인 성질이다.

    서울 시내버스 정류장은 이 데이터에 없다(서울은 별도 TOPIS 를 쓴다). 다만 서울을
    지나는 광역·경기 버스 정류장은 들어 있어서, 서울 좌표로 물어도 쓸 만한 것이 나온다.
    """
    if not TAGO_KEY:
        return []
    body = tago_stop_body(lat, lon, limit)
    if body is None:
        return []

    items = body.get("items") or {}
    rows = items.get("item") if isinstance(items, dict) else None
    if rows is None:
        return []
    rows = rows if isinstance(rows, list) else [rows]
    return [
        {"name": r["nodenm"], "lat": r["gpslati"], "lon": r["gpslong"],
         "no": r.get("nodeno"),
         # **정류장 id.** 도착정보 API(`ArvlInfoInqireService`)가 `nodeId` 로 받는다.
         # 응답에 늘 있었는데 버리고 있었다.
         "id": r.get("nodeid"),
         # 도시코드. 이름으로 정류장을 다시 찾을 때 필요하다 — 좌표만으로 찾는
         # 근접 조회는 반경이 좁아서(실측 17개) 500m 옆 정류장이 안 잡힌다.
         "city": r.get("citycode")}
        for r in rows if r.get("nodenm") and r.get("gpslati")
    ]


def apns_trouble():
    """APNs 를 못 쓰는 이유. 쓸 수 있으면 None.

    이유를 나눠 주는 것이 중요하다 — 키가 없는 것과 도구가 없는 것은 고치는 법이
    전혀 다른데, `apns: false` 만 봐서는 구분할 수 없다.
    """
    missing = missing_tools()
    if missing:
        return f"도구 없음: {', '.join(missing)}"
    if not all([APNS_KEY, APNS_KEY_ID, TEAM_ID]):
        return "HOMECOMING_APNS_KEY(_P8)/_KEY_ID/HOMECOMING_TEAM_ID 가 필요하다"
    if not os.path.exists(APNS_KEY or ""):
        return f"키 파일이 없다: {APNS_KEY}"
    return None


def apns_configured():
    return apns_trouble() is None


# 이동 갱신이 APNs 안에서 살아 있을 시간(초).
#
# **낡은 위치는 위치가 없는 것보다 나쁘다.** 지하철에서 폰이 끊긴 동안 쌓인 갱신이
# 재접속 때 한꺼번에 내려오면, 그중 제일 늦게 도착한 것이 화면에 남는다. 순서를
# 보장하는 장치는 APNs 에 없다 (`aps.timestamp` 는 iOS 가 자동으로 비교해 주지
# 않는다). heartbeat 가 2분마다 제자리를 보고하므로, 3분 넘게 묵은 갱신은 곧 올
# 새 값보다 나쁘다. 버리는 게 맞다.
#
# 시작·도착·중지는 이 값을 쓰지 않는다. 그건 한 번뿐인 사건이라 늦게라도 닿아야 한다.
UPDATE_EXPIRATION_SECONDS = 180


def apns_push(token, payload, priority=10, expiration=3600):
    """푸시 한 건. 죽은 토큰(410)은 지운다.

    보내기 실패는 그 수신자만의 문제다. 다른 가족에게 보내는 것을 막지 않는다.

    **`priority` 는 10 을 기본으로 둔다.** 5 는 "전력을 아끼는 시점에 전달" 이라
    iOS 가 `expiration` 까지 붙잡아 둘 수 있다. 근거는 `update_activities` 주석에 있다.
    """
    if not apns_configured():
        log("  (APNs 미설정 — 전송 생략)", json.dumps(payload["aps"]["content-state"], ensure_ascii=False))
        return True

    # **한 수신자의 실패가 다른 수신자를 막지 않는다.** 이 함수는 가족마다 한 번씩
    # 불리는데, 여기서 예외가 새어 나가면 스레드가 통째로 죽어서 나머지 가족은
    # 알림을 아예 못 받는다. 실제로 컨테이너에 curl 이 없어 FileNotFoundError 가
    # 났고, 그 한 번으로 모든 알림이 사라졌다.
    try:
        result = subprocess.run(
            [
                "curl", "-sS", "--http2", "-X", "POST",
                f"https://{APNS_HOST}/3/device/{token}",
                "-H", f"authorization: bearer {apns_jwt()}",
                "-H", f"apns-topic: {BUNDLE_ID}.push-type.liveactivity",
                "-H", "apns-push-type: liveactivity",
                "-H", f"apns-priority: {priority}",
                "-H", f"apns-expiration: {int(time.time()) + expiration}",
                "-d", json.dumps(payload, ensure_ascii=False),
                "-D", "-", "-o", "/dev/stdout",
            ],
            capture_output=True,
            timeout=20,
        )
    except Exception as error:                              # noqa: BLE001
        log(f"  APNs 전송 실패({token[:8]}…): {error!r}")
        return False
    output = result.stdout.decode(errors="replace")

    if " 200 " in output.split("\n")[0]:
        return True

    if "410" in output or "BadDeviceToken" in output:
        db().execute("DELETE FROM activities WHERE token = ?", (token,))
        db().execute("UPDATE accounts SET start_token = NULL WHERE start_token = ?", (token,))
        db().commit()
        log("  죽은 토큰 폐기")
        return False

    log("  APNs 실패:", output.split("\n")[0].strip())
    return False


# ------------------------------------------------------------ 추정 · 판정

TRANSPORT_SPEED = {"walk": 70, "bus": 300, "car": 400, "subway": 480}   # m/분


# 경로 구간의 모드를 카드가 아는 교통수단으로 옮긴다.
#
# `wait`(환승 대기)는 교통수단이 아니다. 서 있는 동안 아이콘이 바뀌면 탄 것처럼
# 보이므로, 대기 중에는 **곧 탈 것**을 보여 준다 — 그게 사람이 기다리는 대상이다.
LEG_TRANSPORT = {"walk": "walk", "bus": "bus", "subway": "subway", "car": "car"}


def transport_of(legs, index):
    """그 구간에서 카드에 보여 줄 교통수단."""
    if not legs or index < 0:
        return None
    mode = legs[index].get("mode")
    if mode in LEG_TRANSPORT:
        return LEG_TRANSPORT[mode]
    # 대기 중이다. 다음 이동 구간을 앞당겨 보여 준다.
    for leg in legs[index + 1:]:
        if leg.get("mode") in LEG_TRANSPORT:
            return LEG_TRANSPORT[leg["mode"]]
    return None


def guess_transport(route_meters):
    """저장된 경로가 없을 때만 쓴다. 거리로 짐작한다.

    **경로가 있으면 짐작하지 않는다.** 짐작하면 전체 직선거리로 판단하게 되어,
    회사에서 역까지 걸어가는 첫 6분에도 "지하철" 이 뜬다. 카드 문구는 경로에서
    나오고 아이콘은 짐작에서 나오니, 한 카드 안에서 두 값이 어긋난다.
    """
    if route_meters <= 900:
        return "walk", "골목 도보"
    if route_meters <= 3_000:
        return "bus", "간선버스 이동 중"
    return "subway", f"지하철 · {max(1, round(route_meters / 1400))}정거장 남음"


def observed_speed(session_id):
    """최근 위치들로 실제 접근 속도(m/초)를 잰다.

    앱과 같은 생각이다 — 지면 속도가 아니라 **집에 가까워지는 속도**를 본다.
    근거가 얕으면 쓰지 않는다.
    """
    rows = db().execute(
        "SELECT at, remaining FROM fixes WHERE session_id = ? ORDER BY at DESC LIMIT 12",
        (session_id,),
    ).fetchall()
    if len(rows) < 2:
        return None

    newest, oldest = rows[0], rows[-1]
    t_new, t_old = parse_iso(newest["at"]), parse_iso(oldest["at"])
    if not t_new or not t_old:
        return None

    span = (t_new - t_old).total_seconds()
    closed = oldest["remaining"] - newest["remaining"]
    if span < 90 or closed < 150:
        return None
    if (now() - t_new).total_seconds() > FIX_FRESHNESS_SECONDS:
        return None

    speed = closed / span
    # 걷는 것보다 느리게 다가가는 중이면 이 관측으로 남은 여정을 예측할 수 없다.
    # 너무 빠르면 GPS 가 튄 것이다. 어느 쪽이든 교통수단 기반 추정이 낫다.
    if not (MIN_OBSERVED_SPEED <= speed <= MAX_OBSERVED_SPEED):
        return None
    return speed


def stage_for(remaining, previous, arrival_radius):
    """단계는 뒤로 가지 않는다. GPS 가 튀어도 가족이 혼란스럽지 않게."""
    nearby = max(arrival_radius * 5, 800)
    order = ["leaving", "moving", "nearby", "arrived"]
    if remaining < arrival_radius:
        candidate = "arrived"
    elif remaining < nearby:
        candidate = "nearby"
    else:
        candidate = "moving"
    return candidate if order.index(candidate) >= order.index(previous) else previous


def content_state(session):
    """모든 수신자에게 **똑같이** 나가는 값. 한 번 만들어 그대로 나눠 보낸다."""
    state = {
        "stage": session["stage"],
        "transport": session["transport"],
        "expectedArrival": session["expected_arrival"],
        "remainingMeters": int(session["remaining_meters"]),
        "totalMeters": int(session["total_meters"]),
    }
    # **경로 위에서 여기까지 왔다(m).** 노선도의 점과 지도의 지나온/남은 색 분리가
    # 이 값을 함께 쓴다 — 진행도를 **한 번만** 계산해 내려보낸다.
    #
    # `content_state` 를 한 번 만들어 수신자마다 그대로 보내는 이 파일의 방침을
    # 지도까지 넓히는 값이다. 앱이 `remaining_meters` 로 되짚던 것을 대신한다 —
    # 그 값은 이탈하면 직선거리로 **뜻이 바뀌어서** 노선도의 점을 앞으로 튀게 했다
    # (2026-08-20 실측: 60% 지점에서 1.5km 빠졌는데 점이 85% 로 전진).
    travelled = route_travelled(session)
    if travelled is not None:
        state["travelledMeters"] = travelled
    if session["detail"]:
        state["detail"] = session["detail"]
    if session["end_reason"]:
        state["endReason"] = session["end_reason"]
    # 저장된 경로 기준으로 밀린 시간. 1분 미만은 잡음이라 보내지 않는다 —
    # 가족 화면에 "지연 12초" 가 떴다 사라지면 고장으로 보인다.
    if session["delay_seconds"] and session["delay_seconds"] >= 60:
        state["delaySeconds"] = int(session["delay_seconds"])
    # **언제의 위치인가.** 배달 시각이 아니라 측정 시각이라, 갱신이 APNs 에 붙잡혀
    # 늦게 내려와도 화면이 "N분 전 확인" 을 제대로 적을 수 있다.
    if session["measured_at"]:
        state["measuredAt"] = session["measured_at"]
    # **귀가자의 지금 자리와 집.** 가족 화면이 지도에 점 두 개를 찍는 데 쓴다.
    #
    # 파생값(남은거리·단계)만 보내던 것에 좌표를 더한다. 거리는 "얼마나 남았나" 에
    # 답하지만 "어디쯤인가" 에는 답하지 못했다 — 지도가 필요한 이유가 그것이다.
    #
    # 둘 다 옵셔널이다. 첫 위치 보고 전에는 last_lat 이 비어 있고, 그때는 키를
    # 넣지 않는다. 앱은 좌표가 없으면 지도를 그리지 않는다.
    if session["last_lat"] is not None and session["last_lon"] is not None:
        state["lat"] = session["last_lat"]
        state["lon"] = session["last_lon"]
        # 집은 세션 안에서 바뀌지 않지만 갱신값에 같이 싣는다. 고정값
        # (attributes)에 넣으면 push-to-start 경로까지 건드려야 하고, 좌표 두
        # 개가 늘어난다고 4KB 한도에 가까워지지도 않는다.
        state["homeLat"] = session["home_lat"]
        state["homeLon"] = session["home_lon"]
        # 도착 반경. 지도가 집 주위에 원으로 그린다 — 단계가 `nearby` 로 바뀌는
        # 근거를 화면에서 볼 수 있게. 지금까지는 "곧 도착" 이 지리적 설명 없이
        # 나타났다. 판정에 쓰는 값과 그리는 값이 같아야 화면이 거짓말을 하지 않는다.
        state["homeRadius"] = int(session["home_radius"])
    # **어떻게 낸 값인지 밝힌다.** 앱은 자기가 경로로 시작한 것만 알고, 서버가 도중에
    # 이탈해 직선거리로 되돌아간 것은 모른다. 진단 화면이 `저장된 경로 (실측)` 이라고
    # 끝까지 적고 있었던 이유다(2026-08-18).
    #   route    — 저장된 경로를 따라 쟀다
    #   offRoute — 경로는 있는데 지금 벗어나 있다. **남은거리만** 직선이다 —
    #              도착예정은 경로의 시간 예산에서 그대로 나온다(2026-08-25)
    #   distance — 경로 없이 시작한 귀가다
    # 뒤의 둘을 뭉치면 "왜 직선거리인가" 를 화면에서 가릴 수 없다.
    if not session["route_id"]:
        state["estimateSource"] = "distance"
    else:
        state["estimateSource"] = "offRoute" if session["off_route"] else "route"
    return state


def attributes_for(session, audience, route_shape):
    """가족 액티비티 고정값.

    `route_shape` 는 호출자가 `route_shape_for(session)` 으로 미리 구해 넘긴다.
    가족이 여럿이면 이 함수가 링크 수만큼 불리는데, 세션이 같으니 노선도도
    매번 같다 — 여기서 다시 구하면 가족 수만큼 DB 조회와 크기 측정이
    되풀이된다. 세션당 한 번이면 되는 값이라 루프 밖에서 구해 들여보낸다.
    """
    out = {
        "travelerName": session["traveler_name"],
        "destinationName": session["home_name"],
        "departedAt": session["started_at"],
        "audience": audience,
        "sessionId": session["id"],
    }
    # 노선도. 귀가 중에 안 바뀌므로 갱신값이 아니라 고정값이다.
    # 경로 없이 시작한 귀가는 키를 넣지 않는다 — 앱이 지금 카드로 폴백한다.
    if route_shape:
        out["routeShape"] = route_shape
    return out


# --------------------------------------------------------- 가족에게 보내기

def 은는이가(name, 받침있음="이", 받침없음="가"):
    """이름 뒤에 붙는 조사를 고른다. **받침이 있으면 `이`, 없으면 `가`.**

    `f"{이름}이 집으로..."` 로 박아 두었더니 가족 폰 알림이 `아빠이 집으로
    출발했어요` 로 떴다(2026-08-25). 이름은 사용자가 적는 값이라 받침이 있는지
    없는지 미리 알 수 없다.

    한글 음절만 정확히 가른다 — 유니코드에서 `(코드 - 0xAC00) % 28` 이 0 이 아니면
    받침이 있다. 한글이 아닌 끝글자(영문·숫자·기호)는 받침 없음으로 본다. 짐작으로
    가르면 `Tom` 같은 이름에서 틀리는데, 그건 여기서 풀 문제가 아니다.
    """
    if not name:
        return name
    last = name.strip()[-1]
    if "가" <= last <= "힣":
        return name + (받침있음 if (ord(last) - 0xAC00) % 28 else 받침없음)
    return name + 받침없음

def watchers_of(traveler):
    return db().execute("SELECT * FROM links WHERE traveler = ?", (traveler,)).fetchall()


def start_activity_for(session, link, state=None, route_shape=None):
    """가족 한 명에게 push-to-start. 그 폰에 카드가 뜬다.

    `state` 와 `route_shape` 는 부르는 쪽이 미리 구해 넘길 수 있다. 가족이 여럿이면
    세션은 하나이므로 루프 밖에서 한 번만 구하는 게 맞다.
    """
    if state is None:
        state = content_state(session)
    if route_shape is None:
        route_shape = route_shape_for(session)

    account = db().execute(
        "SELECT start_token FROM accounts WHERE id = ?", (link["watcher"],)
    ).fetchone()
    if not account or not account["start_token"]:
        log(f"  {link['watcher_name']}: push-to-start 토큰 없음 — 건너뜀")
        return False

    payload = {
        "aps": {
            "timestamp": int(time.time()),
            "event": "start",
            "content-state": state,
            "attributes-type": "HomecomingAttributes",
            "attributes": attributes_for(session, "watcher", route_shape),
            "alert": {
                "title": "귀가 시작",
                "body": f"{은는이가(session['traveler_name'])} 집으로 출발했어요",
            },
        }
    }
    ok = apns_push(account["start_token"], payload)
    log(f"  {link['watcher_name']}에게 시작 알림 {'성공' if ok else '실패'}")
    return ok


def start_activities(session):
    """가족 각자에게 push-to-start. 이 순간 가족 폰에 알림이 뜬다."""
    rows = watchers_of(session["traveler"])
    if not rows:
        log(f"  세션 {session['id']}: 연결된 가족 없음")
        return

    # 가족이 몇 명이든 세션은 하나다 — 링크마다 다시 구하면 그 수만큼 DB 조회와
    # JSON 크기 측정이 되풀이된다. 루프 밖에서 한 번만 구해 나눠 쓴다.
    state = content_state(session)
    route_shape = route_shape_for(session)
    for link in rows:
        start_activity_for(session, link, state, route_shape)


def update_activities(session, alert=None):
    """이미 뜬 액티비티들에 새 상태를 밀어 넣는다."""
    state = content_state(session)
    rows = db().execute(
        "SELECT * FROM activities WHERE session_id = ?", (session["id"],)
    ).fetchall()

    sent = 0
    for row in rows:
        aps = {"timestamp": int(time.time()), "event": "update", "content-state": state}
        if alert:
            aps["alert"] = alert
        # **이동 갱신도 priority 10 이다.** 예전에는 5 였고, 그게 2026-08-18 실주행에서
        # 화면을 27분 낡게 만들었다 — 갱신 172건이 전부 APNs 200 을 받았는데(로그의
        # `2/2개 화면 갱신`), 18:28 에 폰이 그린 값은 서버가 18:01 에 갖고 있던
        # 21950m 였다. priority 5 는 "전력을 아끼는 시점에 전달" 이라 iOS 가 만료
        # 시각까지 붙잡아 둘 수 있다.
        #
        # `2/2개 화면 갱신` 은 **APNs 가 접수했다**는 뜻일 뿐 화면이 바뀌었다는 뜻이
        # 아니다. 이 로그만 보고 "전부 닿았다" 고 읽으면 안 된다.
        #
        # **전달 시점(priority)과 알림 소음(alert)은 다른 축이다.** 조용히 갱신하려면
        # `alert` 를 비우면 되고, priority 를 낮출 이유가 없다. 예산 문제도 아니다 —
        # `NSSupportsLiveActivitiesFrequentUpdates` 가 `App/Info.plist` 에 켜져 있다.
        if apns_push(row["token"], {"aps": aps}, priority=10,
                     expiration=3600 if alert else UPDATE_EXPIRATION_SECONDS):
            sent += 1

    if rows:
        # **보낸 수가 아니라 닿은 수를 찍는다.** 시도한 횟수를 성공처럼 적으면
        # 로그가 거짓말을 한다 — `/health` 가 `apns: true` 라고 하면서 실제로는
        # 한 건도 못 쏘던 것과 같은 종류의 고장이다.
        db().execute("UPDATE sessions SET updates_sent = updates_sent + ? WHERE id = ?",
                     (sent, session["id"]))
        db().commit()
        mark = "" if sent == len(rows) else f" (실패 {len(rows) - sent})"
        log(f"  {sent}/{len(rows)}개 화면 갱신{mark} · {state['stage']} · {state['remainingMeters']}m")


# 도착 카드를 잠금화면에 남겨 두는 시간. 앱의 `arrivedLingerSeconds` 와 같아야
# 귀가자와 가족 화면이 동시에 사라진다.
ARRIVED_LINGER_SECONDS = 300


def end_activities(session):
    """도착 또는 중지. 아일랜드는 end 를 받는 순간 알림을 치우므로
    도착 상태를 먼저 보여 준 뒤(update) 끝낸다."""
    state = content_state(session)
    rows = db().execute(
        "SELECT * FROM activities WHERE session_id = ?", (session["id"],)
    ).fetchall()

    arrived = session["end_reason"] == "arrived"
    alert = {
        "title": "도착" if arrived else "공유 중지",
        "body": (
            f"{은는이가(session['traveler_name'])} {session['home_name']}에 도착했어요"
            if arrived
            else f"{은는이가(session['traveler_name'])} 위치 공유를 껐어요"
        ),
    }

    for row in rows:
        apns_push(row["token"], {"aps": {
            "timestamp": int(time.time()), "event": "update",
            "content-state": state, "alert": alert,
        }})

    arrived_at = time.time()

    def finish():
        # **도착 카드를 끝내는 주인은 서버다.**
        #
        # `end` 를 보내는 순간 다이나믹 아일랜드는 즉시 치운다 — `dismissal-date` 는
        # 잠금화면에만 듣는다. 그래서 두 화면을 같이 5분 띄우려면 5분 동안 `end` 를
        # 안 보내는 수밖에 없다.
        #
        # 앱은 그걸 못 한다. 도착은 대개 백그라운드에서 판정되고 iOS 어시션은 30초쯤
        # 이면 만료돼 앱이 잠든다. 서버는 안 잠기니 여기서 잔다.
        #
        # 가족이 그 순간 폰을 보고 있을 확률이 낮다. 알림음을 놓치면 카드가 사라진
        # 뒤에 폰을 보게 되고, 도착한 것인지 앱이 죽은 것인지 구분할 수 없다.
        time.sleep(ARRIVED_LINGER_SECONDS)
        for row in rows:
            apns_push(row["token"], {"aps": {
                "timestamp": int(time.time()), "event": "end",
                "content-state": state,
                # 이미 그만큼 기다렸다. 지금 치운다.
                "dismissal-date": int(time.time()),
            }})
        db().execute("DELETE FROM activities WHERE session_id = ?", (session["id"],))
        db().commit()
        log(f"  세션 {session['id']} 알림 정리 완료")

    threading.Thread(target=finish, daemon=True).start()


# ------------------------------------------------------------------ 세션

def route_of(session):
    """세션에 붙은 저장 경로. 없으면 None."""
    if not session["route_id"]:
        return None
    row = db().execute("SELECT * FROM routes WHERE id = ?", (session["route_id"],)).fetchone()
    if not row:
        return None
    return {"total_seconds": row["total_seconds"], "legs": json.loads(row["legs"])}


def short_place(name):
    """카드 한 줄에 들어갈 만큼 줄인 장소 이름.

    한국 정류장 이름은 `역명.랜드마크` 로 붙는 경우가 많다 —
    "출발역.은행앞", "월드컵파크7단지.상암초등학교". 카드 한 줄에는 안
    들어가서 실기기에서 "국회의사당.KB국민 …" 으로 잘렸다. 잘린 이름은 안 잘린
    이름보다 나쁘다. 어디인지 알아볼 수 없기 때문이다.

    사람이 말할 때는 앞부분만 쓴다. 그래서 점에서 자른다.
    """
    if not name:
        return name
    head = name.split(".")[0].strip()
    return head or name


def leg_length(leg):
    """구간 좌표열의 길이(m). 대기 구간은 0 이다."""
    points = leg.get("points") or []
    return sum(haversine(a[0], a[1], b[0], b[1]) for a, b in zip(points, points[1:]))


def route_length(legs):
    """경로 전체 길이(m). 좌표열을 따라 잰다."""
    return int(sum(leg_length(leg) for leg in legs))


# 액티비티 시작 푸시는 APNs 4KB 한도를 받는다. 고정값에는 이름·시각도 함께
# 들어가므로 노선도에 전부를 주지 않는다. 10구간이 600바이트 남짓이다.
ROUTE_SHAPE_MAX_BYTES = 3_000


def route_stops(legs):
    """구간을 노선도에 찍을 정류장 목록으로 접는다.

    **대기 구간은 점을 만들지 않는다.** 대기는 앞 구간과 같은 자리라, 점을 따로
    찍으면 노선도에 같은 자리가 두 번 나온다. 앞 정류장의 `waitSeconds` 로 붙는다.
    그래서 10구간이 점 7개가 된다.

    **거리는 `leg_length()` 로 잰다. 저장된 `meters` 필드가 아니다.**
    `route_length()` 가 좌표열로 재므로 다른 자를 쓰면 정류장 거리의 합이
    `totalMeters` 와 어긋난다.

    **자르기는 구간마다 하지 않고 누적값에서 한다.** `int(leg_length(leg))` 를
    구간마다 반올림해 버리면 소수점 아래가 구간 수만큼 쌓여 `route_length()` 의
    결과와 어긋난다 (실측: 7구간에서 2m 차이). `route_length()` 가 전체를 먼저
    더하고 마지막에 한 번만 자르는 것과 같은 자리에서 잘라야, 정류장 거리의 합이
    `totalMeters` 와 정확히 같아진다. 안 맞으면 노선도의 점이 마지막 정류장에서
    밀린다.
    """
    stops = []
    traveled = 0.0   # 지금까지 지난 실제 거리(m, 소수)
    covered = 0      # 그중 이미 정류장에 나눠 준 정수 미터
    for leg in legs or []:
        if leg.get("mode") == "wait":
            # 붙일 앞 정류장이 없으면 버린다. 노선도는 출발점을 점으로 그리지
            # 않으므로 보여 줄 자리가 없다.
            if stops:
                stops[-1]["waitSeconds"] += int(leg.get("seconds") or 0)
            continue
        traveled += leg_length(leg)
        cut = int(traveled)             # route_length() 와 같은 자리에서 자른다
        stops.append({
            "name": leg.get("toName") or "",
            "mode": leg.get("mode") or "walk",
            "meters": cut - covered,
            "seconds": int(leg.get("seconds") or 0),
            "waitSeconds": 0,
        })
        covered = cut
    return stops


def route_geometry(legs):
    """경로를 지도에 그릴 형태로 — 좌표열과 정류장 좌표.

    **`route_stops()` 와 따로 두는 이유는 크기다.** 그쪽은 액티비티 푸시에 실려
    `ROUTE_SHAPE_MAX_BYTES`(3,000) 예산 안에 들어가야 한다. 좌표를 그쪽에 얹으면
    샘플 경로만 해도 5,283바이트라 예산을 넘겨 **노선도가 통째로 빠진다**
    (`route_shape_payload` 가 None 을 준다). 잠금화면이 조용히 달라지는 것이
    이 프로젝트가 제일 싫어하는 실패다. 그래서 지도용 좌표는 푸시가 아니라
    앱이 직접 받아 가는 길로 보낸다 — 그쪽에는 4KB 한도가 없다.

    폴리라인은 구간 좌표열을 이어붙인 것이다. 이어 붙일 때 두 가지를 걸러낸다 —
      대기 구간: 앞 구간과 같은 자리에 점 하나뿐이라 선에 보탤 것이 없다
      맞닿은 중복점: 앞 구간의 끝과 뒤 구간의 시작이 같은 점이다
    걸러도 선의 모양은 같고, 바이트만 줄어든다.
    """
    line = []
    stops = []
    segments = []
    for leg in legs or []:
        if leg.get("mode") == "wait":
            # 대기는 자리를 옮기지 않는다. 앞 정류장에 대기 시간만 붙인다 —
            # `route_stops()` 와 같은 규칙이라야 노선도와 지도가 같은 말을 한다.
            if stops:
                stops[-1]["waitSeconds"] += int(leg.get("seconds") or 0)
            continue

        points = leg.get("points") or []
        piece = []
        for point in points:
            spot = [round(float(point[0]), 5), round(float(point[1]), 5)]
            piece.append(spot)
            if line and line[-1] == spot:
                continue                      # 구간이 맞닿은 자리
            line.append(spot)

        # **구간별로도 따로 담는다.** 앱이 도보 구간을 점선으로 그린다(네이버
        # 지도가 그렇게 한다). 이어붙인 `line` 만으로는 어디가 도보인지 알 수 없다.
        #
        # `line` 을 없애지 않고 함께 보낸다 — 옛 빌드가 그것으로 선을 그리고,
        # 카메라와 지나온/남은 구간 계산도 그것을 쓴다. HTTP 채널이라 4KB 한도가
        # 없어서 둘을 같이 보내도 무해하다(합쳐 12KB 남짓).
        if len(piece) >= 2:
            segments.append({"mode": leg.get("mode") or "walk", "points": piece})

        # 정류장의 자리는 그 구간의 마지막 점이다. 이름이 붙는 지점이 곧 도착점이다.
        if points:
            stops.append({
                "name": leg.get("toName") or "",
                "mode": leg.get("mode") or "walk",
                "lat": round(float(points[-1][0]), 5),
                "lon": round(float(points[-1][1]), 5),
                "waitSeconds": 0,
            })

    return {"polyline": line, "segments": segments, "stops": stops}


def route_shape_payload(stops):
    """정류장 목록을 액티비티에 실을 형태로. 너무 크면 None.

    `route_shape_for` 에서 DB 조회를 뺀 부분이다. 크기 판단이 이 작업에서
    제일 위험한 자리다 — 초과했는데도 안 빠지거나, 이유 없이 빠지면 가족
    화면이 설명 없이 달라진다. 그래서 DB 없이 시험할 수 있게 갈라 둔다.
    """
    if not stops:
        return None
    size = len(json.dumps({"stops": stops}, ensure_ascii=False).encode("utf-8"))
    if size > ROUTE_SHAPE_MAX_BYTES:
        log(f"  노선도 {size}바이트 — {ROUTE_SHAPE_MAX_BYTES} 초과라 뺀다 "
            f"(정류장 {len(stops)}개). 가족은 카드를 본다")
        return None
    return {"stops": stops}


def route_shape_for(session):
    """세션이 쓰는 경로의 노선도.

    None 은 두 경우다 — 세션에 경로가 없거나(`route_of` 가 None), 있어도
    `route_shape_payload` 가 크기 초과로 뺐거나. `attributes_for` 에
    `routeShape` 가 왜 안 들어왔는지 추적할 때 이 두 갈래를 구분해야 한다.
    """
    try:
        route = route_of(session)
    except (TypeError, ValueError):
        return None
    if not route:
        return None
    return route_shape_payload(route_stops(route["legs"]))


def route_remaining(legs, progress):
    """지금 진행(초)에서 경로 끝까지 남은 거리(m).

    **직선거리를 쓰면 안 되는 이유가 이 앱에 특히 크다.** 이 귀가 경로는 집 쪽으로
    곧장 가지 않는다 — 여의도에서 신촌으로 동북쪽으로 갔다가 서북쪽 일산으로
    꺾는다. 환승로터리에서 서강대역까지 7분 걷는 동안 집에는 300m 밖에 가까워지지
    않는다. 직선으로 재면 진행 바가 한참 멈춰 있다가 갑자기 뛴다.

    자동차 경로 거리도 아니다. 그 사람은 차를 타지 않는다.

    경로를 갖고 있으니 그 위에서 재면 된다. 구간 안에서는 시간 비례로 나눈다 —
    좌표열의 어느 점에 있는지까지 따질 값어치는 없다. 진행 바에 쓰는 값이다.
    """
    remaining = 0.0
    for leg in legs:
        ends_at = leg["startsAt"] + leg["seconds"]
        if ends_at <= progress:
            continue                      # 지나온 구간
        length = leg_length(leg)
        if leg["startsAt"] >= progress:
            remaining += length           # 아직 시작 안 한 구간
        elif leg["seconds"] > 0:
            done = (progress - leg["startsAt"]) / leg["seconds"]
            remaining += length * max(0.0, 1.0 - done)
    return int(remaining)


def same_journey(existing, route_id, lat, lon):
    """진행 중인 세션을 이어 쓸 것인가.

    경로가 같으면 같은 귀가로 본다. **경로가 없으면 출발지도 본다** — 경로 없는
    귀가의 전체거리는 출발 시점의 직선거리라, 다른 도시에서 다시 시작한 것을 같은
    세션에 이어붙이면 분모가 옛 출발지 기준으로 남는다. 일산에서 눌러 6.7km 로
    시작한 세션에 여의도(19.6km)에서 다시 누르면 남은거리가 분모를 넘어 진행 바가
    깨진다(2026-08-21).

    문턱은 `stage_for` 의 `nearby` 와 같은 값이다 — 새 숫자를 만들지 않는다.
    그 거리 안에서 다시 누른 것은 같은 자리에서 다시 누른 것으로 본다(앱이 죽어
    다시 켠 경우가 그렇다).

    출발 좌표를 안 보낸 앱이면 판단할 재료가 없으니 예전처럼 이어 쓴다.
    """
    if (existing["route_id"] or None) != (route_id or None):
        return False
    if existing["route_id"] or lat is None or existing["last_lat"] is None:
        return True
    moved = haversine(lat, lon, existing["last_lat"], existing["last_lon"])
    return moved <= max(existing["home_radius"] * 5, 800)


def widen_total(session, straight):
    """전체거리를 남은거리보다 작지 않게 넓힌다. 넓혔으면 갱신된 행을 돌려준다.

    경로 없는 귀가의 전체거리는 출발 시점의 직선거리다. 집 반대쪽으로 먼저 가는
    길이면(주차장·역까지 걸어 나가는 방향) 남은거리가 그 값을 넘어서고, 그러면
    진행 바가 0 에 붙어 아무리 가도 안 움직인다 — 2026-08-20 실주행 로그에서
    남은거리가 5,813m → 6,721m 로 늘어나는 것을 봤다.

    **줄이지는 않는다.** 가까워질 때마다 분모가 따라 줄면 진행률이 늘 같은 자리에
    머문다. 앱도 같은 규칙이다(`HomecomingActivityManager.update` 의
    `max(previous.totalMeters, meters)`).
    """
    if session["total_meters"] >= int(straight):
        return session
    db().execute("UPDATE sessions SET total_meters = ? WHERE id = ?",
                 (int(straight), session["id"]))
    db().commit()
    return db().execute("SELECT * FROM sessions WHERE id = ?", (session["id"],)).fetchone()


def route_travelled(session):
    """경로 위에서 여기까지 온 거리(m). 경로 없이 시작한 귀가면 None.

    **`remaining_meters` 의 짝이 아니다.** 그 값은 이탈하면 집까지 직선거리로
    바뀌므로 `route_length() - remaining_meters` 는 이탈한 순간 뜻을 잃는다.
    여기는 `route_progress` 만 본다 — 그것은 경로 위에서만 정의되고, 뒤로 가지
    않으며(`recompute` 의 `max(progress, ...)`), 이탈하면 갱신이 멈춘다.

    그래서 이탈 중에는 이 값이 **그 자리에 선다.** 화면은 지나온 표시를 거기
    멈춰 두고 귀가자 점만 선 밖으로 내보내 이탈을 눈에 보이게 한다.

    **도착하면 전체 길이다.** `route_progress` 는 끝까지 가지 않는다 — 도착 판정은
    거리로 하고(`stage_for`), 그때 `recompute` 가 `remaining_meters` 만 0 으로
    내린다. 진행만 보면 도착한 뒤에도 마지막 구간이 남은 것으로 그려진다.
    """
    try:
        route = route_of(session)
    except (TypeError, ValueError):
        return None
    if not route:
        return None
    total = route_length(route["legs"])
    if session["stage"] == "arrived":
        return total
    return max(0, total - route_remaining(route["legs"], session["route_progress"]))


def leg_sentence(leg, expected_elapsed):
    """가족 카드에 실을 한 줄.

    "남은거리 8.2km" 는 기다리는 사람에게 쓸모가 적다. 알고 싶은 건 지금 어디쯤
    이고 언제 오는지다. 저장된 경로가 있으면 그걸 말할 수 있다.

        지하철 · 풍산역까지 12분
        환승 대기
    """
    label = leg.get("label") or leg.get("mode") or "이동"
    if leg.get("mode") == "wait":
        return label

    # **수단 이름을 넣지 않는다.** 카드 왼쪽 아이콘이 이미 그것을 말한다.
    # 좁은 한 줄에 같은 말을 두 번 쓰면 정류장 이름이 잘린다 — 실기기에서
    # "도보 · 국회의사당역까지…" 로 끊겼다.
    left = leg["startsAt"] + leg["seconds"] - expected_elapsed
    to_name = short_place(leg.get("toName"))
    if to_name and left > 30:
        return f"{to_name}까지 {max(1, round(left / 60))}분"
    if to_name:
        return f"{to_name} 도착"
    return label


def leg_index_at(legs, elapsed):
    """경과 시각이 속한 구간의 번호."""
    found = 0
    for index, leg in enumerate(legs):
        if leg["startsAt"] <= elapsed:
            found = index
    return found


def leg_at(legs, elapsed):
    """경과 시각이 속한 구간.

    문구는 **진행에서 만든다.** 가장 가까운 좌표의 구간에서 만들면 GPS 가 흔들릴 때
    "환승로터리 도착" → "서강대역까지 3분" → "환승로터리 도착" 처럼 뒤로 간다.
    진행은 뒤로 가지 않으니 여기서 만든 문구도 뒤로 가지 않는다.
    """
    return legs[leg_index_at(legs, elapsed)] if legs else None


def where_on_route(legs, lat, lon, progress):
    """위치가 경로의 어디쯤인가.

    돌려주는 것 — (경로 기준 기대 경과초, 경로까지의 거리)

    **이게 위치가 하는 일 전부다.** 남은 시간을 예측하지 않는다. 저장된 경로의
    어느 지점에 있는지만 찾는다. 구간이 km 단위라 정확도가 150m 여도 맞힌다.

    구간 안 진행은 **거리 누적**으로 잰다. 좌표 개수로 나누면 안 된다 — 도로
    좌표는 커브에서 촘촘하고 직선에서 드물어서, 개수로 나누면 진행이 뚝뚝 끊긴다.

    **이미 끝난 구간은 후보에서 뺀다.** 전 구간에서 찾으면 겹치는 길에서 막힌다.
    버스가 환승로터리까지 온 길과 거기서 서강대역까지 걷는 326m 가 같은 길이라,
    걷는 동안에도 버스 구간의 마지막 점이 계속 가장 가깝다. 그 점의 시각은 "버스가
    끝난 순간" 이니 진행이 그 자리에 멈추고, 실제 시계만 흘러서 없던 지연이 4분까지
    쌓였다. 내린 구간의 점은 더 볼 이유가 없다.

    앞으로는 좁히지 않는다. "지금 구간과 다음 하나" 로 좁혀 봤더니 환승 대기 구간이
    좌표 하나로 그 창의 한 칸을 잡아먹어서, 버스를 타고 있는데 후보에 버스 구간이
    없어 경로 이탈로 떨어졌다.
    """
    if not legs:
        return None

    best = None
    for leg in legs:
        # 끝난 구간은 보지 않는다. 진행이 그 구간을 지났다는 뜻이다.
        if leg["startsAt"] + leg["seconds"] <= progress:
            continue
        points = leg.get("points") or []
        if not points:
            continue

        # 구간 좌표의 누적 거리. 이걸로 나눠야 진행이 매끄럽다.
        marks = [0.0]
        for i in range(1, len(points)):
            marks.append(marks[-1] + haversine(*points[i - 1], *points[i]))
        span = marks[-1] or 1.0

        for index, point in enumerate(points):
            gap = haversine(lat, lon, point[0], point[1])
            if best is None or gap < best[1]:
                expected = leg["startsAt"] + leg["seconds"] * (marks[index] / span)
                best = (expected, gap)
    return best


def recompute(session, lat, lon, at):
    """위치 하나가 들어왔을 때 세션 상태를 다시 계산한다."""
    straight = haversine(lat, lon, session["home_lat"], session["home_lon"])
    radius = max(session["home_radius"], MIN_ARRIVAL_RADIUS)

    db().execute(
        "INSERT INTO fixes (session_id, lat, lon, at, remaining) VALUES (?, ?, ?, ?, ?)",
        (session["id"], lat, lon, iso(at), straight),
    )
    # 최근 것만 남긴다. 경로 전체를 들고 있을 이유가 없다.
    db().execute(
        """DELETE FROM fixes WHERE rowid IN (
               SELECT rowid FROM fixes WHERE session_id = ?
               ORDER BY at DESC LIMIT -1 OFFSET ?)""",
        (session["id"], FIX_WINDOW),
    )

    stage = stage_for(straight, session["stage"], radius)
    transport, detail = guess_transport(straight)

    # --- 도착예정 -----------------------------------------------------------
    #
    # 저장된 경로가 있으면 **도착예정은 계산하지 않는다.** 아는 값이다.
    #   출발 시각 + 저장된 총 소요시간 + 지연
    # 위치는 어느 구간인지 찾아서 지연을 재는 데만 쓴다. 지하철에서 위치가
    # 부정확해도 도착예정이 흔들리지 않는다. 애초에 위치로 나누는 게 아니다.
    route = route_of(session)
    route_left = None
    # **못 구했으면 None 이다.** 예전에는 초기화가 없어서, 아래 폴백이 `route_left`
    # 가 None 인지로 "도착예정을 구했는가" 를 대신 판단했다. 둘은 이제 다른 질문이다 —
    # 이탈하면 남은거리는 경로에서 못 구해도(`route_left is None`) 도착예정은 구한다.
    arrival = None
    delay = session["delay_seconds"]
    off_route = bool(session["off_route"])
    progress = session["route_progress"]

    # **이탈은 상태가 아니라 지금 거리의 함수다.**
    #
    # 예전에는 `if route and not off_route:` 였다. `off_route` 를 False 로 되돌리는
    # 코드가 한 줄도 없었으므로 한 번 걸리면 세션이 끝날 때까지 이 블록에 다시 들어오지
    # 못했다. 2026-08-18 실주행에서 지하철 GPS 가 1043m 튀어 문턱(1000m)을 43m 넘긴
    # 순간 걸렸고, **남은 49분 전체가 직선거리 폴백으로 돌았다** — 이 앱이 없애려고
    # 만든 바로 그 값이다. 구간 문구("풍산역까지 30분")와 노선도의 점도 그 순간에
    # 얼어붙어 25분 뒤 화면까지 그대로 남았다.
    #
    # 이제는 매 보고마다 다시 잰다. 튐 한 번이 남은 여정을 망치지 않는다.
    if route:
        elapsed = (at - parse_iso(session["started_at"])).total_seconds()
        spot = where_on_route(route["legs"], lat, lon, progress)
        if spot:
            expected_elapsed, gap = spot
            if off_route:
                if gap <= OFF_ROUTE_REJOIN_METERS:
                    off_route = False
                    log(f"  경로 복귀 {int(gap)}m — 저장된 경로로 다시 잰다")
            elif gap > OFF_ROUTE_METERS:
                off_route = True
                log(f"  경로 이탈 {int(gap)}m — 남은거리만 직선으로 잰다"
                    f"(도착예정은 경로의 시간 예산 그대로)")

            if not off_route:
                # 경로 진행은 뒤로 가지 않는다. GPS 가 흔들려서 가장 가까운 좌표가
                # 앞뒤로 튀면 지연과 문구가 깜박이는데, 사람은 되돌아가지 않았다.
                progress = max(progress, int(expected_elapsed))
                measured = max(0, elapsed - progress)
                delay = int(delay + (measured - delay) * DELAY_SMOOTHING)
                index = leg_index_at(route["legs"], progress)
                here = leg_at(route["legs"], progress)
                detail = leg_sentence(here, progress) if here and stage != "arrived" else None
                # 교통수단도 구간에서 온다. 짐작하지 않는다.
                transport = transport_of(route["legs"], index) or transport
                remaining_seconds = route["total_seconds"] + delay - elapsed
                arrival = now() + timedelta(seconds=max(30, remaining_seconds))
                # 남은거리도 경로에서 온다. 직선으로 재면 이 경로처럼 집 쪽으로
                # 곧장 가지 않는 경로에서 진행 바가 한참 멈춰 있다가 갑자기 뛴다.
                route_left = route_remaining(route["legs"], progress)
            else:
                # **이탈해도 도착예정은 경로에서 낸다.**
                #
                # 이 값은 `총소요시간 + 지연 − 경과시간` 이라 **위치를 아예 안 쓴다.**
                # 위치가 벗어났다고 시간 계산까지 버릴 이유가 없다.
                #
                # 2026-08-25 실주행이 그 근거다. 18:09 에 1,105m 로 이탈해 도착까지
                # 39분을 직선거리 추정으로 돌았는데 —
                #
                #   저장된 경로의 예정  18:54   ← 실제 도착 18:48:39 과 6분 차이
                #   직선 폴백의 예정    ~18:30  ← 18분 차이
                #
                # 폴백이 더 나쁜 값으로 덮었다. 게다가 그 값이 앞당겨지면서 가족이
                # 도착한 줄 알았다.
                #
                # 남은거리는 그대로 직선이다(`route_left` 를 안 채운다). 경로 위
                # 어디인지 모르는 채로 경로 거리를 말하면 그게 거짓이 된다 —
                # 시간은 경과로 알 수 있지만 자리는 알 수 없다. `travelledMeters` 도
                # 같은 이유로 그 자리에 선다.
                #
                # `delay` 는 마지막으로 경로 위에 있었을 때 값에 멈춰 있다. 이탈
                # 중에는 갱신할 근거가 없으니 그게 맞다.
                arrival = now() + timedelta(
                    seconds=max(30, route["total_seconds"] + delay - elapsed))

    # **경로값을 못 구했으면 폴백이다.** 조건이 `not route or off_route` 였는데,
    # 경로에 좌표가 없어 `where_on_route` 가 None 을 주는 경우에는 두 블록 다 건너뛰어
    # `arrival` 이 정의되지 않은 채 아래로 내려갔다. 실제로 못 만든 값을 기준으로
    # 판단하는 게 맞다.
    if arrival is None and session["planned_seconds"]:
        # **귀가자가 적은 시간이 도착예정이다.** 출발 시각 + 그 시간. 저장된 경로의
        # `total_seconds` 를 쓰는 것과 같은 자리다 — 추정이 아니라 아는 값이라
        # 위치로 흔들지 않는다.
        #
        # 관측 속도로 보정하지 않는 이유: 지하철처럼 집 쪽으로 곧장 가지 않는
        # 길에서는 접근 속도가 0 에 가깝다가 갑자기 뛴다. 그걸로 사람이 적은
        # 시각을 덮으면, 물어본 뜻이 없어진다.
        started_at = parse_iso(session["started_at"]) or now()
        arrival = started_at + timedelta(seconds=int(session["planned_seconds"]))
    elif arrival is None:
        # 폴백 — 저장된 경로도 없고 적어 둔 시간도 없다. 관측 접근 속도로 짐작한다.
        # 여기서 도착예정이 크게 튀는 걸 막는 게 MIN_OBSERVED_SPEED 와 ETA_OBSERVED_LIMIT 다.
        flat = straight / (TRANSPORT_SPEED[transport] / 60)
        speed = observed_speed(session["id"])
        if speed and speed > 0:
            seconds = min(straight / speed, flat * ETA_OBSERVED_LIMIT)
        else:
            seconds = flat
        arrival = now() + timedelta(seconds=max(30, seconds))

    if stage == "arrived":
        detail = None
        route_left = 0

    db().execute(
        """UPDATE sessions SET remaining_meters = ?, stage = ?, transport = ?,
           expected_arrival = ?, detail = ?, delay_seconds = ?, off_route = ?,
           route_progress = ?, measured_at = ?, last_lat = ?, last_lon = ?
           WHERE id = ?""",
        (route_left if route_left is not None else int(straight),
         stage, transport, iso(arrival), detail,
         delay, 1 if off_route else 0, progress, iso(at), lat, lon, session["id"]),
    )
    db().commit()

    return db().execute("SELECT * FROM sessions WHERE id = ?", (session["id"],)).fetchone()


def close_session(session, reason):
    db().execute(
        "UPDATE sessions SET ended_at = ?, end_reason = ?, stage = ? WHERE id = ?",
        (iso(now()), reason, "arrived" if reason == "arrived" else session["stage"], session["id"]),
    )
    if reason == "arrived":
        db().execute("UPDATE sessions SET remaining_meters = 0 WHERE id = ?", (session["id"],))
    db().commit()

    fresh = db().execute("SELECT * FROM sessions WHERE id = ?", (session["id"],)).fetchone()

    # 귀가가 끝나면 그 경로는 더 이상 아무에게도 필요하지 않다.
    removed = db().execute(
        "DELETE FROM fixes WHERE session_id = ?", (session["id"],)
    ).rowcount
    log(f"세션 {session['id']} 종료 ({reason}) · 위치 기록 {removed}건 삭제")

    end_activities(fresh)
    purge()


def purge():
    """남은 것을 걷어낸다.

    서버가 죽거나 앱이 세션을 안 끝내면 기록이 남는다. 그런 것까지 정리해야
    '끝나면 지운다' 가 실제로 지켜진다.
    """
    cutoff = iso(now() - timedelta(hours=SESSION_RETENTION_HOURS))

    orphans = db().execute(
        "DELETE FROM fixes WHERE session_id IN "
        "(SELECT id FROM sessions WHERE ended_at IS NOT NULL)"
    ).rowcount

    stale = db().execute(
        "DELETE FROM fixes WHERE session_id IN "
        "(SELECT id FROM sessions WHERE ended_at IS NULL AND started_at < ?)",
        (cutoff,),
    ).rowcount

    # **안 끝난 오래된 세션을 닫는다.** 예전에는 위치 기록만 지우고 세션 행은 그대로
    # 뒀다. 아래 삭제가 `ended_at IS NOT NULL` 만 보므로 그 행은 **영구히 남았고**,
    # `/session/start` 가 같은 경로일 때 그걸 재사용해서 경과 시간이 어긋났다.
    #
    # 여기서는 표시만 한다. 알림 정리 푸시는 보내지 않는다 — 하루 전 카드는 이미
    # `staleDate` 로 흐려졌거나 사라졌고, 정리 스레드에서 APNs 를 붙잡을 이유가 없다.
    abandoned = db().execute(
        "UPDATE sessions SET ended_at = ?, end_reason = 'stopped' "
        "WHERE ended_at IS NULL AND started_at < ?",
        (iso(now()), cutoff),
    ).rowcount
    if abandoned:
        db().execute(
            "DELETE FROM activities WHERE session_id IN "
            "(SELECT id FROM sessions WHERE end_reason = 'stopped' AND ended_at = ?)",
            (iso(now()),),
        )
        log(f"정리: 버려진 세션 {abandoned}건을 닫았다")

    # 오래 끝난 세션 자체도 지운다. 집 좌표를 들고 있을 이유가 없다.
    sessions = db().execute(
        "DELETE FROM sessions WHERE ended_at IS NOT NULL AND ended_at < ?", (cutoff,)
    ).rowcount

    db().execute("DELETE FROM invites WHERE expires_at < ?", (iso(now()),))

    if orphans or stale or sessions:
        log(f"정리: 위치 {orphans + stale}건, 끝난 세션 {sessions}건")


# ------------------------------------------------------------------ HTTP

class Handler(BaseHTTPRequestHandler):

    server_version = "HomecomingServer/1.0"

    # --- 보조 ---

    def account(self):
        """이 요청을 보낸 계정. 토큰으로만 판별한다. 모르는 토큰이면 None.

        `X-Account-Id` 는 더 읽지 않는다. 헤더에 적힌 걸 믿으면 한 줄만 바꿔서
        남의 실시간 위치를 읽고 남의 세션을 끝낼 수 있다.
        """
        header = self.headers.get("Authorization") or ""
        if not header.startswith("Bearer "):
            return None
        token = header[7:].strip()
        if not token:
            return None
        row = db().execute(
            "SELECT id FROM accounts WHERE auth_token = ?", (token_digest(token),),
        ).fetchone()
        if not row:
            return None
        # 요청마다 쓴다. 참조 서버 규모에서는 부담이 아니고, 이 값이 없으면
        # "기기가 서버에 닿았는가" 를 판정할 방법이 없다.
        db().execute(
            "UPDATE accounts SET last_seen = ? WHERE id = ?", (iso(now()), row["id"]),
        )
        return row["id"]

    def unauthorized(self):
        return self.reply(401, {"error": "인증이 필요합니다. POST /device/register 로 토큰을 받으세요."})

    def body(self):
        length = int(self.headers.get("Content-Length", 0))
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            return {}

    def reply(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass

    def touch_account(self, account_id):
        db().execute(
            "INSERT OR IGNORE INTO accounts (id, updated_at) VALUES (?, ?)",
            (account_id, iso(now())),
        )

    def active_session(self, traveler):
        return db().execute(
            "SELECT * FROM sessions WHERE traveler = ? AND ended_at IS NULL "
            "ORDER BY started_at DESC LIMIT 1",
            (traveler,),
        ).fetchone()

    # --- 라우팅 ---

    def guard(self, work):
        """한 요청의 실패가 서버 전체를 흔들지 않게."""
        try:
            work()
        except Exception as error:                      # noqa: BLE001
            log("  처리 실패:", repr(error))
            try:
                self.reply(500, {"error": str(error)})
            except Exception:                           # noqa: BLE001
                pass

    def do_POST(self):
        self.guard(self._post)

    def do_GET(self):
        self.guard(self._get)

    def do_DELETE(self):
        self.guard(self._delete)

    def _post(self):
        path = self.path.rstrip("/")
        body = self.body()

        # 기기 등록만 인증 없이 통과한다. 토큰을 받아 가는 길이니 당연하다.
        if path == "/device/register":
            return self.handle_device_register(body)

        me = self.account()
        if not me:
            return self.unauthorized()
        self.touch_account(me)
        log(f"POST {path}  ({me[:8]})")

        if path == "/eta":
            return self.handle_eta(body)
        if path.startswith("/push/"):
            return self.handle_push(path, body, me)
        if path == "/route":
            return self.handle_route_save(body, me)
        if path == "/pair/invite":
            return self.handle_invite(body, me)
        if path == "/pair/accept":
            return self.handle_accept(body, me)
        if path == "/session/start":
            return self.handle_session_start(body, me)
        if path.startswith("/session/") and path.endswith("/location"):
            return self.handle_location(path.split("/")[2], body, me)
        if path.startswith("/session/") and path.endswith("/end"):
            return self.handle_session_end(path.split("/")[2], body, me)

        return self.reply(404, {"error": "unknown path"})

    def _get(self):
        path = self.path.rstrip("/")

        # 살아 있는지 묻는 것뿐이라 인증을 걸지 않는다. 아무것도 알려주지 않는다.
        if path == "/health":
            trouble = apns_trouble()
            health = {"ok": True, "apns": trouble is None}
            if trouble:
                health["apnsTrouble"] = trouble
            return self.reply(200, health)

        me = self.account()
        if not me:
            return self.unauthorized()
        log(f"GET  {path}  ({me[:8]})")
        # 경로 하나를 통째로. **수정하려면 구간을 되돌려받아야 한다.**
        # 목록(`GET /route`)은 요약만 주므로 고칠 수가 없다.
        if path.startswith("/route/"):
            route = db().execute(
                "SELECT * FROM routes WHERE id = ? AND account_id = ?",
                (path.split("/")[2], me),
            ).fetchone()
            if not route:
                return self.reply(404, {"error": "unknown route"})
            legs = json.loads(route["legs"])
            return self.reply(200, {
                "routeId": route["id"],
                "name": route["name"],
                "totalSeconds": route["total_seconds"],
                "home": {"lat": route["home_lat"], "lon": route["home_lon"],
                         "name": route["home_name"], "radius": route["home_radius"]},
                "legs": legs,
                # 목록과 상세가 다른 말을 하면 안 된다.
                "stops": route_stops(legs),
            })

        # 지금 진행 중인 내 세션. 세션 id 를 잃어버렸을 때 되찾는 길이다.
        # `/session/{id}` 보다 먼저 걸러야 한다 — 안 그러면 "active" 를 id 로 읽는다.
        if path == "/session/active":
            session = self.active_session(me)
            return self.reply(200, {"sessionId": session["id"] if session else None})

        # 이 귀가가 쓰는 경로의 좌표열과 정류장. **가족 지도가 이걸로 선을 그린다.**
        #
        # **가족이 읽을 수 있는 첫 엔드포인트다.** 지금까지 가족 기기는 서버에
        # 아무것도 묻지 않고 액티비티 푸시만 받았다. 그 원칙을 여기서 깬 이유는
        # 크기다 — 좌표를 푸시에 실으면 4KB 한도에 걸려 노선도가 빠진다
        # (`route_geometry` 주석). 지도는 앱 화면에만 있고 앱은 요청을 보낼 수
        # 있으므로, 한도가 없는 쪽으로 옮긴다. 위젯은 그대로 푸시만 본다.
        #
        # 인가는 두 갈래다 — 자기 귀가이거나, 그 귀가자를 지켜보는 가족이거나.
        # 아니면 404 다. 403 은 "그 세션은 있다" 를 알려 주는 셈이라, 남의 귀가가
        # 진행 중인지 떠보는 데 쓸 수 있다(`owned_session` 과 같은 판단).
        if path.startswith("/session/") and path.endswith("/route"):
            session_id = path.split("/")[2]
            session = db().execute(
                "SELECT * FROM sessions WHERE id = ?", (session_id,)
            ).fetchone()
            if not session:
                return self.reply(404, {"error": "unknown session"})
            if session["traveler"] != me:
                link = db().execute(
                    "SELECT 1 FROM links WHERE traveler = ? AND watcher = ?",
                    (session["traveler"], me),
                ).fetchone()
                if not link:
                    return self.reply(404, {"error": "unknown session"})

            route = route_of(session)
            if not route:
                # 경로 없이 시작한 귀가다. 그릴 선이 없다 — 앱은 점만 찍는다.
                return self.reply(200, {"polyline": [], "segments": [], "stops": []})
            return self.reply(200, route_geometry(route["legs"]))

        # 자기 세션의 상태. 검증 도구가 단계·남은거리·갱신 대상 기기 수를 본다.
        #
        # 서버의 SQLite 를 직접 열던 것을 대신한다 — 배포한 서버에는 그 길이 없다.
        # 남의 세션이면 404 다. 있는지 없는지도 알려 주지 않는다.
        if path.startswith("/session/") and path.count("/") == 2:
            session = self.owned_session(path.split("/")[2], me, include_ended=True)
            if not session:
                return self.reply(404, {"error": "unknown session"})
            live = db().execute(
                "SELECT COUNT(*) AS n FROM activities WHERE session_id = ?", (session["id"],),
            ).fetchone()["n"]
            fixes = db().execute(
                "SELECT COUNT(*) AS n FROM fixes WHERE session_id = ?", (session["id"],),
            ).fetchone()["n"]
            state = content_state(session)
            state.update({
                "sessionId": session["id"],
                "routeId": session["route_id"],
                "activities": live,     # 지금 갱신을 받을 수 있는 기기 수
                "updatesSent": session["updates_sent"],   # 실제로 닿은 갱신 횟수
                "fixes": fixes,         # 남아 있는 위치 이력. 도착하면 0 이어야 한다
                "endedAt": session["ended_at"],
            })
            return self.reply(200, state)

        # 좌표 근처의 진짜 버스정류장. 경로를 만들 때 쓴다.
        #
        # **왜 서버가 대신 부르는가** — 공공데이터 서비스 키는 서버에만 둔다.
        # 앱에 넣으면 앱을 뜯는 누구나 그 키로 요청을 쏠 수 있고, 할당량은 이
        # 계정에 붙어 있다.
        #
        # 애플 지도에는 버스정류장이 시설로 없어서 "환승로터리" 를 검색하면 근처
        # 편의점이 나온다. 지도에서 대충 찍은 좌표를 여기 물으면 **공식 이름과
        # 정확한 좌표**로 바꿔 준다.
        # 버스 한 구간이 실제로 지나는 정류장 좌표열.
        #
        # 앱이 경로를 만들 때 부른다. 받은 점들을 경유지로 넣어 MapKit 으로 다시
        # 그리면 **실제 노선을 따라 도로 모양으로** 이어진다 — 정류장만 직선으로
        # 이으면 노선은 맞아도 길 모양이 아니다.
        #
        # 빈 배열은 실패가 아니다. 노선을 못 찾았거나(서울 시내버스는 이 자료에
        # 없다) 좌표를 못 채운 경우이고, 앱은 그때 지금처럼 자동차 경로로 그린다.
        if path.startswith("/bus/leg"):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(path).query)
            route_no = (query.get("no", [""])[0] or "").strip()
            to_name = (query.get("to", [""])[0] or "").strip()
            from_name = (query.get("from", [""])[0] or "").strip() or None
            try:
                from_lat = float(query.get("fromLat", [""])[0])
                from_lon = float(query.get("fromLon", [""])[0])
            except ValueError:
                return self.reply(400, {"error": "fromLat/fromLon 이 필요합니다"})
            if not route_no or not to_name:
                return self.reply(400, {"error": "no/to 가 필요합니다"})
            points, missing = bus_leg_waypoints(route_no, from_lat, from_lon,
                                                to_name, from_name)
            note = f" · 좌표 못 찾음 {missing}" if missing else ""
            log(f"  버스 {route_no} {from_name or '?'} → {to_name}: "
                f"경유 정류장 {len(points)}개{note}")
            return self.reply(200, {"points": points, "missing": missing})

        # 지하철 구간의 경유 역. `/bus/leg` 와 같은 자리, 같은 계약이다 —
        # 빈 결과는 실패가 아니고, 앱은 그때 두 역 직선으로 그리며 그 사실을 화면에 적는다.
        if path.startswith("/subway/leg"):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(path).query)
            from_name = (query.get("from", [""])[0] or "").strip()
            to_name = (query.get("to", [""])[0] or "").strip()
            if not from_name or not to_name:
                return self.reply(400, {"error": "from/to 가 필요합니다"})
            line, stops = subway_leg_stops(from_name, to_name)
            if line:
                log(f"  지하철 {line} {from_name} → {to_name}: 경유 역 {len(stops)}개")
            return self.reply(200, {"line": line, "stops": stops})

        if path.startswith("/stops"):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(path).query)
            text = (query.get("q", [""])[0] or "").strip()
            if text:
                # 이름으로 찾기. 서울 자료만 이름·좌표를 함께 갖고 있다.
                return self.reply(200, {"stops": seoul_search(text)})

            try:
                lat = float(query.get("lat", [""])[0])
                lon = float(query.get("lon", [""])[0])
            except ValueError:
                return self.reply(400, {"error": "lat/lon 또는 q 가 필요합니다"})

            # 서울 자료를 먼저 본다. 이름이 사람이 부르는 것과 같다
            # ("환승로터리"). TAGO 는 같은 자리를 "신촌오거리.현대백화점" 이라
            # 부르므로 서울에서는 뒤로 둔다. 서울 밖에서는 TAGO 뿐이다.
            want = 8
            stops = seoul_nearby(lat, lon, want)
            if len(stops) < want:
                seen = {s["name"] for s in stops}
                stops += [s for s in nearby_stops(lat, lon, want) if s["name"] not in seen]
            return self.reply(200, {"stops": stops[:want]})

        if path == "/push/status":
            # **자기 계정에 대해서만** 답한다. 검증 도구가 "기기가 서버에 닿았나",
            # "push-to-start 토큰이 올라왔나" 를 가리는 데 쓴다.
            #
            # 예전에는 도구가 서버의 SQLite 를 직접 열어서 봤다. 서버가 같은
            # 기계에 있을 때만 되는 방법이라, 배포한 뒤에는 통하지 않는다.
            # 토큰 값은 주지 않는다 — 있는지 없는지만 알면 판정에 충분하다.
            row = db().execute(
                "SELECT device_token, start_token, last_seen FROM accounts WHERE id = ?", (me,),
            ).fetchone()
            return self.reply(200, {
                "deviceToken": bool(row and row["device_token"]),
                "startToken": bool(row and row["start_token"]),
                "lastSeen": row["last_seen"] if row else None,
            })

        if path == "/route":
            rows = db().execute(
                "SELECT id, name, total_seconds, home_name, home_lat, home_lon, "
                "home_radius, legs FROM routes "
                "WHERE account_id = ? ORDER BY created_at DESC", (me,),
            ).fetchall()

            def summary(row):
                # 첫 구간의 교통수단과 문구를 함께 준다.
                #
                # **앱이 귀가 시작 순간의 카드를 직접 만든다.** 서버 응답을 기다리지
                # 않는다. 그런데 앱은 경로의 구간을 모르니, 없으면 MapKit 이 준
                # 자동차 경로를 쓰게 된다 — 걸어서 역까지 가는 첫 6분에 카드가
                # "차량 탑승" 으로 떴다.
                # **집 좌표도 준다.** 경로는 저장 시점의 집 사본을 들고 있고, 그 뒤에
                # 집을 옮기면 그 사본이 옛 자리에 남는다. 이름만 주면 앱은 두 집이
                # 다른지 알 수 없어서, 마지막 구간이 옛 집으로 끝나는 경로를 그냥
                # 고르게 된다 — 그러면 도착 반경(120m)에 영영 안 들어와 도착 판정이
                # 안 떨어진다. 좌표를 주면 앱이 견줘 말해 줄 수 있다.
                out = {"routeId": row["id"], "name": row["name"],
                       "totalSeconds": row["total_seconds"], "homeName": row["home_name"],
                       "home": {"lat": row["home_lat"], "lon": row["home_lon"],
                                "radius": row["home_radius"]}}
                try:
                    legs = json.loads(row["legs"])
                except (TypeError, ValueError):
                    return out
                out["totalMeters"] = route_length(legs)
                out["stops"] = route_stops(legs)
                mode = transport_of(legs, 0)
                if mode:
                    out["firstTransport"] = mode
                sentence = leg_sentence(leg_at(legs, 0), 0) if legs else None
                if sentence:
                    out["firstDetail"] = sentence
                return out

            return self.reply(200, [summary(r) for r in rows])

        if path == "/pair/watchers":
            rows = db().execute(
                "SELECT watcher AS accountId, watcher_name AS name FROM links WHERE traveler = ?",
                (me,),
            ).fetchall()
            return self.reply(200, [dict(r) for r in rows])

        if path == "/pair/watching":
            rows = db().execute(
                "SELECT traveler AS accountId, traveler_name AS name FROM links WHERE watcher = ?",
                (me,),
            ).fetchall()
            return self.reply(200, [dict(r) for r in rows])

        return self.reply(404, {"error": "unknown path"})

    def _delete(self):
        path = self.path.rstrip("/")
        me = self.account()
        if not me:
            return self.unauthorized()
        # 경로를 지운다. 목록에 지울 수단이 없으면 잘못 만든 것이 영영 남는다.
        if path.startswith("/route/"):
            route_id = path.split("/")[2]
            removed = db().execute(
                "DELETE FROM routes WHERE id = ? AND account_id = ?", (route_id, me),
            ).rowcount
            # 그 경로로 도는 세션이 있으면 거리 기반 추정으로 떨어진다. 세션을
            # 끊지는 않는다 — 귀가 중에 화면이 통째로 죽는 것보다 낫다.
            db().execute("UPDATE sessions SET route_id = NULL WHERE route_id = ?", (route_id,))
            db().commit()
            if not removed:
                return self.reply(404, {"error": "unknown route"})
            log(f"  경로 삭제 {route_id}")
            return self.reply(200, {"ok": True})

        if path.startswith("/pair/link/"):
            other = path.split("/")[-1]
            db().execute(
                "DELETE FROM links WHERE (traveler = ? AND watcher = ?) OR (watcher = ? AND traveler = ?)",
                (me, other, me, other),
            )
            db().commit()
            log(f"  연결 해제 {me[:8]} ↔ {other[:8]}")
            return self.reply(200, {"ok": True})
        return self.reply(404, {"error": "unknown path"})

    # --- 처리 ---

    def handle_eta(self, body):
        origin, destination = body.get("origin"), body.get("destination")
        if not origin or not destination:
            return self.reply(400, {"error": "origin/destination 필요"})

        straight = haversine(origin["lat"], origin["lon"], destination["lat"], destination["lon"])
        route = straight * 1.35
        mode, detail = guess_transport(route)
        minutes = max(1, round(route / TRANSPORT_SPEED[mode]))
        return self.reply(200, {
            "expectedArrival": iso(now() + timedelta(minutes=minutes)),
            "routeMeters": round(route),
            "mode": mode,
            "detail": detail,
        })

    def handle_push(self, path, body, me):
        if path == "/push/device":
            db().execute("UPDATE accounts SET device_token = ? WHERE id = ?", (body.get("deviceToken"), me))
        elif path == "/push/start-token":
            db().execute("UPDATE accounts SET start_token = ? WHERE id = ?", (body.get("token"), me))
            log("  push-to-start 토큰 저장")
        elif path == "/push/activity":
            session_id = body.get("sessionId") or ""
            if not session_id:
                # 세션 ID 가 없으면 이 계정이 관련된 활성 세션으로 짐작한다.
                row = db().execute(
                    "SELECT s.id FROM sessions s LEFT JOIN links l ON l.traveler = s.traveler "
                    "WHERE s.ended_at IS NULL AND (s.traveler = ? OR l.watcher = ?) "
                    "ORDER BY s.started_at DESC LIMIT 1",
                    (me, me),
                ).fetchone()
                session_id = row["id"] if row else ""
            if session_id:
                db().execute(
                    "INSERT OR REPLACE INTO activities (activity_id, session_id, account_id, token) "
                    "VALUES (?, ?, ?, ?)",
                    (body.get("activityId"), session_id, me, body.get("token")),
                )
                log(f"  액티비티 토큰 등록 → 세션 {session_id}")
        elif path == "/push/activity/end":
            db().execute("DELETE FROM activities WHERE activity_id = ?", (body.get("activityId"),))
        db().commit()
        return self.reply(200, {"ok": True})

    def handle_device_register(self, body):
        """기기 하나에 계정과 비밀 토큰을 발급한다. 앱이 처음 켜질 때 한 번 부른다.

        계정 id 는 서버가 정한다. 클라이언트가 고르게 하면 남의 id 를 달라고 해서
        그 계정을 차지할 수 있다.

        토큰은 앱의 키체인에 둔다. UserDefaults 는 안 된다 — 실기기에서
        `devicectl device copy` 로 그대로 꺼내 봤다.

        앱을 지워도 키체인은 남으므로 재설치하면 같은 계정으로 돌아온다.
        이 엔드포인트가 불리는 것은 그 기기의 **처음 한 번**이다.
        """
        account_id = uuid.uuid4().hex[:12]
        token = os.urandom(32).hex()
        # 평문은 이 응답에만 실려 나가고 서버에 남지 않는다.
        db().execute(
            "INSERT INTO accounts (id, auth_token, updated_at) VALUES (?, ?, ?)",
            (account_id, token_digest(token), iso(now())),
        )
        db().commit()
        log(f"기기 등록 {account_id}")
        return self.reply(200, {"accountId": account_id, "token": token})

    def owned_session(self, session_id, me, include_ended=False):
        """내 세션이면 돌려준다. 아니면 None.

        토큰이 있다고 아무 세션이나 만질 수 있으면 인증을 붙인 뜻이 없다.
        남의 세션에 위치를 넣거나 끝낼 수 있으면 그게 그대로 구멍이다.

        **쓰기는 진행 중인 세션에만 된다.** 끝난 세션에 위치를 넣을 수는 없다.
        읽기는 끝난 뒤에도 허용한다 — 귀가가 어떻게 끝났는지 보는 것이 자기
        데이터를 보는 것이고, 검증 도구도 그걸 봐야 판정할 수 있다.
        """
        clause = "" if include_ended else " AND ended_at IS NULL"
        return db().execute(
            f"SELECT * FROM sessions WHERE id = ? AND traveler = ?{clause}",
            (session_id, me),
        ).fetchone()

    def handle_route_save(self, body, me):
        """자주 가는 귀가 경로를 저장한다.

        대중교통 앱이 알려 주는 것을 그대로 받는다 — 구간 목록과 총 소요시간.
        이 값이 도착예정의 근거가 된다. 서버가 다시 계산하지 않는다.
        """
        legs = body.get("legs") or []
        total = int(body.get("totalSeconds") or 0)
        home = body.get("home") or {}

        if not legs:
            return self.reply(400, {"error": "legs 가 필요합니다"})
        if total <= 0:
            return self.reply(400, {"error": "totalSeconds 가 필요합니다"})
        if home.get("lat") is None or home.get("lon") is None:
            return self.reply(400, {"error": "home 좌표가 필요합니다"})

        # 구간에 좌표가 없으면 어느 구간인지 판정할 수 없다. 환승 대기는 예외다.
        movable = [leg for leg in legs if leg.get("mode") != "wait"]
        if not any(leg.get("points") for leg in movable):
            return self.reply(400, {"error": "구간에 points 가 필요합니다"})

        # 같은 이름의 경로를 다시 올리는 건 고치는 것이다. 새로 만들면 앱의 고르기
        # 화면에 구분할 수 없는 줄이 쌓인다 — 실제로 여덟 개까지 쌓였다.
        # id 는 유지한다. 세션과 앱이 그 id 를 들고 있다.
        name = body.get("name") or "귀가 경로"

        # **고치는 것이면 id 가 온다.** 이름으로만 찾으면 이름을 바꾼 순간 새 경로가
        # 생기고 옛것이 남는다 — 고쳤다고 생각한 사람에게 두 개가 보인다.
        wanted = body.get("routeId")
        existing = None
        if wanted:
            existing = db().execute(
                "SELECT id FROM routes WHERE id = ? AND account_id = ?", (wanted, me),
            ).fetchone()
            if not existing:
                return self.reply(404, {"error": "unknown route"})
        else:
            existing = db().execute(
                "SELECT id FROM routes WHERE account_id = ? AND name = ?", (me, name),
            ).fetchone()
        route_id = existing["id"] if existing else uuid.uuid4().hex[:12]

        db().execute(
            """INSERT INTO routes (id, account_id, name, home_lat, home_lon, home_radius,
               home_name, total_seconds, legs, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT (id) DO UPDATE SET
                 name = excluded.name,
                 home_lat = excluded.home_lat, home_lon = excluded.home_lon,
                 home_radius = excluded.home_radius, home_name = excluded.home_name,
                 total_seconds = excluded.total_seconds, legs = excluded.legs
               ON CONFLICT (account_id, name) DO UPDATE SET
                 home_lat = excluded.home_lat, home_lon = excluded.home_lon,
                 home_radius = excluded.home_radius, home_name = excluded.home_name,
                 total_seconds = excluded.total_seconds, legs = excluded.legs""",
            (
                route_id, me, name,
                float(home["lat"]), float(home["lon"]),
                max(float(home.get("radius") or 120), MIN_ARRIVAL_RADIUS),
                home.get("name") or "집",
                total, json.dumps(legs, ensure_ascii=False), iso(now()),
            ),
        )
        db().commit()
        verb = "갱신" if existing else "저장"
        log(f"  경로 {verb} {route_id} — {name} · {total // 60}분 · 구간 {len(legs)}개")
        return self.reply(200, {"routeId": route_id, "totalSeconds": total})

    def handle_invite(self, body, me):
        alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        code = "".join(alphabet[b % len(alphabet)] for b in os.urandom(5))
        expires = now() + timedelta(minutes=INVITE_TTL_MINUTES)
        db().execute(
            "INSERT OR REPLACE INTO invites (code, traveler, traveler_name, expires_at) VALUES (?, ?, ?, ?)",
            (code, me, body.get("travelerName") or "귀가자", iso(expires)),
        )
        db().commit()
        log(f"  초대 코드 {code}")
        return self.reply(200, {"code": code, "expiresAt": iso(expires)})

    def handle_accept(self, body, me):
        code = (body.get("code") or "").upper()
        invite = db().execute("SELECT * FROM invites WHERE code = ?", (code,)).fetchone()
        if not invite:
            return self.reply(404, {"error": "unknown code"})
        if parse_iso(invite["expires_at"]) < now():
            return self.reply(410, {"error": "expired"})
        if invite["traveler"] == me:
            return self.reply(400, {"error": "자기 자신은 연결할 수 없습니다"})

        db().execute(
            "INSERT OR REPLACE INTO links (traveler, watcher, watcher_name, traveler_name) "
            "VALUES (?, ?, ?, ?)",
            (invite["traveler"], me, body.get("name") or "가족", invite["traveler_name"]),
        )
        db().commit()
        log(f"  연결 {me[:8]} → {invite['traveler'][:8]}")

        # **이미 귀가 중이면 이 가족에게도 지금 카드를 띄운다.**
        #
        # `start_activities` 는 세션 시작 때 딱 한 번 불린다. 그래서 귀가 중에 가족이
        # 새로 붙으면 다음 귀가까지 아무것도 안 보였다 — 사용자는 페어링이 실패한 줄
        # 안다. 2026-08-19 에 실제로 그렇게 헤맸다: 초대 코드를 넣었는데 SE2 에 아무것도
        # 뜨지 않았고, 원인을 찾느라 로그를 뒤졌다.
        #
        # 지금 붙은 사람에게만 쏜다. 이미 카드를 든 가족에게 다시 쏘면 그쪽 화면이
        # 새 알림으로 한 번 더 울린다.
        session = self.active_session(invite["traveler"])
        if session:
            link = db().execute(
                "SELECT * FROM links WHERE traveler = ? AND watcher = ?",
                (invite["traveler"], me),
            ).fetchone()
            log(f"  귀가 중({session['id']}) — 방금 붙은 가족에게 카드를 띄운다")
            threading.Thread(
                target=start_activity_for, args=(session, link), daemon=True,
            ).start()

        return self.reply(200, {
            "travelerName": invite["traveler_name"],
            "travelerAccountId": invite["traveler"],
        })

    def handle_session_start(self, body, me):
        # 귀가자당 활성 세션은 하나다. 앱이 재시작돼도 세션이 늘어나지 않는다.
        #
        # 다만 **같은 귀가일 때만** 그렇다. 경로를 다르게 골랐으면 그건 다른 귀가다.
        # 그냥 돌려주면 앱은 새 경로로 카드를 띄우는데 서버는 옛 경로로 계산해서
        # 둘이 어긋난다. 더 나쁜 경우는 이렇다 — 앱이 죽으면 세션이 24시간 남고,
        # 다음 날 귀가 시작을 누르면 **어제 세션이 재사용되면서 오늘 고른 경로가
        # 조용히 무시된다.** 실제로 시험 중에 이걸로 걸렸다.
        # 출발 좌표를 먼저 읽는다 — 재사용 판정(`same_journey`)이 이걸 본다.
        try:
            start_lat = float(body["lat"])
            start_lon = float(body["lon"])
        except (KeyError, TypeError, ValueError):
            start_lat = start_lon = None

        existing = self.active_session(me)
        if existing:
            started = parse_iso(existing["started_at"])
            aged = started is None or \
                (now() - started) > timedelta(hours=SESSION_REUSE_MAX_HOURS)
            if aged:
                # 나이를 보는 이유는 `SESSION_REUSE_MAX_HOURS` 주석에 있다.
                hours = "?" if started is None else f"{(now() - started).total_seconds() / 3600:.1f}"
                log(f"  세션 {existing['id']} 는 {hours}시간 전 것이다 — 닫고 새로 연다")
                close_session(existing, "stopped")
            elif same_journey(existing, body.get("routeId"), start_lat, start_lon):
                log(f"  이미 진행 중인 세션 {existing['id']} 재사용")
                return self.reply(200, {"sessionId": existing["id"]})
            else:
                log(f"  다른 귀가다 — 세션 {existing['id']} 를 닫고 새로 연다")
                close_session(existing, "stopped")

        route_id = body.get("routeId")
        route_row = None
        if route_id:
            route_row = db().execute(
                "SELECT * FROM routes WHERE id = ? AND account_id = ?", (route_id, me),
            ).fetchone()
            if not route_row:
                return self.reply(404, {"error": "unknown route"})

        # **집은 앱이 보낸 것이 이긴다.** 경로에 박힌 집은 그 경로를 저장한 순간의
        # 사본이다. 그 뒤에 집을 옮기면 경로는 옛 좌표를 계속 들고 있고, 서버는
        # 그것으로 도착을 판정하고 가족 지도에 마커를 찍는다 — 사용자가 지금 지정해
        # 둔 집이 있는데도 4km 떨어진 옛 자리를 "집" 이라고 그렸다(2026-08-19).
        #
        # 예전 주석은 "두 곳에 적어 두면 어긋날 자리가 생긴다" 며 경로를 택했다.
        # 어긋나는 것은 맞지만, 그때 믿어야 하는 쪽은 **사용자가 방금 지정한 값**이다.
        #
        # 경로만 있는 경우(앱이 집을 안 보낸 옛 클라이언트)는 경로에서 가져온다.
        #
        # **주의: 경로의 `legs` 와 `total_seconds` 는 여전히 옛 집까지 재어진 값이다.**
        # 두 집이 멀면 남은거리와 도착예정이 도착 판정과 어긋난다. 집을 옮겼으면
        # 경로도 다시 저장해야 완전히 맞는다 — 여기서 고칠 수 있는 것은 "어디를
        # 집으로 보는가" 까지다.
        home = body.get("home") or {}
        home_origin = "앱"
        if home.get("lat") is None or home.get("lon") is None:
            if route_row:
                home = {"lat": route_row["home_lat"], "lon": route_row["home_lon"],
                        "name": route_row["home_name"], "arrivalRadius": route_row["home_radius"]}
                home_origin = "경로"
            else:
                home_origin = "없음"

        radius = max(float(home.get("arrivalRadius") or 120), MIN_ARRIVAL_RADIUS)
        session_id = uuid.uuid4().hex[:12]

        # **출발 좌표는 위에서 읽었다**(재사용 판정이 먼저 쓴다). 여기서는 그 값이
        # 무엇을 더 하는지 적어 둔다 — 앱이 보내면 첫 카드부터 지도가 그려진다.
        #
        # `content_state` 는 `last_lat` 이 있을 때만 좌표를 싣고, 그 값은 위치
        # 보고에서만 채워졌다(`recompute`). 그래서 세션 시작 푸시에는 좌표가 없고,
        # 가족은 **카드는 받았는데 지도가 없는 화면**을 봤다. 실제 귀가에서는 앱이
        # 1초 안에 첫 위치를 올려 메워지지만, 그 사이에 화면을 보면 고장으로 읽힌다
        # (2026-08-20 실기기 검증에서 그렇게 짚었다).
        #
        # 없으면 예전대로 돈다 — 이 키를 모르는 옛 앱이 있다.

        # 경로가 있으면 첫 도착예정부터 아는 값이다. 위치가 한 건도 안 와도 맞다.
        # 없으면 20분이라는 자리표시자로 시작해서 첫 위치에 덮어쓴다.
        started = now()
        planned_seconds = None
        first_transport = "subway"
        first_detail = None
        first_meters = 0
        if route_row:
            first_arrival = started + timedelta(seconds=route_row["total_seconds"])
            # **첫 구간의 교통수단으로 시작한다.** 예전에는 "subway" 로 못박아 둬서,
            # 회사에서 역까지 걸어가는 첫 6분에도 카드에 지하철이 떴다. 문구는
            # "도보 · 국회의사당역까지 6분" 인데 아이콘만 지하철이라 어긋나 보였다.
            legs = json.loads(route_row["legs"])
            first_transport = transport_of(legs, 0) or "walk"
            first_detail = leg_sentence(leg_at(legs, 0), 0) if legs else None
            # 위치가 오기 전에도 거리를 안다. 0 으로 두면 카드에 "0m 남음" 이 뜨고,
            # 그건 도착했다는 뜻으로 읽힌다.
            first_meters = route_length(legs)
        else:
            # **귀가자가 적은 시간이 있으면 그것이 도착예정이다.** 없으면 20분이라는
            # 자리표시자로 시작해서 첫 위치에 덮어쓴다(예전 동작).
            try:
                planned = int(body.get("plannedMinutes") or 0)
            except (TypeError, ValueError):
                planned = 0
            planned_seconds = planned * 60 if planned > 0 else None
            first_arrival = (started + timedelta(seconds=planned_seconds)) if planned_seconds \
                else (started + timedelta(minutes=20))
            # 출발 좌표가 있으면 첫 거리도 안다. 0 으로 두면 카드에 "0m 남음" 이
            # 뜨는데 그건 도착했다는 뜻으로 읽힌다 — 경로가 있는 쪽이 이미 같은
            # 이유로 `route_length()` 를 미리 넣는다. `handle_location` 이 첫 보고에서
            # 하는 계산과 같은 것을 한 보고 앞당겨 하는 것이다.
            if start_lat is not None and home.get("lat") is not None:
                first_meters = int(haversine(start_lat, start_lon,
                                             float(home["lat"]), float(home["lon"])))

        db().execute(
            """INSERT INTO sessions (id, traveler, traveler_name, home_lat, home_lon, home_radius,
               home_name, total_meters, remaining_meters, stage, transport, expected_arrival,
               detail, started_at, route_id, measured_at, planned_seconds, last_lat, last_lon)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (
                session_id, me, body.get("travelerName") or "귀가자",
                float(home.get("lat") or 0), float(home.get("lon") or 0), radius,
                home.get("name") or "집",
                first_meters, first_meters, "leaving", first_transport, iso(first_arrival),
                first_detail, iso(started), route_id, iso(started), planned_seconds,
                start_lat, start_lon,
            ),
        )
        db().commit()

        session = db().execute("SELECT * FROM sessions WHERE id = ?", (session_id,)).fetchone()
        # **어디를 집으로 잡았는지 남긴다.** 이 값이 도착 판정의 기준이고 가족 지도의
        # 마커다. 안 남기던 동안, 잘못된 집으로 4km 떨어진 자리를 "집" 이라고 그리는
        # 것을 로그로는 알아낼 방법이 없었다(2026-08-19). 출처도 같이 적는다 —
        # 앱이 보낸 값인지 경로에 박힌 사본인지가 원인 추적의 갈림길이다.
        where = (f"집({session['home_lat']:.5f}, {session['home_lon']:.5f}) "
                 f"출처={home_origin} 반경={int(radius)}m")
        if route_row:
            log(f"세션 {session_id} 시작 — {session['traveler_name']} · 경로 "
                f"{route_row['name']} {route_row['total_seconds'] // 60}분 · {where} · "
                f"도착예정 {iso(first_arrival)}")
        else:
            log(f"세션 {session_id} 시작 — {session['traveler_name']} · 경로 없음(거리 추정) · {where}")
        threading.Thread(target=start_activities, args=(session,), daemon=True).start()
        return self.reply(200, {"sessionId": session_id})

    def handle_location(self, session_id, body, me):
        session = self.owned_session(session_id, me)
        if not session:
            # 남의 세션과 없는 세션을 같은 404 로 답한다. 구분해 주면 세션 id 를
            # 넣어 보면서 남의 귀가가 진행 중인지 알아낼 수 있다.
            return self.reply(404, {"error": "unknown session"})

        lat, lon = body.get("lat"), body.get("lon")
        if lat is None or lon is None:
            return self.reply(400, {"error": "lat/lon 필요"})

        at = parse_iso(body.get("at")) or now()
        previous_stage = session["stage"]

        # 첫 위치는 전체 거리의 기준이 된다.
        #
        # **그리고 그보다 멀어지면 기준을 넓힌다.** 경로 없는 귀가의 전체거리는 출발
        # 시점의 직선거리라, 집 반대쪽으로 먼저 가는 길(주차장·역까지 걸어 나가는 방향)
        # 에서는 남은거리가 전체거리를 넘어선다. 그러면 진행 바가 0 에 붙어 아무리
        # 가도 안 움직인다 — 2026-08-20 실주행에서 남은거리가 5,813m → 6,721m 로
        # 늘어나는 것을 로그로 봤다. 앱도 같은 규칙을 쓴다
        # (`HomecomingActivityManager.update` 의 `max(previous.totalMeters, meters)`).
        session = widen_total(
            session, haversine(lat, lon, session["home_lat"], session["home_lon"]))

        session = recompute(session, lat, lon, at)

        if session["stage"] == "arrived":
            close_session(session, "arrived")
            return self.reply(200, {"ok": True, "arrived": True})

        alert = None
        if session["stage"] == "nearby" and previous_stage != "nearby":
            alert = {
                "title": "곧 도착",
                "body": f"{은는이가(session['traveler_name'])} {int(session['remaining_meters'])}m 앞이에요",
            }
        update_activities(session, alert)
        # **보고한 폰에게 지금 상태를 되돌려 준다.**
        #
        # 귀가자 폰은 남은거리·진행도를 오직 APNs 푸시로만 받는다. 좌표는 자기
        # GPS 로 쓰면서 나머지는 기다리는 것이라, 푸시가 늦으면 **한 화면 안에서
        # 어긋난다** — 점은 지금 자리인데 남은거리는 몇 분 전 것이 된다
        # (2026-08-21 14:41 실주행: 화면 3.2km, 그때 서버는 2,093m).
        #
        # 그런데 이 요청이 이미 오가고 있다. 여기에 상태를 실으면 보고할 때마다
        # 화면이 최신이 된다 — 새 엔드포인트도, 추가 요청도 필요 없다.
        #
        # 가족 폰은 이 길이 없다(위치를 보내지 않으니까). 그쪽은 푸시가 전부이고,
        # 대신 상태 전체가 한 봉투에서 와 어긋나지 않는다.
        #
        # **응답에 키를 더하는 것은 안전하다.** 이 필드를 모르는 옛 앱은 무시한다.
        return self.reply(200, {"ok": True, "state": content_state(session)})

    def handle_session_end(self, session_id, body, me):
        session = self.owned_session(session_id, me)
        if not session:
            return self.reply(404, {"error": "unknown session"})
        close_session(session, body.get("reason") or "stopped")
        return self.reply(200, {"ok": True})


def warm_bus_routes():
    """노선표를 미리 받아 둔다. **첫 요청이 느린 것을 없애는 게 목적이다.**

    노선번호로 거르는 파라미터가 없어서 시도를 통째로 훑는다(경기 4,671개,
    실측 15초). 그 15초가 첫 `/bus/leg` 요청에 그대로 얹히는데, 앱이 먼저
    끊으면 그 구간이 **조용히 자동차 경로로 저장된다** — 2026-08-20 에 실제로
    그랬다(저장 12:31:10, 노선 응답 12:32:26). 기동 때 미리 받아 두면 사용자가
    기다리는 요청에서는 이미 캐시에 있다.

    실패해도 넘어간다. 필요할 때 다시 받는다.
    """
    for ctpv in BUS_CTPV:
        try:
            bus_route_ids(ctpv, "0")     # 표만 채운다. 노선번호는 아무거나.
        except Exception as error:                              # noqa: BLE001
            log(f"  버스 노선표 {ctpv} 미리받기 실패: {error!r}")


def main():
    parser = argparse.ArgumentParser()
    # 배포 플랫폼은 대개 PORT 로 포트를 주입한다. 그걸 무시하면 헬스체크가 실패한다.
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", 8787)))
    # 배포에서는 127.0.0.1 로 묶고 앞에 Caddy 를 세운다. 이 서버는 평문 HTTP 만
    # 하므로 바깥에 그대로 열면 토큰이 평문으로 흐른다.
    # 개발 기본값이 0.0.0.0 인 이유는 실기기가 맥에 붙어야 하기 때문이다.
    parser.add_argument("--host", default=os.environ.get("HOMECOMING_HOST", "0.0.0.0"))
    args = parser.parse_args()

    db()
    purge()

    # 노선표를 백그라운드로 미리 받는다. 헬스체크를 붙잡지 않으려고 스레드로
    # 돌린다 — 배포 플랫폼이 30초 안에 응답을 본다.
    if TAGO_KEY:
        threading.Thread(target=warm_bus_routes, daemon=True).start()

    def sweeper():
        while True:
            time.sleep(3600)
            try:
                purge()
            except Exception as error:                  # noqa: BLE001
                log("정리 실패:", repr(error))

    threading.Thread(target=sweeper, daemon=True).start()

    log(f"귀가마중 서버 {args.host}:{args.port}")
    log(f"  DB   {DB_PATH}")
    log(f"  APNs {'설정됨 · ' + APNS_HOST if apns_configured() else '미설정 (푸시 생략)'}")
    log(f"  서울 정류소 {len(SEOUL_STOPS)}건")
    log(f"  위치 보관  진행 중 최근 {FIX_WINDOW}건 · 종료 시 삭제 · 세션 {SESSION_RETENTION_HOURS}시간 후 삭제")

    try:
        ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()

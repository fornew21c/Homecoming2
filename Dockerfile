# 귀가마중 서버.
#
# 파이썬 표준 라이브러리와 SQLite 만 쓴다. 설치할 패키지가 없어서 이미지가
# 거의 베이스 그대로다.
FROM python:3.12-slim

# curl — **APNs 로 쏘는 통로다.** HTTP/2 가 필요해서 파이썬 표준 라이브러리로는
#        못 한다. 이게 없으면 서버는 멀쩡히 뜨는데 알림이 한 건도 안 나간다.
#        실제로 첫 배포에서 이걸 빠뜨려 푸시 스레드가 FileNotFoundError 로 죽었다.
# openssl — APNs 토큰 서명(ES256). 파이썬만으로 하려면 암호화 라이브러리를 넣어야
#           하는데 그러면 "의존성 없음" 이 깨진다. 바이너리 하나가 더 싸다.
# util-linux — `setpriv`. 진입점이 root 로 볼륨 소유권만 넘기고 권한을 내려놓는다.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl openssl util-linux \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Server/homecoming_server.py /app/homecoming_server.py
# 서울 정류소 자료. 없으면 서버는 뜨지만 서울 정류장 검색이 조용히 빈손이 된다.
COPY Server/data /app/data
COPY Deploy/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# 서버는 이 사용자로 돈다. root 일 이유가 없다 — 하는 일이 소켓 하나와 파일 하나뿐이다.
# 다만 진입점은 root 로 시작한다. 볼륨이 root 소유로 마운트되기 때문이다.
RUN useradd --system --uid 10001 homecoming

# 포트는 플랫폼이 PORT 로 준다. 여기서 고정하지 않는다.
# 바인딩은 0.0.0.0 이다 — 컨테이너 밖에서 들어와야 하고, TLS 는 플랫폼이 끝낸다.
CMD ["/app/entrypoint.sh"]

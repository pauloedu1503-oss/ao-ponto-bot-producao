FROM dart:stable

RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/backend

COPY pubspec.yaml pubspec.lock ./
RUN dart pub get --enforce-lockfile

COPY bin ./bin
COPY lib ./lib

EXPOSE 8080
VOLUME ["/app/backend/data", "/app/backend/backups"]

CMD ["dart", "run", "bin/server.dart"]

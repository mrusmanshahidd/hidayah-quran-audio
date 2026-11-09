FROM dart:stable AS build

WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY bin/ bin/
COPY lib/ lib/
RUN dart compile exe -DQF_PRODUCTION_BUILD=true bin/server.dart -o /app/quran_audio_server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/quran_audio_server ./quran_audio_server
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app/quran_audio_server"]

# ---- build ----
FROM debian:bookworm-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
    nasm gcc make libc6-dev libcurl4-openssl-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Makefile ./
COPY src ./src
RUN make

# ---- runtime ----
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4 ca-certificates && rm -rf /var/lib/apt/lists/* \
    && useradd -r -u 10001 caine && mkdir -p /data && chown caine /data
COPY --from=build /src/caine /usr/local/bin/caine
USER caine
ENV DATA_FILE=/data/caine_settings.txt
CMD ["caine"]

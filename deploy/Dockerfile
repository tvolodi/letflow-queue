# ── Stage 1: Build the Elixir release ──────────────────────────────────────
# Pinned to match this project's `mix.exs` (elixir: "~> 1.17") and the
# Elixir/OTP combination documented as the known-good sandbox toolchain in
# the sibling Letflow repo's docs/anti-patterns.md.
FROM elixir:1.17-otp-27 AS builder

ENV MIX_ENV=prod \
    LANG=C.UTF-8

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# Fetch and compile deps first so dependency changes don't bust the cache
# for every source change.
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod
RUN mix deps.compile

COPY lib lib
COPY priv priv
RUN mix compile

RUN mix release

# ── Stage 2: minimal runtime image ──────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

# openssl/libncurses/locales are the standard runtime deps for a compiled
# Erlang/OTP release; ca-certificates for outbound TLS if ever needed.
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# Non-root user to run the release.
RUN groupadd --gid 1000 letflow && \
    useradd --uid 1000 --gid letflow --shell /bin/sh --create-home letflow

WORKDIR /app

# SQLite database file lives here — mount a volume at /app/data to persist
# it across container recreates.
RUN mkdir -p /app/data && chown -R letflow:letflow /app

COPY --from=builder --chown=letflow:letflow /app/_build/prod/rel/letflow_queue ./

USER letflow

ENV PHX_SERVER=true \
    PORT=4000 \
    DATABASE_PATH=/app/data/queue.db

# Internal port the app listens on. nginx on the host reverse-proxies to
# this via the compose file's host-port binding — see
# deploy/docker-compose.*.yml and deploy/nginx/*.conf.
EXPOSE 4000

CMD ["bin/letflow_queue", "start"]

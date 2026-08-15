import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/letflow_queue start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :letflow_queue, LetflowQueueWeb.Endpoint, server: true
end

config :letflow_queue, LetflowQueueWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Optional GitHub Issues sync (see README.md "GitHub Issues sync"). Both
# are read here, at boot, exactly like QUEUE_AUTH_TOKEN below — never
# hardcoded. Unlike QUEUE_AUTH_TOKEN, neither is required: sync is
# best-effort and LetflowQueue.GitHub treats either being unset/blank as
# "not configured", degrading every sync call to a no-op rather than
# raising. Applied in every env (not just :prod) since config/dev.exs and
# config/test.exs intentionally have no fallback for these — unlike the
# dev auth token, there is no meaningful dev/test default for a real
# external GitHub repo to sync against.
config :letflow_queue,
  github_token: System.get_env("GITHUB_TOKEN"),
  github_repo: System.get_env("GITHUB_REPO")

if config_env() == :prod do
  # The single shared bearer token every one of the four endpoints checks
  # (except GET /health). Read here, at boot, from the environment —
  # never hardcoded. See lib/letflow_queue_web/auth_plug.ex.
  auth_token =
    System.get_env("QUEUE_AUTH_TOKEN") ||
      raise """
      environment variable QUEUE_AUTH_TOKEN is missing.
      This is the shared bearer token AI-agent callers must present.
      """

  config :letflow_queue, auth_token: auth_token

  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /app/data/queue.db
      """

  config :letflow_queue, LetflowQueue.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :letflow_queue, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :letflow_queue, LetflowQueueWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :letflow_queue, LetflowQueueWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :letflow_queue, LetflowQueueWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

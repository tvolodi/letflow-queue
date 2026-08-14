import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :letflow_queue, LetflowQueue.Repo,
  database: Path.expand("../letflow_queue_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# Fixed test token so controller/integration tests can authenticate without
# depending on the environment.
config :letflow_queue, auth_token: "test-secret-token"

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :letflow_queue, LetflowQueueWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "j1MU3tmIJwfS7Ww8xA8aAvDfA57bJr5knsiGhEpasCDXBMl38pRW+sXzv0CRDEoJ",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

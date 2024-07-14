This pool will open ten HTTP/1.1 connections with each using `my-session-#{id}` ClickHouse `session_id` for query requests where `id` is 1 through 10.

```elixir
Ch.start_link(session: "my-session-", pool_size: 10)
```

See tests for more.

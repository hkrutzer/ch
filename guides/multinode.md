# Connecting to multiple nodes

Similar to https://clickhouse.com/docs/en/integrations/go#connecting-to-multiple-nodes

```elixir
default_port = 8123

endpoints = [
    [scheme: :https, hostname: "clickhouse.example.io", port: 8123],
    [scheme: :https, hostname: "clickhouse-2.example.io", port: 8123],
    # etc.
]

Ch.start_link(endpoints: endpoints, pool_size: 20)
```

See tests for more.

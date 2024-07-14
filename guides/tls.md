# Using TLS

## system cacerts

```elixir
Ch.start_link(scheme: :https, transport_opts: [cacerts: :public_key.cacerts_get()])
```

## custom certs

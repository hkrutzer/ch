# Ch

[![Documentation badge](https://img.shields.io/badge/Documentation-ff69b4)](https://hexdocs.pm/ch)
[![Hex.pm badge](https://img.shields.io/badge/Package%20on%20hex.pm-informational)](https://hex.pm/packages/ch)

Minimal ClickHouse client for Elixir.

Used in [Ecto ClickHouse adapter.](https://github.com/plausible/ecto_ch)

### Key features

- Minimal API
- Native query parameters
- Per query [settings](./guides/settings.md)
- HTTP or [Native](./guides/native.md)
- [Multinode](./guides/multinode.md)
- [Compression](./guides/compression.md)
- [OpenTelemetry](./guides/otel.md)

## Installation

```elixir
defp deps do
  [
    {:ch, "~> 0.3.0"}
  ]
end
```

## Usage

#### Start [DBConnection](https://github.com/elixir-ecto/db_connection) pool

```elixir
defaults = [
  scheme: "http",
  hostname: "localhost",
  port: 8123,
  database: "default",
  settings: [],
  pool_size: 1,
  timeout: :timer.seconds(15)
]

{:ok, pid} = Ch.start_link(defaults)
```

#### Select rows

```elixir
{:ok, pid} = Ch.start_link()

{:ok, %Ch.Result{rows: [[0], [1], [2]]}} =
  Ch.query(pid, "SELECT * FROM system.numbers LIMIT 3")

{:ok, %Ch.Result{rows: [[0], [1], [2]]}} =
  Ch.query(pid, "SELECT * FROM system.numbers LIMIT {limit:UInt8}", %{"limit" => 3})
```

<details>
<summary>Notes on datetime encoding in query parameters.</summary>

`NaiveDateTime` is encoded as text to make it assume the column's or ClickHouse server's timezone

```elixir

```

- `DateTime` with `Etc/UTC` timezone is encoded as unix timestamp and is treated as UTC timestamp by ClickHouse regardless of the column's or ClickHouse server's timezone

```elixir

```

- encoding non-UTC `DateTime` is "slow" and requires a [time zone database](https://hexdocs.pm/elixir/DateTime.html#module-time-zone-database)

```elixir

```

</summary>

#### Insert rows

```elixir
{:ok, pid} = Ch.start_link()

Ch.query!(pid, "CREATE TABLE IF NOT EXISTS ch_demo(id UInt64) ENGINE Null")

%Ch.Result{num_rows: 2} =
  Ch.query!(pid, "INSERT INTO ch_demo(id) VALUES (0), (1)")

%Ch.Result{num_rows: 2} =
  Ch.query!(pid, "INSERT INTO ch_demo(id) VALUES ({a:UInt16}), ({b:UInt64})", %{"a" => 0, "b" => 1})

%Ch.Result{num_rows: 2} =
  Ch.query!(pid, "INSERT INTO ch_demo(id) SELECT number FROM system.numbers LIMIT {limit:UInt8}", %{"limit" => 2})
```

#### Insert [RowBinary](https://clickhouse.com/docs/en/interfaces/formats#rowbinary)

```elixir
{:ok, pid} = Ch.start_link()

Ch.query!(pid, "CREATE TABLE IF NOT EXISTS ch_demo(id UInt64, text String) ENGINE Null")

rows = [
  [0, "a"],
  [1, "b"]
]

types = ["UInt64", "String"]
# or
types = [Ch.Types.u64(), Ch.Types.string()]
# or
types = [:u64, :string]

rowbinary = Ch.RowBinary.encode_rows(rows, types)

%Ch.Result{num_rows: 2} =
  Ch.query!(pid, ["INSERT INTO ch_demo(id, text) FORMAT RowBinary\n" | rowbinary])
```

Similarly, you can use [`RowBinaryWithNamesAndTypes`](https://clickhouse.com/docs/en/interfaces/formats#rowbinarywithnamesandtypes) which would additionally do something not quite unlike a type check for each column.

```elixir
sql = "INSERT INTO ch_demo FORMAT RowBinaryWithNamesAndTypes\n"

rows = [
  [0, "a"],
  [1, "b"]
]

types = ["UInt64", "String"]
names = ["id", "text"]

rowbinary_with_names_and_types = [
  Ch.RowBinary.encode_names_and_types(names, types),
  Ch.RowBinary.encode_rows(rows, types)
]

%Ch.Result{num_rows: 2} =
  Ch.query!(pid, [sql | rowbinary_with_names_and_types])
```

And there are buffer helpers too. They are available for RowBinary, RowBinaryWithNamesAndTypes, and Native formats.

```elixir
buffer = Ch.RowBinary.new_buffer(_types = ["UInt64", "String"])
buffer = Ch.RowBinary.push_buffer(buffer, [[0, "a"], [1, "b"]])
rowbinary = Ch.RowBinary.buffer_to_iodata(buffer)

%Ch.Result{num_rows: 2} =
  Ch.query!(pid, ["INSERT INTO ch_demo(id, text) FORMAT RowBinary\n" | rowbinary])
```

#### Insert rows in some other [format](https://clickhouse.com/docs/en/interfaces/formats)

```elixir
{:ok, pid} = Ch.start_link()

Ch.query!(pid, "CREATE TABLE IF NOT EXISTS ch_demo(id UInt64, text String) ENGINE Null")

csv =
  """
  0,"a"\n
  1,"b"\
  """

%Ch.Result{num_rows: 2} =
  Ch.query!(pid, ["INSERT INTO ch_demo(id) FORMAT CSV\n" | csv])
```

#### Insert [chunked](https://en.wikipedia.org/wiki/Chunked_transfer_encoding) RowBinary stream

```elixir
{:ok, pid} = Ch.start_link()

Ch.query!(pid, "CREATE TABLE IF NOT EXISTS ch_demo(id UInt64) ENGINE Null")

DBConnection.run(pid, fn conn ->
  Stream.repeatedly(fn -> [:rand.uniform(100)] end)
  |> Stream.chunk_every(100_000)
  |> Stream.map(fn chunk -> Ch.RowBinary.encode_rows(chunk, _types = ["UInt64"]) end)
  |> Stream.take(10)
  |> Stream.into(Ch.stream(conn, "INSERT INTO ch_demo(id) FORMAT RowBinary\n"))
  |> Stream.run()
end)
```

This query makes a [`transfer-encoding: chunked`] HTTP request while unfolding the stream resulting in lower memory usage.

#### Stream from a file

```elixir
{:ok, pid} = Ch.start_link()

Ch.query!(pid, "CREATE TABLE IF NOT EXISTS ch_demo(id UInt64) ENGINE Null")

DBConnection.run(pid, fn conn ->
  File.stream!("buffer.tmp", _chunk_size_in_bytes = 100_000)
  |> Stream.into(Ch.stream(conn, "INSERT INTO ch_demo(id) FORMAT RowBinary\n"))
  |> Stream.run()
end)
```

#### Query with custom [settings](https://clickhouse.com/docs/en/operations/settings/settings)

```elixir
{:ok, pid} = Ch.start_link()

settings = [async_insert: 1]

%Ch.Result{rows: [["async_insert", "Bool", "0"]]} =
  Ch.query!(pid, "SHOW SETTINGS LIKE 'async_insert'")

%Ch.Result{rows: [["async_insert", "Bool", "1"]]} =
  Ch.query!(pid, "SHOW SETTINGS LIKE 'async_insert'", _params = [], settings: settings)
```

## Caveats

Please see [Caveats](./guides/caveats.md)

## Benchmarks

Please see [CI Results](https://github.com/plausible/ch/actions/workflows/bench.yml) (make sure to click the latest workflow run and scroll down to "Artifacts") for [some of our benchmarks.](./bench/)

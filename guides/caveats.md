Some caveats:

- [NULL in RowBinary](#null-in-rowbinary)
- [UTF-8 in RowBinary](#utf-8-in-rowbinary)
- [Timezones in RowBinary](#timezones-in-rowbinary)
- [Dual-Stack](#dual-stack)

# NULL in RowBinary

It's the same as in [`ch-go`](https://clickhouse.com/docs/en/integrations/go#nullable)

> At insert time, Nil can be passed for both the normal and Nullable version of a column. For the former, the default value for the type will be persisted, e.g., an empty string for string. For the nullable version, a NULL value will be stored in ClickHouse.

```elixir
{:ok, pid} = Ch.start_link()

Ch.query!(pid, """
CREATE TABLE ch_nulls (
  a UInt8 NULL,
  b UInt8 DEFAULT 10,
  c UInt8 NOT NULL
) ENGINE Memory
""")

types = ["Nullable(UInt8)", "UInt8", "UInt8"]
row = [nil, nil, nil]
rowbinary = Ch.RowBinary.encode_row(row, types)

%Ch.Result{num_rows: 1} =
  Ch.query!(pid, ["INSERT INTO ch_nulls(a, b, c) FORMAT RowBinary\n" | rowbinary])

%Ch.Result{rows: [[nil, _not_10 = 0, 0]]} =
  Ch.query!(pid, "SELECT * FROM ch_nulls")
```

Note that in this example `DEFAULT 10` is ignored and `0` (the default value for `UInt8`) is persisted instead.

However, [`input()`](https://clickhouse.com/docs/en/sql-reference/table-functions/input) can be used as a workaround:

```elixir
sql = """
INSERT INTO ch_nulls
  SELECT * FROM input('a Nullable(UInt8), b Nullable(UInt8), c UInt8')
  FORMAT RowBinary
"""

types = ["Nullable(UInt8)", "Nullable(UInt8)", "UInt8"]
rowbinary = Ch.RowBinary.encode_row(row, types)

%Ch.Result{num_rows: 1} =
  Ch.query!(pid, [sql | rowbinary])

%Ch.Result{rows: [_before = [0], _after = [10]]} =
  Ch.query!(pid, "SELECT b FROM ch_nulls ORDER BY b")
```

# UTF-8 in RowBinary

When decoding [`String`](https://clickhouse.com/docs/en/sql-reference/data-types/string) columns non UTF-8 characters are replaced with `�` (U+FFFD). This behaviour is similar to [`toValidUTF8`](https://clickhouse.com/docs/en/sql-reference/functions/string-functions#tovalidutf8) and [JSON format.](https://clickhouse.com/docs/en/interfaces/formats#json)

```elixir
{:ok, pid} = Ch.start_link()

Ch.query!(pid, "CREATE TABLE ch_utf8(str String) ENGINE Memory")

rowbinary = Ch.RowBinary.encode(:string, "\x61\xF0\x80\x80\x80b")

%Ch.Result{num_rows: 1} =
  Ch.query!(pid, ["INSERT INTO ch_utf8(str) FORMAT RowBinary\n" | rowbinary])

%Ch.Result{rows: [["a�b"]]} =
  Ch.query!(pid, "SELECT * FROM ch_utf8")

%Ch.Result{rows: %{"data" => [["a�b"]]}} =
  pid |> Ch.query!("SELECT * FROM ch_utf8 FORMAT JSONCompact") |> Map.update!(:rows, &Jason.decode!/1)
```

# Timezones in RowBinary

Decoding non-UTC datetimes like `DateTime('Asia/Taipei')` requires a [timezone database.](https://hexdocs.pm/elixir/DateTime.html#module-time-zone-database)

```elixir
Mix.install([:ch, :tz])

:ok = Calendar.put_time_zone_database(Tz.TimeZoneDatabase)

{:ok, pid} = Ch.start_link()

%Ch.Result{rows: [[~N[2023-04-25 17:45:09]]]} =
  Ch.query!(pid, "SELECT CAST(now() as DateTime)")

%Ch.Result{rows: [[~U[2023-04-25 17:45:11Z]]]} =
  Ch.query!(pid, "SELECT CAST(now() as DateTime('UTC'))")

%Ch.Result{rows: [[%DateTime{time_zone: "Asia/Taipei"} = taipei]]} =
  Ch.query!(pid, "SELECT CAST(now() as DateTime('Asia/Taipei'))")

"2023-04-26 01:45:12+08:00 CST Asia/Taipei" = to_string(taipei)
```

Encoding non-UTC datetimes is possible but slow.

```elixir
Ch.query!(pid, "CREATE TABLE ch_datetimes(datetime DateTime) ENGINE Null")

naive = NaiveDateTime.utc_now()
utc = DateTime.utc_now()
taipei = DateTime.shift_zone!(utc, "Asia/Taipei")

rows = [
  [naive],
  [utc],
  [taipei]
]

types = ["DateTime"]

Ch.RowBinary.encode_rows(rows, types)
```

# Dual-Stack

just use happy tcp

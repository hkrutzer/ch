defmodule Ch do
  @moduledoc "Minimal HTTP ClickHouse client."
  alias Ch.{Connection, Query, Result}

  @doc """
  Start the connection process and connect to ClickHouse.

  ## Options

    * `:hostname` - server hostname, defaults to `"localhost"`
    * `:port` - HTTP port, defualts to `8123`
    * `:scheme` - HTTP scheme, defaults to `"http"`
    * `:database` - Database, defaults to `"default"`
    * `:username` - Username
    * `:password` - User password
    * `:settings` - Keyword list of ClickHouse settings
    * `:timeout` - HTTP receive timeout in milliseconds
    * `:transport_opts` - options to be given to the transport being used. See `Mint.HTTP1.connect/4` for more info

  """
  def start_link(opts \\ []) do
    DBConnection.start_link(Connection, opts)
  end

  @doc """
  Returns a supervisor child specification for a DBConnection pool.
  """
  def child_spec(opts) do
    DBConnection.child_spec(Connection, opts)
  end

  @type statement :: iodata | Enumerable.t()
  @type params :: %{String.t() => term} | [{String.t(), term}]
  @type option ::
          {:settings, Keyword.t()}
          | {:database, String.t()}
          | {:username, String.t()}
          | {:password, String.t()}
          | {:command, Ch.Query.command()}
          | {:decode, boolean}
          | {:headers, String.t()}

  @type options :: [option | DBConnection.connection_option()]

  @doc """
  Runs a query and returns the result as `{:ok, %Ch.Result{}}` or
  `{:error, Exception.t()}` if there was a database error.

  ## Options

    * `:timeout` - Query request timeout
    * `:settings` - Keyword list of settings
    * `:database` - Database
    * `:username` - Username
    * `:password` - User password

  """
  @spec query(DBConnection.conn(), statement, params, options) ::
          {:ok, Result.t()} | {:error, Exception.t()}
  def query(conn, statement, params \\ [], opts \\ []) do
    query = Query.build(statement, opts)

    with {:ok, _query, result} <- DBConnection.execute(conn, query, params, opts) do
      {:ok, result}
    end
  end

  @doc """
  Runs a query and returns the result or raises `Ch.Error` if
  there was an error. See `query/4`.
  """
  @spec query!(DBConnection.conn(), statement, params, options) :: Result.t()
  def query!(conn, statement, params \\ [], opts \\ []) do
    query = Query.build(statement, opts)
    DBConnection.execute!(conn, query, params, opts)
  end

  @doc false
  @spec stream(DBConnection.t(), statement, params, options) :: DBConnection.Stream.t()
  def stream(conn, statement, params \\ [], opts \\ []) do
    query = Query.build(statement, opts)
    DBConnection.stream(conn, query, params, opts)
  end

  if Code.ensure_loaded?(Ecto.ParameterizedType) do
    @behaviour Ecto.ParameterizedType

    @impl true
    def type(params), do: {:parameterized, Ch, params}

    @impl true
    def init(opts) do
      clickhouse_type =
        opts[:raw] || opts[:type] ||
          raise ArgumentError, "keys :raw or :type not found in: #{inspect(opts)}"

      Ch.Types.decode(clickhouse_type)
    end

    @impl true
    def load(value, _loader, _params), do: {:ok, value}

    @impl true
    def dump(value, _dumper, _params), do: {:ok, value}

    @impl true
    def cast(value, :string = type), do: Ecto.Type.cast(type, value)
    def cast(value, :boolean = type), do: Ecto.Type.cast(type, value)
    def cast(value, :uuid), do: Ecto.Type.cast(Ecto.UUID, value)
    def cast(value, :date = type), do: Ecto.Type.cast(type, value)
    def cast(value, :date32), do: Ecto.Type.cast(:date, value)
    def cast(value, :datetime), do: Ecto.Type.cast(:naive_datetime, value)
    def cast(value, {:datetime, "UTC"}), do: Ecto.Type.cast(:utc_datetime, value)
    def cast(value, {:datetime64, _p}), do: Ecto.Type.cast(:naive_datetime_usec, value)
    def cast(value, {:datetime64, _p, "UTC"}), do: Ecto.Type.cast(:utc_datetime_usec, value)
    def cast(value, {:fixed_string, _s}), do: Ecto.Type.cast(:string, value)

    for size <- [8, 16, 32, 64, 128, 256] do
      def cast(value, unquote(:"i#{size}")), do: Ecto.Type.cast(:integer, value)
      def cast(value, unquote(:"u#{size}")), do: Ecto.Type.cast(:integer, value)
    end

    for size <- [32, 64] do
      def cast(value, unquote(:"f#{size}")), do: Ecto.Type.cast(:float, value)
    end

    def cast(value, {:decimal = type, _p, _s}), do: Ecto.Type.cast(type, value)

    for size <- [32, 64, 128, 256] do
      def cast(value, {unquote(:"decimal#{size}"), _s}) do
        Ecto.Type.cast(:decimal, value)
      end
    end

    def cast(value, {:array, type}), do: Ecto.Type.cast({:array, type(type)}, value)
    def cast(value, {:nullable, type}), do: cast(value, type)
    def cast(value, {:low_cardinality, type}), do: cast(value, type)
    def cast(value, {:simple_aggregate_function, _name, type}), do: cast(value, type)

    def cast(value, :ring), do: Ecto.Type.cast({:array, type(:point)}, value)
    def cast(value, :polygon), do: Ecto.Type.cast({:array, type(:ring)}, value)
    def cast(value, :multipolygon), do: Ecto.Type.cast({:array, type(:polygon)}, value)

    def cast(nil, _params), do: {:ok, nil}

    def cast(value, {enum, mappings}) when enum in [:enum8, :enum16] do
      result =
        case value do
          _ when is_integer(value) -> List.keyfind(mappings, value, 1, :error)
          _ when is_binary(value) -> List.keyfind(mappings, value, 0, :error)
          _ -> :error
        end

      case result do
        {_, _} -> {:ok, value}
        :error = e -> e
      end
    end

    def cast(value, :ipv4) do
      case value do
        {a, b, c, d} when is_number(a) and is_number(b) and is_number(c) and is_number(d) ->
          {:ok, value}

        _ when is_binary(value) ->
          with {:error = e, _reason} <- :inet.parse_ipv4_address(to_charlist(value)), do: e

        _ when is_list(value) ->
          with {:error = e, _reason} <- :inet.parse_ipv4_address(value), do: e

        _ ->
          :error
      end
    end

    def cast(value, :ipv6) do
      case value do
        {a, s, d, f, g, h, j, k}
        when is_number(a) and is_number(s) and is_number(d) and is_number(f) and
               is_number(g) and is_number(h) and is_number(j) and is_number(k) ->
          {:ok, value}

        _ when is_binary(value) ->
          with {:error = e, _reason} <- :inet.parse_ipv6_address(to_charlist(value)), do: e

        _ when is_list(value) ->
          with {:error = e, _reason} <- :inet.parse_ipv6_address(value), do: e

        _ ->
          :error
      end
    end

    def cast(value, :point) do
      case value do
        {x, y} when is_number(x) and is_number(y) -> {:ok, value}
        _ -> :error
      end
    end

    def cast(value, {:tuple, types}), do: cast_tuple(types, value)
    def cast(value, {:map, key_type, value_type}), do: cast_map(value, key_type, value_type)

    defp cast_tuple(types, values) when is_tuple(values) do
      cast_tuple(types, Tuple.to_list(values), [])
    end

    defp cast_tuple(types, values) when is_list(values) do
      cast_tuple(types, values, [])
    end

    defp cast_tuple(_types, _values), do: :error

    defp cast_tuple([type | types], [value | values], acc) do
      case cast(value, type) do
        {:ok, value} -> cast_tuple(types, values, [value | acc])
        :error = e -> e
      end
    end

    defp cast_tuple([], [], acc), do: {:ok, List.to_tuple(:lists.reverse(acc))}
    defp cast_tuple(_types, _values, _acc), do: :error

    defp cast_map(value, key_type, value_type) when is_map(value) do
      cast_map(Map.to_list(value), key_type, value_type)
    end

    defp cast_map(value, key_type, value_type) when is_list(value) do
      cast_map(value, key_type, value_type, [])
    end

    defp cast_map(_value, _key_type, _value_type), do: :error

    defp cast_map([{key, value} | kvs], key_type, value_type, acc) do
      with {:ok, key} <- cast(key, key_type),
           {:ok, value} <- cast(value, value_type) do
        cast_map(kvs, key_type, value_type, [{key, value} | acc])
      end
    end

    defp cast_map([], _key_type, _value_type, acc), do: {:ok, Map.new(acc)}
    defp cast_map(_kvs, _key_type, _value_type, _acc), do: :error

    @impl true
    def embed_as(_, _), do: :self

    @impl true
    def equal?(a, b, _), do: a == b

    @impl true
    def format(params) do
      "#Ch<#{Ch.Types.encode(params)}>"
    end
  end
end

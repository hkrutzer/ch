defmodule Ch.Connection do
  @moduledoc false
  use DBConnection
  alias Ch.Error
  alias Mint.HTTP1, as: HTTP

  @impl true
  def connect(opts) do
    scheme = String.to_existing_atom(opts[:scheme] || "http")

    # TODO or hostname?
    address = opts[:host] || "localhost"
    port = opts[:port] || 8123

    # TODO active: once, active: false, how to deal with checkout / controlling process?
    with {:ok, conn} <- HTTP.connect(scheme, address, port, mode: :passive) do
      conn =
        conn
        |> HTTP.put_private(:database, opts[:database] || "default")
        |> HTTP.put_private(:timeout, opts[:timeout] || :timer.seconds(5))
        |> maybe_put_private(:username, opts[:username])
        |> maybe_put_private(:password, opts[:password])

      {:ok, conn}
    end
  end

  @impl true
  def ping(conn) do
    with {:ok, conn, ref} <- request(conn, "GET", "/ping", _headers = [], _body = ""),
         {:ok, conn, _responses} <- receive_stream(conn, ref),
         do: {:ok, conn}
  end

  @impl true
  def checkout(conn) do
    {:ok, conn}
  end

  @impl true
  def handle_begin(_opts, conn) do
    {:disconnect, Error.exception("transactions are not supported"), conn}
  end

  @impl true
  def handle_commit(_opts, conn) do
    {:disconnect, Error.exception("transactions are not supported"), conn}
  end

  @impl true
  def handle_rollback(_opts, conn) do
    {:disconnect, Error.exception("transactions are not supported"), conn}
  end

  @impl true
  def handle_status(_opts, conn) do
    {:disconnect, Error.exception("transactions are not supported"), conn}
  end

  @impl true
  def handle_prepare(query, _opts, conn) do
    {:ok, query, conn}
  end

  @impl true
  def handle_execute(%Ch.Query{command: :insert} = query, stream_or_iodata, opts, conn) do
    %Ch.Query{statement: statement} = query

    with {:ok, conn, ref} <- request(conn, "POST", "/", headers(conn, opts), :stream),
         {:ok, conn} <- stream_body(conn, ref, statement, stream_or_iodata),
         {:ok, conn, responses} <- receive_stream(conn, ref) do
      [_status, {:headers, _ref, headers} | _responses] = responses
      # TODO or lists:keyfind
      raw_summary = :proplists.get_value("x-clickhouse-summary", headers, nil)

      written_rows =
        if raw_summary do
          %{"written_rows" => written_rows} = Jason.decode!(raw_summary)
          String.to_integer(written_rows)
        end

      {:ok, query, %{num_rows: written_rows, rows: []}, conn}
    end
  end

  def handle_execute(query, params, opts, conn) do
    %Ch.Query{statement: statement} = query
    path = "/?" <> encode_params_qs(params)

    # TODO ok to POST for everything, does it make the query not a readonly?
    with {:ok, conn, ref} <- request(conn, "POST", path, headers(conn, opts), statement),
         {:ok, conn, responses} <- receive_stream(conn, ref, opts) do
      [_status, {:headers, ^ref, headers} | responses] = responses
      data = responses |> collect_body(ref) |> IO.iodata_to_binary()
      # TODO
      {:ok, query, %{headers: headers, data: data}, conn}
    end
  end

  @impl true
  def handle_close(_query, _opts, conn) do
    {:ok, _result = nil, conn}
  end

  @impl true
  def handle_declare(_query, _params, _opts, conn) do
    {:error, Error.exception("cursors are not supported"), conn}
  end

  @impl true
  def handle_fetch(_query, _cursor, _opts, conn) do
    {:error, Error.exception("cursors are not supported"), conn}
  end

  @impl true
  def handle_deallocate(_query, _cursor, _opts, conn) do
    {:error, Error.exception("cursors are not supported"), conn}
  end

  @impl true
  def disconnect(_error, conn) do
    {:ok = ok, _conn} = HTTP.close(conn)
    ok
  end

  defp maybe_put_private(conn, _k, nil), do: conn
  defp maybe_put_private(conn, k, v), do: HTTP.put_private(conn, k, v)

  defp get_opts_or_private(conn, opts, key) do
    opts[key] || HTTP.get_private(conn, key)
  end

  defp headers(conn, opts) do
    []
    |> maybe_put_header("x-clickhouse-user", get_opts_or_private(conn, opts, :username))
    |> maybe_put_header("x-clickhouse-key", get_opts_or_private(conn, opts, :password))
    |> maybe_put_header("x-clickhouse-database", get_opts_or_private(conn, opts, :database))
  end

  defp maybe_put_header(headers, _k, nil), do: headers
  defp maybe_put_header(headers, k, v), do: [{k, v} | headers]

  # @compile inline: [request: 5]
  defp request(conn, method, path, headers, body) do
    case HTTP.request(conn, method, path, headers, body) do
      {:ok, _conn, _ref} = ok -> ok
      {:error, _conn, _reason} = error -> disconnect(error)
    end
  end

  def stream_body(conn, ref, statement, data) do
    # TODO HTTP.stream_request_body(conn, ref, [statement, ?\n])?
    stream = Stream.concat([[statement, ?\n]], data)

    # TODO bench vs manual
    reduced =
      Enum.reduce_while(stream, {:ok, conn}, fn
        chunk, {:ok, conn} -> {:cont, HTTP.stream_request_body(conn, ref, chunk)}
        _chunk, error -> {:halt, error}
      end)

    case reduced do
      {:ok, conn} ->
        case HTTP.stream_request_body(conn, ref, :eof) do
          {:ok, _conn} = ok -> ok
          {:error, _conn, _error} = error -> disconnect(error)
        end

      {:halt, {:error, _conn, _error} = error} ->
        disconnect(error)
    end
  end

  defp receive_stream(conn, ref, opts \\ []) do
    case receive_stream(conn, ref, [], opts) do
      {:ok, _conn, [{:status, _ref, 200} | _rest]} = ok ->
        ok

      # TODO headers have error code, use that
      {:ok, conn, [_status, _headers | responses]} ->
        error = responses |> collect_body(ref) |> IO.iodata_to_binary()
        {:error, Error.exception(error), conn}

      {:error, _conn, _error, _responses} = error ->
        disconnect(error)
    end
  end

  @spec receive_stream(HTTP.t(), reference, [Mint.Types.response()], Keyword.t()) ::
          {:ok, HTTP.t(), [Mint.Types.response()]}
          | {:error, HTTP.t(), Mint.Types.error(), [Mint.Types.response()]}
  defp receive_stream(conn, ref, acc, opts) do
    timeout = opts[:timeout] || HTTP.get_private(conn, :timeout)

    case HTTP.recv(conn, 0, timeout) do
      {:ok, conn, responses} ->
        case handle_responses(responses, ref, acc) do
          {:ok, resp} -> {:ok, conn, resp}
          {:more, acc} -> receive_stream(conn, ref, acc, opts)
        end

      {:error, _conn, _reason, responses} = error ->
        put_elem(error, 3, acc ++ responses)
    end
  end

  # TODO wrap errors in Ch.Error?
  @spec disconnect({:error, HTTP.t(), Mint.Types.error(), [Mint.Types.response()]}) ::
          {:disconnect, Mint.Types.error(), HTTP.t()}
  defp disconnect({:error, conn, error, _responses}) do
    {:disconnect, error, conn}
  end

  @spec disconnect({:error, HTTP.t(), Mint.Types.error()}) ::
          {:disconnect, Mint.Types.error(), HTTP.t()}
  defp disconnect({:error, conn, error}) do
    {:disconnect, error, conn}
  end

  # TODO handle rest
  defp handle_responses([{:done, ref} = done], ref, acc) do
    {:ok, :lists.reverse([done | acc])}
  end

  defp handle_responses([{tag, ref, _data} = resp | rest], ref, acc)
       when tag in [:data, :status, :headers] do
    handle_responses(rest, ref, [resp | acc])
  end

  defp handle_responses([], _ref, acc), do: {:more, acc}

  @spec collect_body([{:data, reference, binary} | {:done, reference}], reference) :: iodata
  defp collect_body([{:data, ref, data} | responses], ref) do
    [data | collect_body(responses, ref)]
  end

  defp collect_body([{:done, ref}], ref), do: []

  # TODO support just one approach?
  defp encode_params_qs(params) when is_map(params) do
    params |> Map.new(fn {k, v} -> {"param_#{k}", encode_param(v)} end) |> URI.encode_query()
  end

  defp encode_params_qs([{_k, _v} | _] = params) do
    params |> Map.new(fn {k, v} -> {"param_#{k}", encode_param(v)} end) |> URI.encode_query()
  end

  defp encode_params_qs(params) when is_list(params) do
    params
    |> Enum.with_index()
    |> Map.new(fn {v, idx} -> {"param_$#{idx}", encode_param(v)} end)
    |> URI.encode_query()
  end

  defp encode_param(n) when is_number(n), do: Integer.to_string(n)
  defp encode_param(b) when is_binary(b), do: b
  defp encode_param(f) when is_float(f), do: Float.to_string(f)
  defp encode_param(%s{} = d) when s in [Date, DateTime, NaiveDateTime], do: d

  defp encode_param(a) when is_list(a) do
    IO.iodata_to_binary([?[, encode_array_param(a), ?]])
  end

  # TODO [1, 2] => 1,2, (CH doesn't seem to mind trailing comma, but still...)
  defp encode_array_param([s | rest]) when is_binary(s) do
    # TODO faster escaping
    [?', String.replace(s, "'", "\\'"), "'," | encode_array_param(rest)]
  end

  defp encode_array_param([el | rest]) do
    [encode_param(el), "," | encode_array_param(rest)]
  end

  defp encode_array_param([] = done), do: done
end

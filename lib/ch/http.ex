defmodule Ch.HTTP do
  @moduledoc false
  import Kernel, except: [send: 2]

  @user_agent "github.com/plausible/ch/releases/tag/v" <> Mix.Project.config()[:version]

  # TODO on raise protect x-clickhouse-password

  @type scheme :: :http | :https | String.t()
  @type host :: :inet.socket_address() | :inet.hostname() | String.t()
  @type socket :: :gen_tcp.socket() | :ssl.sslsocket()
  @type error :: {:error, Ch.Error.t() | Ch.HTTPError.t() | Ch.TransportError.t()}

  @spec connect(scheme, host, :inet.port_number(), [:gen_tcp.connect_option()], timeout) ::
          {:ok, socket} | error
  def connect(scheme, address, port, opts, timeout) do
    protocol = protocol(scheme)

    opts =
      case protocol do
        :http -> opts
        :https -> Ch.SSL.opts(address, opts)
      end

    address =
      if is_binary(address) do
        String.to_charlist(address)
      else
        address
      end

    connect_result =
      case protocol do
        :http -> :gen_tcp.connect(address, port, opts, timeout)
        :https -> :ssl.connect(address, port, opts, timeout)
      end

    case connect_result do
      {:ok, _socket} = ok -> ok
      {:error, reason} -> {:error, Ch.TransportError.exception(reason: reason)}
    end
  end

  defp protocol(protocol) when protocol in [:http, :https], do: protocol

  defp protocol(scheme) when is_binary(scheme) do
    case String.downcase(scheme) do
      "http" -> :http
      "https" -> :https
    end
  end

  @spec close(socket) :: :ok | {:error, Ch.TransportError.t()}
  def close(socket) when is_port(socket), do: :gen_tcp.close(socket)

  def close(socket) do
    case :ssl.close(socket) do
      :ok = ok -> ok
      # not raising since that error is unlikely to be useful
      {:error, reason} -> {:error, Ch.TransportError.exception(reason: reason)}
    end
  end

  @keepalive_and_ua "\r\nConnection: Keep-Alive\r\nUser-Agent: #{@user_agent}\r\n"

  defp build(:get, path, host, headers, _body) do
    [
      "GET ",
      path,
      " HTTP/1.1\r\n Host: ",
      host,
      @keepalive_and_ua,
      format_headers(headers),
      "\r\n"
    ]
  end

  defp build(:post, path, host, headers, body) do
    # TODO
    # content_length = body |> IO.iodata_length() |> String.to_integer()
    # headers = [{"Content-Length", content_length} | headers]

    [
      "POST ",
      path,
      " HTTP/1.1\r\n Host: ",
      host,
      @keepalive_and_ua,
      format_headers(headers),
      "\r\n" | body
    ]
  end

  defp format_headers([{key, value} | headers]) do
    [key, ": ", value, "\r\n" | format_headers(headers)]
  end

  defp format_headers([] = done), do: done

  def request(socket, method, path, host, headers, body) do
    case send(socket, build(method, path, host, headers, body)) do
      :ok -> recv_all(socket)
      {:error, reason} -> raise Ch.TransportError, reason: reason
    end
  rescue
    e -> reraise e, prune_args_from_stacktrace(__STACKTRACE__)
  end

  @spec prune_args_from_stacktrace(Exception.stacktrace()) :: Exception.stacktrace()
  defp prune_args_from_stacktrace([{mod, fun, [_ | _] = args, info} | rest]) do
    [{mod, fun, length(args), info} | rest]
  end

  defp prune_args_from_stacktrace(stacktrace) when is_list(stacktrace) do
    stacktrace
  end

  # def query(socket, sql, params, opts) do
  #   host = Map.fetch!(opts, :host)

  #   path = "/?" <> encode_params(params)
  #   headers = [{"content-length", IO.iodata_length(sql)}]

  #   case request(socket, "POST", path, host, headers, sql) do
  #     {:ok, status, headers, body} ->
  #       nil
  #   end
  # end

  defp recv_all(socket) do
    packet = recv(socket, 0, :timer.seconds(30))

    case decode_status_line(packet) do
      {:ok, {{1, _minor_version}, status, _reason}, buffer} ->
        case decode_headers(buffer, _headers_acc = []) do
          {:ok, headers, buffer} ->
            {_, content_length} = List.keyfind!(headers, :"Content-Length", 0)
            {body, buffer} = recv_body(socket, content_length, buffer)
            {status, headers, body, buffer}

          {:more, headers_acc, buffer} ->
            {:ok, headers, buffer} = recv_headers(socket, headers_acc, buffer)
            {_, content_length} = List.keyfind!(headers, :"Content-Length", 0)
            {body, buffer} = recv_body(socket, content_length, buffer)
            {status, headers, body, buffer}
        end

      {:more, buffer} ->
        recv_status(socket, buffer)

      {:error, reason} ->
        raise Ch.TransportError, reason: reason
    end
  end

  defp recv_status(socket, buffer) do
    packet = recv(socket, 0, :timer.seconds(30))
    buffer = buffer <> packet

    case decode_status_line(buffer) do
      {:ok, _response} = ok -> ok
      :more -> recv_status(socket, buffer)
    end
  end

  defp recv_headers(socket, acc, buffer) do
    packet = recv(socket, 0, :timer.seconds(30))
    buffer = buffer <> packet

    case decode_headers(buffer, acc) do
      {:ok, headers, buffer} -> {:ok, headers, buffer}
      {:more, acc, buffer} -> recv_headers(socket, acc, buffer)
    end
  end

  defp recv_body(socket, :chunked, buffer) do
  end

  defp recv_body(socket, content_length, buffer) do
    buffer_size = byte_size(buffer)
    to_receive = content_length - buffer_size

    cond do
      to_receive == 0 ->
        {:ok, buffer, <<>>}

      to_receive < 0 ->
        <<body::size(content_length)-bytes, buffer::bytes>> = buffer
        {:ok, body, buffer}

      to_receive > 0 ->
        case recv(socket, to_receive, :timer.seconds(30)) do
          {:ok, packet} -> {:ok, [buffer | packet], <<>>}
          {:error, reason} -> raise Ch.TransportError, reason: reason
        end
    end
  end

  defp decode_status_line(packet) do
    case :erlang.decode_packet(:http_bin, packet, []) do
      {:ok, {:http_response, version, status, reason}, rest} ->
        {:ok, {version, status, reason}, rest}

      {:ok, _other, _rest} ->
        raise Ch.HTTPError, state: :status

      {:more, _length} ->
        :more

      {:error, _reason} ->
        raise Ch.HTTPError, state: :status
    end
  end

  defp decode_headers(packet, acc) do
    case decode_header(packet) do
      {:ok, kv, rest} -> decode_headers(rest, [kv | acc])
      {:ok, :eof, rest} -> {:ok, :lists.reverse(acc), rest}
      :more -> {:more, acc, packet}
    end
  end

  defp decode_header(packet) do
    case :erlang.decode_packet(:httph_bin, packet, []) do
      {:ok, {:http_header, _unused, name, _reserved, value}, rest} ->
        {:ok, {name, value}, rest}

      {:ok, :http_eoh, rest} ->
        {:ok, :eof, rest}

      {:ok, _other, _rest} ->
        raise Ch.HTTPError, stage: :headers

      {:more, _length} ->
        :more

      {:error, _reason} ->
        raise Ch.HTTPError, stage: :headers
    end
  end

  defp decode_chunk(buffer) do
    case :binary.split(buffer, "\r\n") do
      [_size] ->
        # TODO ensure not too big
        {:more, buffer}

      [size, data] ->
        chunk_size = String.to_integer(size, 16)
        data_size = byte_size(data)

        cond do
          chunk_size == 0 and data_size >= 5 ->
            "0\r\n\r\n" <> buffer = data
            {:eof, buffer}

          chunk_size > 0 and data_size >= chunk_size + 4 ->
            <<chunk::size(chunk_size)-bytes, "\r\n", buffer::bytes>> = data
            {:more, chunk, buffer}

          true ->
            {:more, buffer}
        end
    end
  end

  @compile inline: [send: 2]
  defp send(socket, data) when is_port(socket), do: :gen_tcp.send(socket, data)
  defp send(socket, data), do: :ssl.send(socket, data)

  @compile inline: [recv: 3]
  defp recv(socket, size, timeout) when is_port(socket), do: :gen_tcp.recv(socket, size, timeout)
  defp recv(socket, size, timeout), do: :ssl.recv(socket, size, timeout)
end

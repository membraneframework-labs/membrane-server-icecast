defmodule Membrane.Server.Icecast.HTTP do

  @end_of_line "\r\n"

  def request(method, path, headers, ver \\ "1.0") do
    http_header(method, path, ver) <> http_headers(headers) <> "\r\n"
  end

  def http_header(method, path, ver \\ "1.0"), do: "#{method} #{path} HTTP/#{ver}#{@end_of_line}"

  def http_headers(headers) do
    headers
    |> Enum.map(fn {k, v} -> "#{k}: #{v}\r\n" end)
    |> Enum.reduce("", fn h1, h2 -> h1 <> h2 end)
  end

  def connect(port) do
    {:ok, conn} = :gen_tcp.connect('localhost', port, [active: false, mode: :binary])
    conn
  end

  def get_http_response_status_headers(conn) do
    {:ok, data} = :gen_tcp.recv(conn, 0)

    {:ok, {version, status, reason}, rest} = fetch_status_line(conn, data)
    {headers, rest} = fetch_headers(conn, rest)

    %{:version => version, :status => status, :reason => reason,
      :headers => headers, :tcp_rest => rest}

  end


  defp fetch_status_line(conn, binary) do
    case :erlang.decode_packet(:http_bin, binary, []) do
      {:ok, {:http_response, version, status, reason}, rest} ->
        {:ok, {version, status, reason}, rest}
      {:more, len} ->
        rest = :gen_tcp.recv(conn, len)
        fetch_status_line(conn, binary <> rest)
      _ ->
        :error
    end
  end

  defp fetch_headers(conn, data, acc \\ []) do
    case decode_header(data) do
      {:ok, :eof, rest} ->
        {acc, rest}
      {:more, len} ->
        rest = :gen_tcp.recv(conn, len)
        fetch_headers(conn, rest, acc)
      {:ok, h, rest} ->
        fetch_headers(conn, rest, [h | acc])
    end
  end

  defp decode_header(binary) do
    case :erlang.decode_packet(:httph_bin, binary, []) do
      {:ok, {:http_header, _unused, name, _reserved, value}, rest} ->
        {:ok, {header_name(name), value}, rest}
      {:ok, :http_eoh, rest} ->
        {:ok, :eof, rest}
    end
  end

  defp header_name(atom) when is_atom(atom), do: atom |> Atom.to_string() |> String.downcase
  defp header_name(binary) when is_binary(binary), do: binary |> String.downcase

end

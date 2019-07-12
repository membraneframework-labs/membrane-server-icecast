defmodule Membrane.Server.Icecast.ServerTest do
  use ExUnit.Case, async: true
  alias Membrane.Protocol.Icecast.Input.Machine, as: InputMachine
  alias Membrane.Protocol.Icecast.Output.Machine, as: OutputMachine

  alias Membrane.Server.Icecast.Input
  alias Membrane.Server.Icecast.Output

  alias Membrane.Server.Icecast.HTTP

  @receive_timeout 50
  @body_timeout 300

  @mp3_path "test/mp3_sample.mp3"
  @ogg_path "test/ogg_sample.ogg"

  defmodule UsersDB do
    def start_link, do: Agent.start(&MapSet.new/0, name: __MODULE__)

    def register(user, pass),
      do: Agent.update(__MODULE__, fn users -> MapSet.put(users, {user, pass}) end)

    def unregister(user, pass),
      do: Agent.update(__MODULE__, fn users -> MapSet.delete(users, {user, pass}) end)

    def registered?(user, pass),
      do: Agent.get(__MODULE__, fn users -> MapSet.member?(users, {user, pass}) end)
  end

  defmodule MountDB do
    defstruct format: nil, procs: []

    def start_link, do: Agent.start(fn -> %{} end, name: __MODULE__)

    def set_format(mount, format) do
      mountinfo = get(mount, %__MODULE__{})
      new_mountinfo = %__MODULE__{mountinfo | format: format}
      put(mount, new_mountinfo)
    end

    def set_proc(mount, proc) do
      prev = get(mount)

      case prev do
        nil ->
          {:error, :not_found}

        %__MODULE__{procs: procs} = mount_info ->
          new_mountinfo = %__MODULE__{mount_info | procs: [proc | procs]}
          put(mount, new_mountinfo)
          :ok
      end
    end

    def unregister(mount),
      do: Agent.update(__MODULE__, fn mounts -> Map.delete(mounts, mount) end)

    def unregister(mount, proc) do
      mountinfo = get(mount)

      case mountinfo do
        %__MODULE__{procs: procs} ->
          new_procs = List.delete(procs, proc)
          new_mountinfo = %__MODULE__{mountinfo | procs: new_procs}
          put(mount, new_mountinfo)

        # already unregistered
        nil ->
          :ok
      end
    end

    def get_procs(mount) do
      mountinfo = get(mount)

      case mountinfo do
        nil -> []
        %__MODULE__{procs: procs} -> procs
      end
    end

    def get_format(mount) do
      %__MODULE__{format: format} = get(mount)
      format
    end

    def mount_free?(mount) do
      get(mount) == nil
    end

    defp get(mount, default \\ nil), do: Agent.get(__MODULE__, &Map.get(&1, mount, default))

    defp put(mount, mountinfo), do: Agent.update(__MODULE__, &Map.put(&1, mount, mountinfo))
  end

  defmodule InputTestController do
    use Membrane.Protocol.Icecast.Input.Controller

    def handle_init(state) do
      {:ok, state}
    end

    def handle_incoming(_remote_address, controller_state) do
      {:ok, {:allow, controller_state}}
    end

    def handle_source(_address, _method, state, %{
          format: format,
          mount: mount,
          username: user,
          password: pass
        }) do
      case UsersDB.registered?(user, pass) and MountDB.mount_free?(mount) do
        true ->
          MountDB.set_format(mount, format)
          {:ok, {:allow, %{my_mount: mount}}}

        false ->
          {:ok, {:deny, :unauthorized}}
      end
    end

    def handle_payload(_address, payload, %{my_mount: my_mount} = state) do
      my_mount
      |> MountDB.get_procs()
      |> Enum.each(fn p -> send(p, {:payload, payload}) end)

      {:ok, {:continue, state}}
    end

    def handle_invalid(_address, _reason, _state) do
      :ok
    end

    def handle_timeout(_address, _state) do
      :ok
    end

    def handle_closed(_address, %{my_mount: my_mount}) do
      :ok = MountDB.unregister(my_mount)
    end

    def handle_closed(_address, _state) do
      :ok
    end
  end

  defmodule OutputTestController do
    def handle_init(arg) do
      {:ok, arg}
    end

    def handle_incoming(_address, state) do
      {:ok, {:allow, state}}
    end

    def handle_listener(_address, mount, _headers, _state) do
      case MountDB.set_proc(mount, self()) do
        :ok ->
          format = MountDB.get_format(mount)
          {:ok, {:allow, %{my_mount: mount}}, format}

        {:error, :not_found} ->
          {:ok, {:deny, :not_found}}
      end
    end

    def handle_closed(_address, %{my_mount: my_mount} = _state) do
      MountDB.unregister(my_mount, self())
      :ok
    end

    def handle_closed(_address, _state) do
      :ok
    end

    def handle_timeout(_address, _state) do
      :ok
    end

    def handle_invalid(_address, _reason, _state) do
      :ok
    end
  end

  setup_all do
    UsersDB.start_link()
    MountDB.start_link()

    Application.put_env(:membrane_server_icecast, :input_machine, InputMachine)
    Application.put_env(:membrane_server_icecast, :output_machine, OutputMachine)

    {:ok, _} =
      Output.Listener.start_listener(3000, OutputTestController, nil, body_timeout: @body_timeout)

    {:ok, _} =
      Input.Listener.start_listener(4000, InputTestController, nil, body_timeout: @body_timeout)

    on_exit(fn ->
      # TODO
      :ok
    end)
  end

  describe "Connection tests" do
    setup do
      {user, pass} = creds = {unique("Juliet"), "I<3Romeo"}
      UsersDB.register(user, pass)

      on_exit(fn ->
        UsersDB.unregister(user, pass)
      end)

      %{mount: unique("/somemount"), input_creds: creds}
    end

    test "Source client reconnecting", %{input_creds: input_creds, mount: mount} do
      basic_auth = encode_user_pass(input_creds)
      input_port = Input.Listener.get_port!()

      source_client = HTTP.connect(input_port)

      %{status: 200} =
        make_req(source_client, "SOURCE", mount, [
          {"Content-Type", "audio/mpeg"},
          {"Authorization", basic_auth}
        ])

      HTTP.disconnect(source_client)

      source_client = HTTP.connect(input_port)

      assert %{status: 200} =
               make_req(source_client, "SOURCE", mount, [
                 {"Content-Type", "audio/mpeg"},
                 {"Authorization", basic_auth}
               ])

      HTTP.disconnect(source_client)
    end

    test "Client reconnecting", %{input_creds: input_creds, mount: mount} do
      basic_auth = encode_user_pass(input_creds)
      input_port = Input.Listener.get_port!()
      output_port = Output.Listener.get_port!()

      source_client = HTTP.connect(input_port)
      client = HTTP.connect(output_port)

      streaming_interval = 10

      %{status: 200} =
        make_req(source_client, "SOURCE", mount, [
          {"Content-Type", "audio/mpeg"},
          {"Authorization", basic_auth}
        ])

      payload = "I love you romeo"

      stream_pid = start_streaming(source_client, payload, streaming_interval)

      %{status: 200} = make_req(client, "GET", mount, [])

      assert {:ok, ^payload} = :gen_tcp.recv(client, String.length(payload))

      HTTP.disconnect(client)

      :timer.sleep(3 * streaming_interval)

      client = HTTP.connect(output_port)

      %{status: 200} = make_req(client, "GET", mount, [])

      assert {:ok, ^payload} = :gen_tcp.recv(client, String.length(payload))

      stop_streaming(stream_pid)
    end
  end

  describe "When client logged in and connection established" do
    setup do
      {user, pass} = creds = {unique("Juliet"), "I<3Romeo"}
      UsersDB.register(user, pass)

      input_port = Input.Listener.get_port!()
      output_port = Output.Listener.get_port!()
      source_client = HTTP.connect(input_port)
      client = HTTP.connect(output_port)

      on_exit(fn ->
        UsersDB.unregister(user, pass)
        HTTP.disconnect(source_client)
        HTTP.disconnect(client)
      end)

      %{mount: unique("/somemount"), source_client: {source_client, creds}, client: client}
    end

    test "Payload can be streamed successfully", %{
      source_client: {source_client, input_creds},
      client: client,
      mount: mount
    } do
      basic_auth = encode_user_pass(input_creds)

      assert %{status: 200} =
               make_req(source_client, "SOURCE", mount, [
                 {"Content-Type", "audio/mpeg"},
                 {"Authorization", basic_auth}
               ])

      assert %{status: 200} = make_req(client, "GET", mount, [])

      payload = "I love you, Romeo"

      source_client
      |> :gen_tcp.send(payload)

      assert {:ok, payload} == :gen_tcp.recv(client, String.length(payload), @receive_timeout)
    end

    # TODO In original IceCast the connection is simpy closed (no http code returned)
    test "If nothing is streamed on mountpoint client gets 404 with html", %{client: client} do
      assert %{status: 404, headers: headers} =
               make_req(client, "GET", "/nonexistent_mountpoint", [])

      assert headers |> Enum.member?({"content-type", "text/html"})
      assert headers |> Enum.member?({"connection", "close"})
    end

    test "User with wrong password cannot stream", %{
      source_client: {source_client, input_creds},
      mount: mount
    } do
      {user, _} = input_creds
      basic_auth = encode_user_pass({user, "SomeWrongPassword"})

      %{status: 401} =
        make_req(source_client, "SOURCE", mount, [
          {"Content-Type", "audio/mpeg"},
          {"Authorization", basic_auth}
        ])
    end

    # TODO In original IceCast the connection is simpy closed (no http code returned
    test "Timeout in source client and client is triggered if body is not being sent", %{
      source_client: {source_client, input_creds},
      client: client,
      mount: mount
    } do
      basic_auth = encode_user_pass(input_creds)

      %{status: 200} =
        make_req(source_client, "SOURCE", mount, [
          {"Content-Type", "audio/mpeg"},
          {"Authorization", basic_auth}
        ])

      %{status: 200} = make_req(client, "GET", mount, [])

      payload = "I love you, Romeo"
      payload2 = "I really do"

      source_client
      |> :gen_tcp.send(payload)

      assert {:ok, ^payload} = :gen_tcp.recv(client, String.length(payload), @receive_timeout)

      # Firstly we send the payload before the timeout goes off
      :timer.sleep(trunc(@body_timeout * 0.5))

      source_client
      |> :gen_tcp.send(payload2)

      {:ok, ^payload2} = :gen_tcp.recv(client, String.length(payload2), @receive_timeout)

      # Then we would like to send the payload too late
      wait_for_timeout(@body_timeout)

      %{status: 502, headers: source_headers} = HTTP.get_http_response(source_client)

      assert Enum.member?(source_headers, {"connection", "close"})

      # Client is being disconnected
      %{status: 502, headers: client_headers} = HTTP.get_http_response(client)

      assert Enum.member?(client_headers, {"connection", "close"})
    end

    test "Timeout is not triggered if body is sent before the body_timeout",
         %{source_client: {source_client, input_creds}, client: client, mount: mount} do
      basic_auth = encode_user_pass(input_creds)

      %{status: 200} =
        make_req(source_client, "SOURCE", mount, [
          {"Content-Type", "audio/mpeg"},
          {"Authorization", basic_auth}
        ])

      %{status: 200} = make_req(client, "GET", mount, [])

      payload = "I love you, Romeo"

      for _ <- 1..3 do
        source_client
        |> :gen_tcp.send(payload)

        assert {:ok, ^payload} = :gen_tcp.recv(client, String.length(payload), @receive_timeout)

        :timer.sleep(trunc(@body_timeout * 0.6))
      end
    end

    test "mp3 file can be streamed", %{
      source_client: {source_client, input_creds},
      client: client,
      mount: mount
    } do
      basic_auth = encode_user_pass(input_creds)

      %{status: 200} =
        make_req(source_client, "SOURCE", mount, [
          {"Content-Type", "audio/mpeg"},
          {"Authorization", basic_auth}
        ])

      %{status: 200, headers: headers} = make_req(client, "GET", mount, [])

      assert headers |> Enum.member?({"content-type", "audio/mpeg"})

      {:ok, payload} = File.read(@mp3_path)

      source_client
      |> :gen_tcp.send(payload)

      {:ok, ^payload} = :gen_tcp.recv(client, byte_size(payload), @receive_timeout)
    end

    test "ogg file can be streamed", %{
      source_client: {source_client, input_creds},
      client: client,
      mount: mount
    } do
      basic_auth = encode_user_pass(input_creds)

      %{status: 200} =
        make_req(source_client, "SOURCE", mount, [
          {"Content-Type", "audio/ogg"},
          {"Authorization", basic_auth}
        ])

      %{status: 200, headers: headers} = make_req(client, "GET", mount, [])

      assert headers |> Enum.member?({"content-type", "audio/ogg"})

      {:ok, payload} = File.read(@ogg_path)

      source_client
      |> :gen_tcp.send(payload)

      {:ok, ^payload} = :gen_tcp.recv(client, byte_size(payload), @receive_timeout)
    end
  end

  describe "No connections made" do
    setup do
      {user, pass} = {unique("Juliet"), "I<3Romeo"}
      UsersDB.register(user, pass)
      {user2, pass2} = {"seconduser", "seconduserpass"}
      UsersDB.register(user2, pass2)

      on_exit(fn ->
        UsersDB.unregister(user, pass)
        UsersDB.unregister(user2, pass2)
      end)

      %{input_creds: [{user, pass}, {user2, pass2}], mount: unique("/somemount")}
    end

    test "Multiple source clients on the same mount are not allowed", %{
      input_creds: [input_creds, input_creds2],
      mount: mount
    } do
      basic_auth = encode_user_pass(input_creds)
      basic_auth2 = encode_user_pass(input_creds2)

      input_port = Input.Listener.get_port!()

      source_client = HTTP.connect(input_port)
      source_client2 = HTTP.connect(input_port)

      %{status: 200} =
        make_req(source_client, "SOURCE", mount, [
          {"Content-Type", "audio/mpeg"},
          {"Authorization", basic_auth}
        ])

      %{status: 401} =
        make_req(source_client2, "SOURCE", mount, [
          {"Content-Type", "audio/mpeg"},
          {"Authorization", basic_auth2}
        ])
    end

    test "Multiple clients on the same mount are allowed", %{
      input_creds: [input_creds | _],
      mount: mount
    } do
      basic_auth = encode_user_pass(input_creds)

      input_port = Input.Listener.get_port!()
      output_port = Output.Listener.get_port!()

      source_client = HTTP.connect(input_port)

      %{status: 200} =
        make_req(source_client, "SOURCE", mount, [
          {"Content-Type", "audio/mpeg"},
          {"Authorization", basic_auth}
        ])

      clients =
        1..3
        |> Enum.map(fn _ -> HTTP.connect(output_port) end)

      assert clients
             |> Enum.map(fn client -> make_req(client, "GET", mount, []) end)
             |> Enum.all?(fn %{status: status} -> status == 200 end)

      payload = "I love you, Romeo"

      source_client
      |> :gen_tcp.send(payload)

      assert clients
             |> Enum.map(fn client ->
               :gen_tcp.recv(client, String.length(payload), @receive_timeout)
             end)
             |> Enum.all?(fn resp -> resp == {:ok, payload} end)
    end
  end

  ###########
  # Helpers #
  ###########

  defp make_req(conn, method, mount, headers) do
    req_string = HTTP.request(method, mount, headers)
    :gen_tcp.send(conn, req_string)

    HTTP.get_http_response(conn)
  end

  defp encode_user_pass({user, pass}) do
    plain = "#{user}:#{pass}"
    "Basic #{Base.encode64(plain)}"
  end

  defp unique(name), do: "#{name}_#{inspect(:erlang.monotonic_time())}"

  defp wait_for_timeout(timeout, eps \\ 50), do: :timer.sleep(timeout + eps)

  defp start_streaming(socket, payload, interval),
    do: spawn_link(fn -> stream_loop(socket, payload, interval) end)

  defp stop_streaming(ref), do: send(ref, :stop_stream)

  defp stream_loop(socket, payload, interval) do
    receive do
      :stop_stream ->
        :ok
    after
      interval ->
        :gen_tcp.send(socket, payload)
        stream_loop(socket, payload, interval)
    end
  end
end

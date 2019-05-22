defmodule Membrane.Server.Icecast.ServerTest do
  use ExUnit.Case, async: true
  alias Membrane.Protocol.Icecast.Input.Machine, as: InputMachine
  alias Membrane.Protocol.Icecast.Output.Machine, as: OutputMachine

  alias Membrane.Server.Icecast.Input
  alias Membrane.Server.Icecast.Output

  alias Mint.HTTP1

  @receive_timeout 500
  @output_machine_proc :output_machine_proc
  @body_timeout 200
  
  defmodule UsersDB do

    def start_link, do: Agent.start(&MapSet.new/0, name: __MODULE__)

    def register(user, pass), do: Agent.update(__MODULE__, fn users -> MapSet.put(users, {user, pass}) end)

    def unregister(user, pass), do: Agent.update(__MODULE__, fn users -> MapSet.delete(users, {user, pass}) end)

    def registered?(user, pass), do: Agent.get(__MODULE__, fn users -> MapSet.member?(users, {user, pass}) end)
  end

  defmodule InputTestController do
    use Membrane.Protocol.Icecast.Input.Controller

    def handle_init(state) do
      {:ok, state}
    end

    def handle_incoming(_remote_address, controller_state) do
      {:ok, {:allow, controller_state}}
    end

    def handle_source(_address, _method, _format, _mount, user, pass, _headers, state) do
      case UsersDB.registered?(user, pass) do
        true ->
          {:ok, {:allow, state}}
        false ->
          {:ok, {:deny, :unauthorized}}
      end
    end

    def handle_payload(_address, payload, state) do
      send(@output_machine_proc, {:payload, payload})

      {:ok, {:continue, state}}
    end

    def handle_invalid(_address, _reason, state) do
      :ok
    end

    def handle_timeout(_address, state) do
      :ok
    end

    def handle_closed(_address, state) do
      :ok
    end

  end

  defmodule OutputTestController do

    def handle_init(arg) do
      :erlang.register(@output_machine_proc, self())
      {:ok, arg}
    end

    def handle_incoming(_address, state) do
      {:ok, {:allow, state}}
    end

    def handle_listener(_address, _mount, _headers, state) do
      {:ok, {:allow, state}}
    end

    def handle_closed(_address, state) do
      :ok
    end

    def handle_timeout(_address, state) do
      {:ok, state}
    end

    def handle_invalid(_address, _reason, state) do
      {:ok, state}
    end

  end
  

  setup_all do
    
    UsersDB.start_link()

    Application.put_env(:membrane_server_icecast, :input_machine, InputMachine)
    Application.put_env(:membrane_server_icecast, :output_machine, OutputMachine)

    {:ok, _} = Output.Listener.start_listener(0, OutputTestController)
    {:ok, _} = Input.Listener.start_listener(0, InputTestController, nil, body_timeout: @body_timeout)

    on_exit fn ->
      # TODO
      :ok
    end
  end

  setup do
    {user, pass} = {unique("Juliet"), "I<3Romeo"}
    UsersDB.register(user, pass)

    on_exit fn ->
      UsersDB.unregister(user, pass)
    end

    %{input_creds: {user, pass}}
  end



  test "Payload can be streamed successfully", %{input_creds: input_creds} do
    basic_auth = encode_user_pass(input_creds)

    input_port = Input.Listener.get_port!
    output_port = Output.Listener.get_port!

    source_client = connect(input_port)

    client = connect(output_port)

    source_client = make_req(source_client, "SOURCE", "/my_mountpoint", [{"Content-Type", "audio/mpeg"}, {"Authorization", basic_auth}], 200)

    client = make_req(client, "GET", "/my_mountpoint", [], 200)

    payload = "I love you, Romeo"

    source_client
    |> HTTP1.get_socket
    |> :gen_tcp.send(payload)

    assert {:tcp, _, payload} = wait_for_tcp(client)
  end

  test "If nothing is streamed on mountpoint client hangs waiting for content" do
    input_port = Input.Listener.get_port!
    output_port = Output.Listener.get_port!

    client = connect(output_port)

    client = make_req(client, "GET", "/nonexistent_mountpoint", [], 200)

    assert {:error, :timeout_when_waiting_for_tcp} == wait_for_tcp(client)
  end

  test "User with wrong password cannot stream", %{input_creds: input_creds} do
    {user, _} = input_creds
    basic_auth = encode_user_pass({user, "SomeWrongPassword"})
  
    input_port = Input.Listener.get_port!
    output_port = Output.Listener.get_port!
  
    source_client = connect(input_port)
  
    client = connect(output_port)
  
    source_client = make_req(source_client, "SOURCE", "/my_mountpoint", [{"Content-Type", "audio/mpeg"}, {"Authorization", basic_auth}], 401)
  end

  # TODO In original IceCast the connection is simpy closed (no http code returned
  test "Timeout is triggered if body is not being sent", %{input_creds: input_creds} do
    basic_auth = encode_user_pass(input_creds)

        
    input_port = Input.Listener.get_port!
    output_port = Output.Listener.get_port!

    source_client = connect(input_port)

    client = connect(output_port)

    source_client = make_req(source_client, "SOURCE", "/my_mountpoint", [{"Content-Type", "audio/mpeg"}, {"Authorization", basic_auth}], 200)

    client = make_req(client, "GET", "/my_mountpoint", [], 200)

    payload = "I love you, Romeo"
    payload2 = "I really do"

    source_client
    |> HTTP1.get_socket
    |> :gen_tcp.send(payload)

    tcp_msg = wait_for_tcp(client)

    # Firstly we send the payload before the timeout goes off
    :timer.sleep(trunc(@body_timeout * 0.5))

    source_client
    |> HTTP1.get_socket
    |> :gen_tcp.send(payload2)

    tcp_msg = wait_for_tcp(client)

    # Then we would like to send the payload too late
    wait_for_timeout(@body_timeout)

    tcp_msg = wait_for_tcp(source_client)
    {:ok, _, responses} = HTTP1.stream(source_client, tcp_msg)

    assert_header(responses, {"connection", "close"})
    assert_code(responses, 502)
  end


  test "", %{input_creds: input_creds} do

  end


  ###########
  # Helpers #
  ###########

  defp connect(port) do
    {:ok, conn} = HTTP1.connect(:http, "localhost", port)
    conn |> HTTP1.get_socket() |> :inet.setopts([active: true])
    conn
  end

  defp make_req(conn, method, mount, headers, code) do
    {:ok, conn, req_ref} =
      HTTP1.request(conn, method, mount, headers, "") # TODO !!!! This changes option active to once! We can't rely on changing the option on socket!!! FIXME

    tcp_msg = wait_for_tcp(conn)
    {:ok, _, responses} = HTTP1.stream(conn, tcp_msg)
    assert_code(responses, code)
    conn |> HTTP1.get_socket() |> :inet.setopts([active: true])
    conn
  end

  defp assert_code(responses, code) do
    assert {:status, _, code} = responses |> List.keyfind(:status, 0)
  end

  defp assert_header(responses, {k, v} = header) do
    {:headers, _, headers} = responses |> List.keyfind(:headers, 0)
    assert {k, v} == headers |> List.keyfind(k, 0)
  end

  defp encode_user_pass({user, pass}) do
    plain = "#{user}:#{pass}"
    "Basic #{Base.encode64(plain)}"
  end

  defp wait_for_tcp(%Mint.HTTP1{socket: socket}) do
    wait_for_tcp(socket)
  end
  defp wait_for_tcp(socket) do
    receive do
      {:tcp, ^socket, _} = e -> e
    after
      @receive_timeout -> {:error, :timeout_when_waiting_for_tcp}
    end
  end

  defp unique(name), do: "#{name}_#{inspect(:erlang.monotonic_time())}"

  defp wait_for_timeout(timeout, eps \\ 50), do: :timer.sleep(timeout + eps)


end

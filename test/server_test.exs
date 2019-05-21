defmodule Membrane.Server.Icecast.ServerTest do
  use ExUnit.Case, async: true
  alias Membrane.Protocol.Icecast.Input.Machine, as: InputMachine
  alias Membrane.Protocol.Icecast.Output.Machine, as: OutputMachine

  alias Membrane.Server.Icecast.Input
  alias Membrane.Server.Icecast.Output

  alias Mint.HTTP1

  @receive_timeout 500

  @output_machine_proc :output_machine_proc

  defmodule InputTestController do
    use Membrane.Protocol.Icecast.Input.Controller

    def handle_init(state) do
      {:ok, state}
    end

    def handle_incoming(_remote_address, controller_state) do
      {:ok, {:allow, controller_state}}
    end

    def handle_source(_address, _method, _format, _mount, _user, _pass, _headers, state) do
      {:ok, {:allow, state}}
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
    Application.put_env(:membrane_server_icecast, :input_machine, InputMachine)
    Application.put_env(:membrane_server_icecast, :output_machine, OutputMachine)

    {:ok, _} = Output.Listener.start_listener(0, OutputTestController)
    {:ok, _} = Input.Listener.start_listener(0, InputTestController)

    on_exit fn ->
      # TODO
      :ok
    end
  end

  test "payload can be streamed successfully", %{} do
    basic_auth = encode_user_pass("Juliet", "I<3Romeo")

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

    # In theory body can be split
    {:tcp, tcp_msg, payload_part} = wait_for_tcp(client)
    assert String.contains?(payload, payload_part)
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
      HTTP1.request(conn, method, mount, headers, "")
    tcp_msg = wait_for_tcp(conn)
    {:ok, _, responses} = HTTP1.stream(conn, tcp_msg)
    assert {:status, req_ref, code} == responses |> List.keyfind(:status, 0)
    conn
  end

  defp encode_user_pass(user, pass) do
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

end

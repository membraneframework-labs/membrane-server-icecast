defmodule Membrane.Server.Icecast.ServerTest do
  use ExUnit.Case, async: true
  alias Membrane.Protocol.Icecast.Input.Machine, as: InputMachine
  alias Membrane.Protocol.Icecast.Output.Machine, as: OutputMachine

  alias Membrane.Server.Icecast.Input
  alias Membrane.Server.Icecast.Output

  alias Mint.HTTP1

  defmodule TestController do
    use Membrane.Protocol.Icecast.Input.Controller

    def handle_init(arg) do
      {:ok, arg}
    end

    def handle_incoming(_remote_address, controller_state) do
      {:ok, {:allow, controller_state}}
    end

    def handle_source(_address, _method, _format, _mount, _user, _pass, _headers, state) do
      {:ok, {:allow, state}}
    end

    def handle_payload(_address, _payload, state) do
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
  

  setup_all do
    Application.put_env(:membrane_server_icecast, :input_machine, InputMachine)
    Application.put_env(:membrane_server_icecast, :output_machine, OutputMachine)

    {:ok, _} = Input.Listener.start_listener(0, InputTestController)
    {:ok, _} = Output.Listener.start_listener(0, OutputTestController)

    on_exit fn ->
      # TODO
      :ok
    end
  end

  test "some test", %{input_port: input_port, output_port: output_port} do
    input_port = Input.Listener.get_port!
    output_port = Output.Listener.get_port!
    {:ok, conn} = HTTP1.connect(:http, "localhost", input_port)
    conn |> HTTP1.get_socket() |> :inet.setopts([active: true])
    {:ok, conn, req_ref} =
      HTTP1.request(conn, "SOURCE", "/my_mountpoint", [{"Content-Type", "audio/mpeg"}, {"Authorization", "aaa"}], "")
  end
  

end

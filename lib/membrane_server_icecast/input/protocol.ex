defmodule Membrane.Server.Icecast.Input.Protocol do
  alias Membrane.Server.Icecast.Input.Machine

  @behaviour :ranch_protocol

  @impl true
  def start_link(ref, _, transport, {controller_module, controller_arg, allowed_methods, allowed_formats, server_string, request_timeout, body_timeout}) do
    {:ok, :proc_lib.spawn_link(__MODULE__, :init, [ref, transport, controller_module, controller_arg, allowed_methods, allowed_formats, server_string, request_timeout, body_timeout])}
  end

  @doc false
  def init(ref, transport, controller_module, controller_arg, allowed_methods, allowed_formats, server_string, request_timeout, body_timeout) do
    {:ok, socket} = :ranch.handshake(ref)
    Machine.init({socket, transport, controller_module, controller_arg, allowed_methods, allowed_formats, server_string, request_timeout, body_timeout})
  end
end

defmodule Membrane.Server.Icecast.Input.Protocol do
  @behaviour :ranch_protocol

  @impl true
  def start_link(
        ref,
        _,
        transport,
        {controller_module, controller_arg, allowed_methods, allowed_formats, server_string,
         request_timeout, body_timeout}
      ) do
    {:ok,
     :proc_lib.spawn_link(__MODULE__, :init, [
       ref,
       transport,
       controller_module,
       controller_arg,
       allowed_methods,
       allowed_formats,
       server_string,
       request_timeout,
       body_timeout
     ])}
  end

  @doc false
  def init(
        ref,
        transport,
        controller_module,
        controller_arg,
        allowed_methods,
        allowed_formats,
        server_string,
        request_timeout,
        body_timeout
      ) do
    {:ok, socket} = :ranch.handshake(ref)
    machine_module = Application.get_env(:membrane_server_icecast, :input_machine)

    machine_module.init(
      {socket, transport, controller_module, controller_arg, allowed_methods, allowed_formats,
       server_string, request_timeout, body_timeout}
    )
  end
end

defmodule Membrane.Server.Icecast.Output.Listener do
  @default_ranch_ref :membrane_server_icecast_output

  @doc """
  Starts the set of processes that is going to await for incoming connections.

  ## Arguments

  It expects the following arguments:

  * `port` - a valid port number,
  * `controller_module` - a module that is implementing the
    `Membrane.Server.Icecast.Output.Controller` behaviour. It is the module
    implementing application-specific logic related to the connection
    handling,
  * `controller_arg` - an argument that will be passed to the `handle_init`
    callback of the controller module,
  * `options` - a keyword list with additional options.

  Options might be one or many of the following:

  * `ranch_ref` - any erlang term that is going to used as an internal
    reference of the listener by the underlying `:ranch` library. If you
    are spawning multiple pools you need to assign distinct reference to
    each of them. Defaults to `:membrane_server_icecast_output`,
  * `max_connections` - maximum allowed connections, defaults to 1024,
  * `num_acceptors` - acceptor processes, defaults to 10,
  * `server_string` - a value of the `Server` HTTP header sent in response
    to each request, defaults to "Membrane.Server.Icecast.Output/VERSION",
  * `request_timeout` - how long in milliseconds the server will wait for
    the client to send request and associated headers,
  * `body_timeout` - how long in milliseconds the server will wait for
    the client since last payload was received before the client is
    dropped.

  ## Return values

  On success it returns `{:ok, pid}`.

  On error it returns `{:error, reason}`.

  ## Notes

  Real connection count might be larger than `max_connections`.

  By increasing `max_connections` and `num_acceptors` you might run into
  system limits.

  If you have a lot of incoming connections in the short period of time
  you might consider increasing `num_acceptors`.

  For more information see https://ninenines.eu/docs/en/ranch/1.7/guide/listeners/
  """
  @spec start_listener(:inet.port(), module, any,
          ranch_ref: :ranch.ref(),
          max_connections: pos_integer,
          num_acceptors: pos_integer,
          server_string: String.t(),
          request_timeout: timeout,
          body_timeout: timeout
        ) :: {:ok, pid} | {:error, any}
  def start_listener(port, controller_module, controller_arg \\ nil, options \\ []) do
    ranch_ref = Keyword.get(options, :ranch_ref, @default_ranch_ref)
    if not is_atom(ranch_ref), do: raise(":ranch_ref listener option must be an atom")

    max_connections = Keyword.get(options, :max_connections, 1024)

    if not is_number(max_connections),
      do: raise(":max_connections listener option must be a number")

    if max_connections <= 0,
      do: raise(":max_connections listener option must be greater than zero")

    num_acceptors = Keyword.get(options, :num_acceptors, 10)
    if not is_number(num_acceptors), do: raise(":num_acceptors listener option must be a number")
    if num_acceptors <= 0, do: raise(":num_acceptors listener option must be greater than zero")

    server_string =
      Keyword.get(
        options,
        :server_string,
        "Membrane.Server.Icecast.Output/#{Membrane.Server.Icecast.version!()}"
      )

    if not is_binary(server_string), do: raise(":server_string listener option must be a binary")

    request_timeout = Keyword.get(options, :request_timeout, 5000)

    if not is_number(request_timeout),
      do: raise(":request_timeout listener option must be a list")

    if request_timeout <= 0,
      do: raise(":request_timeout listener option must be greater than zero")

    body_timeout = Keyword.get(options, :body_timeout, 5000)
    if not is_number(body_timeout), do: raise(":body_timeout listener option must be a list")
    if body_timeout <= 0, do: raise(":body_timeout listener option must be greater than zero")

    :ranch.start_listener(
      ranch_ref,
      :ranch_tcp,
      %{
        socket_opts: [port: port],
        max_connections: max_connections,
        num_acceptors: num_acceptors
      },
      Membrane.Server.Icecast.Output.Protocol,
      {
        controller_module,
        controller_arg,
        server_string,
        request_timeout,
        body_timeout
      }
    )
  end

  @doc """
  Returns the associated port number of a listener.

  As an argument it accepts reference used by the underlying `ranch` library.

  If you have passed custom `ranch_ref` option to the `start_listener/4` you
  need to pass it also here.
  """
  @spec get_port!(:ranch.ref()) :: {:ok, :inet.port()}
  def get_port!(ranch_ref \\ @default_ranch_ref) do
    :ranch.get_port(ranch_ref)
  end
end

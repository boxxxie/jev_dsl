defmodule JevDSL.Providers.GeminiDecisions do
  @moduledoc """
  `SystemOneSDK.Provider` implementation for the Gemini Decisions API (`gemini-decision-1`).

  Supports both:
  - **Unified LiteLLM `/v1/decisions`** (`decisions_mode: :unified`, `Authorization: Bearer`)
  - **Native Gemini `/v1beta/decisions` or `/gemini/v1beta/decisions` passthrough**
    (`decisions_mode: :native`, `x-goog-api-key`)
  """

  @behaviour SystemOneSDK.Provider

  alias JevDSL.Error
  alias JevDSL.Providers.GeminiDecisions.Protocol
  alias SystemOneSDK.{ListModelsResponse, Prepared, RetryPolicy}

  @default_unified_base_url "http://100.88.180.12:4000"
  @default_native_base_url "https://generativelanguage.googleapis.com"
  @default_model "gemini-decision-1"

  defmodule Client do
    @moduledoc false
    defstruct [
      :api_key,
      :base_url,
      :default_model,
      :decisions_mode,
      :auth_mode,
      :decisions_path,
      :timeout_ms,
      :retry,
      :headers,
      :transport,
      :transport_opts,
      :context,
      :pristine_client
    ]
  end

  @impl true
  def id, do: :gemini_decisions

  @impl true
  def new_client(opts) when is_list(opts) do
    client = build_client(opts)
    context = build_context(client)
    %{client | context: context, pristine_client: Pristine.Client.from_context(context)}
  end

  defp build_client(opts) do
    decisions_mode = Keyword.get(opts, :decisions_mode) || :unified
    {auth_mode, base_url} = mode_defaults(opts, decisions_mode)

    %Client{
      api_key: JevDSL.Runner.resolve_secret(Keyword.get(opts, :api_key)),
      base_url: base_url,
      default_model: Keyword.get(opts, :model) || @default_model,
      decisions_mode: decisions_mode,
      auth_mode: auth_mode,
      decisions_path: resolve_decisions_path(opts, decisions_mode, base_url),
      timeout_ms: Keyword.get(opts, :timeout_ms) || Keyword.get(opts, :timeout) || 30_000,
      retry: RetryPolicy.merge!(nil, Keyword.get(opts, :retry)),
      headers: normalize_headers(Keyword.get(opts, :headers)),
      transport: Keyword.get(opts, :transport) || Pristine.Adapters.Transport.Finch,
      transport_opts: Keyword.get(opts, :transport_opts) || []
    }
  end

  defp mode_defaults(opts, :native) do
    {Keyword.get(opts, :auth_mode) || :x_goog_api_key,
     Keyword.get(opts, :base_url) || @default_native_base_url}
  end

  defp mode_defaults(opts, _unified) do
    {Keyword.get(opts, :auth_mode) || :bearer,
     Keyword.get(opts, :base_url) || @default_unified_base_url}
  end

  defp normalize_headers(nil), do: %{}

  defp normalize_headers(headers) do
    Map.new(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  @impl true
  def default_model(%Client{default_model: model}), do: model

  @impl true
  def system_one(%Client{} = client, state, questions, opts) when is_list(opts) do
    case SystemOneSDK.prepare(questions) do
      {:ok, %Prepared{} = prepared} -> system_one_prepared(client, state, prepared, opts)
      {:error, _} = err -> err
    end
  end

  @impl true
  def system_one_prepared(%Client{} = client, state, %Prepared{} = prepared, opts)
      when is_list(opts) do
    model = Keyword.get(opts, :model) || client.default_model
    decisions_mode = Keyword.get(opts, :decisions_mode) || client.decisions_mode || :unified
    auth_mode = resolve_call_auth_mode(client, opts, decisions_mode)
    api_key = resolve_call_api_key(client, opts)
    decisions_path = resolve_call_decisions_path(client, opts, decisions_mode)

    extra_body =
      (Keyword.get(opts, :extra_body) || %{})
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    body =
      extra_body
      |> Map.merge(Protocol.encode_request(state, prepared, model, decisions_mode))

    call_headers =
      (Keyword.get(opts, :extra_headers) || %{})
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    extra_headers =
      api_key
      |> Protocol.auth_headers(auth_mode)
      |> Map.merge(call_headers)

    request = %{
      id: "gemini_decisions",
      method: :post,
      path: decisions_path,
      path_params: %{},
      query: %{},
      headers: extra_headers,
      body: body,
      form_data: nil,
      auth: [],
      security: nil,
      request_schema: nil,
      response_schema: nil,
      use_default_auth: false,
      resource: "decisions"
    }

    retry = RetryPolicy.merge!(client.retry, Keyword.get(opts, :retry))

    execute_opts =
      [
        retry_opts: RetryPolicy.to_pristine_opts(retry)
      ]
      |> maybe_put(:timeout, Keyword.get(opts, :timeout_ms) || Keyword.get(opts, :timeout))
      |> maybe_put(:cancellation, Keyword.get(opts, :cancellation))

    with {:ok, resp_data} <- Pristine.execute_request(request, client.context, execute_opts),
         {:ok, decoded} <- ensure_decoded_map(resp_data),
         {:ok, response} <- Protocol.decode_response(decoded, prepared, model) do
      {:ok, response}
    else
      {:error, %Error{} = err} ->
        {:error, err}

      {:error, reason} ->
        {:error,
         %Error{
           type: :provider_error,
           message: "Gemini Decisions request failed: #{inspect(reason)}",
           details: %{reason: reason}
         }}
    end
  end

  @impl true
  def list_models(%Client{}, _opts), do: {:ok, %ListModelsResponse{models: []}}

  @impl true
  def capabilities(%Client{pristine_client: pristine, decisions_mode: mode, auth_mode: auth_mode}) do
    report = Pristine.RuntimeCapabilities.transport(pristine)

    %{
      provider: :gemini_decisions,
      decisions_mode: mode,
      auth_mode: auth_mode,
      transport: inspect(report.adapter),
      runtime: report.capabilities
    }
  end

  @doc false
  def resolve_decisions_path(opts, decisions_mode, base_url) do
    case Keyword.get(opts, :decisions_path) do
      path when is_binary(path) and path != "" ->
        path

      _ when decisions_mode == :unified ->
        "/v1/decisions"

      _ when decisions_mode == :native ->
        if String.contains?(to_string(base_url), "generativelanguage.googleapis.com") do
          "/v1beta/decisions"
        else
          "/gemini/v1beta/decisions"
        end
    end
  end

  defp resolve_call_auth_mode(client, opts, decisions_mode) do
    cond do
      auth_mode = Keyword.get(opts, :auth_mode) ->
        auth_mode

      Keyword.get(opts, :decisions_mode) && decisions_mode != client.decisions_mode ->
        if decisions_mode == :native, do: :x_goog_api_key, else: :bearer

      true ->
        client.auth_mode || if(decisions_mode == :native, do: :x_goog_api_key, else: :bearer)
    end
  end

  defp resolve_call_api_key(client, opts) do
    if Keyword.has_key?(opts, :api_key) or Keyword.has_key?(opts, :gemini_api_key) do
      non_blank_secret(Keyword.get(opts, :api_key)) ||
        non_blank_secret(Keyword.get(opts, :gemini_api_key))
    else
      JevDSL.Runner.resolve_secret(client.api_key)
    end
  end

  defp non_blank_secret(raw) do
    case JevDSL.Runner.resolve_secret(raw) do
      val when is_binary(val) and val != "" -> val
      _ -> nil
    end
  end

  defp resolve_call_decisions_path(client, opts, decisions_mode) do
    case Keyword.get(opts, :decisions_path) do
      path when is_binary(path) and path != "" ->
        path

      _ when decisions_mode != client.decisions_mode ->
        resolve_decisions_path(opts, decisions_mode, client.base_url)

      _ ->
        client.decisions_path
    end
  end

  defp build_context(client) do
    Pristine.foundation_context(
      auth: [],
      base_url: client.base_url,
      default_timeout: client.timeout_ms,
      error_module: __MODULE__,
      headers: Map.merge(%{"Accept" => "application/json"}, client.headers),
      package_version: "0.1.0",
      retry: [
        adapter: Pristine.Adapters.Retry.Foundation,
        opts: RetryPolicy.to_pristine_opts(client.retry)
      ],
      serializer: Pristine.Adapters.Serializer.JSON,
      transport: client.transport,
      transport_opts: client.transport_opts
    )
  end

  @doc false
  def from_response(response, body, retry_after_ms, opts) do
    Pristine.Error.from_response(response,
      body: body,
      retry_after_ms: retry_after_ms,
      profile: Keyword.get(opts, :profile)
    )
  end

  @doc false
  def validation_error(reason, body, _opts) do
    %Error{
      type: :invalid_response,
      message: "Invalid response from Gemini Decisions: #{inspect(reason)}",
      details: %{reason: reason, body: body}
    }
  end

  @doc false
  def connection_error(reason, opts) do
    Pristine.Error.connection_error(reason, opts)
  end

  defp ensure_decoded_map(data) when is_map(data), do: {:ok, data}

  defp ensure_decoded_map(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      _ ->
        {:error,
         %Error{type: :invalid_response, message: "Invalid JSON response", details: %{body: data}}}
    end
  end

  defp ensure_decoded_map(data) do
    {:error,
     %Error{
       type: :invalid_response,
       message: "Unexpected response payload",
       details: %{body: data}
     }}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)
end

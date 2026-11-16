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

  defmodule ErrorHandler do
    @moduledoc false

    def from_response(response, body, retry_after_ms, opts) do
      Pristine.Error.from_response(response,
        body: body,
        retry_after_ms: retry_after_ms,
        profile: Keyword.get(opts, :profile)
      )
    end

    def validation_error(reason, body, _opts) do
      %Error{
        type: :invalid_response,
        message: "Invalid response from Gemini Decisions: #{inspect(reason)}",
        details: %{reason: reason, body: body}
      }
    end

    def connection_error(reason, opts) do
      Pristine.Error.connection_error(reason, opts)
    end
  end

  @impl true
  def id, do: :gemini_decisions

  @impl true
  def new_client(opts) when is_list(opts) do
    %Client{} = client = build_client(opts)

    if not non_blank_binary?(client.base_url) do
      raise ArgumentError, missing_base_url_message(client.decisions_mode)
    end

    context = build_context(client)
    %Client{client | context: context, pristine_client: Pristine.Client.from_context(context)}
  end

  defp build_client(opts) do
    decisions_mode = Keyword.get(opts, :decisions_mode) || :unified
    auth_mode = Keyword.get(opts, :auth_mode) || default_auth_mode(decisions_mode)
    base_url = resolve_base_url(opts, decisions_mode)

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

  defp default_auth_mode(:native), do: :x_goog_api_key
  defp default_auth_mode(_unified), do: :bearer

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
    %Client{} = effective = apply_call_opts(client, opts)

    if non_blank_binary?(effective.base_url) do
      execute_prepared(effective, state, prepared, opts)
    else
      {:error,
       %Error{
         type: :invalid_request,
         message: missing_base_url_message(effective.decisions_mode),
         details: %{decisions_mode: effective.decisions_mode}
       }}
    end
  end

  defp execute_prepared(%Client{} = effective, state, %Prepared{} = prepared, opts) do
    extra_body =
      (Keyword.get(opts, :extra_body) || %{})
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    body =
      extra_body
      |> Map.merge(
        Protocol.encode_request(
          state,
          prepared,
          effective.default_model,
          effective.decisions_mode
        )
      )

    call_headers = normalize_headers(Keyword.get(opts, :extra_headers))

    extra_headers =
      effective.api_key
      |> Protocol.auth_headers(effective.auth_mode)
      |> merge_headers_case_insensitive(call_headers)

    request = %{
      id: "gemini_decisions",
      method: :post,
      path: effective.decisions_path,
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

    retry = RetryPolicy.merge!(effective.retry, Keyword.get(opts, :retry))

    execute_opts =
      [
        retry_opts: RetryPolicy.to_pristine_opts(retry)
      ]
      |> maybe_put(:timeout, Keyword.get(opts, :timeout_ms) || Keyword.get(opts, :timeout))
      |> maybe_put(:cancellation, Keyword.get(opts, :cancellation))

    with {:ok, resp_data} <- Pristine.execute_request(request, effective.context, execute_opts),
         {:ok, decoded} <- ensure_decoded_map(resp_data),
         {:ok, response} <- Protocol.decode_response(decoded, prepared, effective.default_model) do
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
  def resolve_base_url(opts, decisions_mode) when is_list(opts) do
    explicit = JevDSL.Runner.resolve_secret(Keyword.get(opts, :base_url))

    if non_blank_binary?(explicit) do
      explicit
    else
      resolve_env_base_url(decisions_mode, Keyword.get(opts, :otp_app))
    end
  end

  defp resolve_env_base_url(:native, otp_app) do
    first_non_blank([
      fn -> otp_app && Application.get_env(otp_app, :gemini_decisions_base_url) end,
      fn -> otp_app && Application.get_env(otp_app, :base_url) end,
      fn -> Application.get_env(:jev_dsl, :gemini_decisions_base_url) end,
      fn -> Application.get_env(:jev_dsl, :base_url) end,
      fn -> System.get_env("GEMINI_DECISIONS_BASE_URL") end,
      fn -> @default_native_base_url end
    ])
  end

  defp resolve_env_base_url(_unified, otp_app) do
    first_non_blank([
      fn -> otp_app && Application.get_env(otp_app, :litellm_base_url) end,
      fn -> otp_app && Application.get_env(otp_app, :base_url) end,
      fn -> Application.get_env(:jev_dsl, :litellm_base_url) end,
      fn -> Application.get_env(:jev_dsl, :base_url) end,
      fn -> System.get_env("LITELLM_BASE_URL") end
    ])
  end

  defp first_non_blank(candidates) do
    Enum.find_value(candidates, fn fun ->
      case JevDSL.Runner.resolve_secret(fun.()) do
        val when is_binary(val) and val != "" -> val
        _ -> nil
      end
    end)
  end

  @doc false
  def apply_call_opts(%Client{} = client, opts) when is_list(opts) do
    decisions_mode = Keyword.get(opts, :decisions_mode) || client.decisions_mode || :unified
    base_url = resolve_override_base_url(client, opts, decisions_mode)
    auth_mode = resolve_call_auth_mode(client, opts, decisions_mode)

    api_key =
      JevDSL.Runner.resolve_override_secret(opts, [:api_key, :gemini_api_key], client.api_key)

    model = Keyword.get(opts, :model) || client.default_model || @default_model
    decisions_path = resolve_call_decisions_path(client, opts, decisions_mode, base_url)

    updated = %Client{
      client
      | decisions_mode: decisions_mode,
        base_url: base_url,
        auth_mode: auth_mode,
        api_key: api_key,
        default_model: model,
        decisions_path: decisions_path
    }

    if base_url != client.base_url and non_blank_binary?(base_url) do
      context = build_context(updated)
      %Client{updated | context: context, pristine_client: Pristine.Client.from_context(context)}
    else
      updated
    end
  end

  @doc false
  def cache_identity_fields(%SystemOneSDK.Client{} = client, %Client{} = pclient, opts) do
    effective = apply_call_opts(pclient, opts)
    model = Keyword.get(opts, :model) || client.default_model || effective.default_model
    {effective.decisions_mode, model}
  end

  def cache_identity_fields(%SystemOneSDK.Client{} = client, nil, opts) do
    decisions_mode = Keyword.get(opts, :decisions_mode) || :unified
    model = Keyword.get(opts, :model) || client.default_model || @default_model
    {decisions_mode, model}
  end

  defp resolve_override_base_url(%Client{} = client, opts, decisions_mode) do
    explicit = JevDSL.Runner.resolve_secret(Keyword.get(opts, :base_url))

    cond do
      non_blank_binary?(explicit) ->
        explicit

      decisions_mode == :unified and client.decisions_mode == :native and
          client.base_url == @default_native_base_url ->
        resolve_base_url(opts, :unified)

      true ->
        client.base_url
    end
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

  defp resolve_call_auth_mode(%Client{} = client, opts, decisions_mode) do
    cond do
      auth_mode = Keyword.get(opts, :auth_mode) ->
        auth_mode

      Keyword.get(opts, :decisions_mode) && decisions_mode != client.decisions_mode ->
        default_auth_mode(decisions_mode)

      true ->
        client.auth_mode || default_auth_mode(decisions_mode)
    end
  end

  defp resolve_call_decisions_path(%Client{} = client, opts, decisions_mode, base_url) do
    case Keyword.get(opts, :decisions_path) do
      path when is_binary(path) and path != "" ->
        path

      _ when decisions_mode != client.decisions_mode or base_url != client.base_url ->
        resolve_decisions_path(opts, decisions_mode, base_url)

      _ ->
        client.decisions_path
    end
  end

  defp merge_headers_case_insensitive(base_headers, override_headers) do
    override_downcased =
      override_headers
      |> Map.keys()
      |> MapSet.new(&String.downcase/1)

    base_headers
    |> Enum.reject(fn {k, _v} -> MapSet.member?(override_downcased, String.downcase(k)) end)
    |> Map.new()
    |> Map.merge(override_headers)
  end

  defp build_context(%Client{} = client) do
    Pristine.foundation_context(
      auth: [],
      base_url: client.base_url,
      default_timeout: client.timeout_ms,
      error_module: ErrorHandler,
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

  defp non_blank_binary?(val) when is_binary(val), do: String.trim(val) != ""
  defp non_blank_binary?(_), do: false

  defp missing_base_url_message(decisions_mode) do
    "Missing :base_url for :gemini_decisions in #{inspect(decisions_mode)} mode. " <>
      "Pass :base_url, configure :litellm_base_url/:base_url, or set LITELLM_BASE_URL."
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

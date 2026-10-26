defmodule JevDSL.Error do
  @moduledoc """
  Structured exception raised by `evaluate!/3` and `JevDSL.Runner.evaluate!/4` when a
  `JevDSL` contract evaluation fails.

  ## Fields

    * `:type` - Error classification atom (`:no_api_key`, `:cache_miss`, `:unknown_contract`, `:invalid_options`, or `:evaluation_failed`).
    * `:message` - Human-readable error message.
    * `:contract` - The contract key (atom or string) being evaluated, if applicable.
    * `:details` - Additional error context or underlying failure term.
  """

  @type error_type ::
          :no_api_key
          | :cache_miss
          | :unknown_contract
          | :invalid_options
          | :evaluation_failed

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t(),
          contract: atom() | String.t() | nil,
          details: term()
        }

  defexception type: :evaluation_failed,
               message: "JevDSL evaluation failed",
               contract: nil,
               details: nil

  @doc """
  Builds a `:no_api_key` exception when neither a `TYPESAFE_API_KEY` nor an offline cache/mock is available.
  """
  @spec no_api_key(atom() | String.t() | nil) :: t()
  def no_api_key(contract \\ nil) do
    %__MODULE__{
      type: :no_api_key,
      contract: contract,
      message:
        "No TYPESAFE_API_KEY configured for JevDSL evaluation" <>
          format_contract_suffix(contract)
    }
  end

  @doc """
  Builds a `:cache_miss` exception when `cache_only: true` is set and the evaluation is not in L1/L2 cache.
  """
  @spec cache_miss(atom() | String.t() | nil) :: t()
  def cache_miss(contract \\ nil) do
    %__MODULE__{
      type: :cache_miss,
      contract: contract,
      message:
        "Cache miss while evaluating in cache_only mode" <>
          format_contract_suffix(contract)
    }
  end

  @doc """
  Builds an `:unknown_contract` exception when a contract key is not defined on the module.
  """
  @spec unknown_contract(module(), atom() | String.t()) :: t()
  def unknown_contract(module, contract) do
    %__MODULE__{
      type: :unknown_contract,
      contract: contract,
      details: %{module: module},
      message: "Unknown JevDSL contract #{inspect(contract)} in #{inspect(module)}"
    }
  end

  @doc """
  Builds an `:invalid_options` exception when invalid options are supplied.
  """
  @spec invalid_options(String.t(), term()) :: t()
  def invalid_options(message, details \\ nil) when is_binary(message) do
    %__MODULE__{
      type: :invalid_options,
      message: message,
      details: details
    }
  end

  @doc """
  Converts an error reason from `evaluate/3` into a raisable exception (`JevDSL.Error` or `SystemOneSDK.Error`).
  """
  @spec from_reason(term(), atom() | String.t() | nil) :: Exception.t()
  def from_reason(%__MODULE__{} = err, _contract), do: err
  def from_reason(%SystemOneSDK.Error{} = err, _contract), do: err
  def from_reason(:no_api_key, contract), do: no_api_key(contract)
  def from_reason(:cache_miss, contract), do: cache_miss(contract)

  def from_reason({:unknown_contract, contract}, _fallback) do
    %__MODULE__{
      type: :unknown_contract,
      contract: contract,
      message: "Unknown JevDSL contract #{inspect(contract)}"
    }
  end

  def from_reason(other, contract) when is_exception(other) do
    %__MODULE__{
      type: :evaluation_failed,
      contract: contract,
      details: other,
      message: Exception.message(other)
    }
  end

  def from_reason(other, contract) do
    %__MODULE__{
      type: :evaluation_failed,
      contract: contract,
      details: other,
      message: "JevDSL evaluation failed#{format_contract_suffix(contract)}: #{inspect(other)}"
    }
  end

  defp format_contract_suffix(nil), do: ""
  defp format_contract_suffix(contract), do: " (contract: #{inspect(contract)})"
end

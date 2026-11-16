defmodule SystemOneDSL.Question do
  @moduledoc """
  Typed representation of a single compiled question (`:noul`, `:choice`, or `:score`)
  within a `SystemOneDSL.Contract`.
  """

  @enforce_keys [:name, :type, :instructions, :criteria]
  defstruct [:name, :type, :instructions, :criteria]

  @type question_key :: atom() | String.t()
  @type question_type :: :noul | :choice | :score
  @type criteria_key :: atom() | String.t() | boolean()
  @type criteria_type ::
          %{optional(criteria_key()) => term()}
          | [{criteria_key(), term()}]

  @type t :: %__MODULE__{
          name: question_key(),
          type: question_type(),
          instructions: term(),
          criteria: criteria_type()
        }
end

defmodule SystemOneDSL.Contract do
  @moduledoc """
  Typed representation of a compiled `SystemOneSDK` / decision contract,
  wrapping the question definitions and the build-time validated `%SystemOneSDK.Prepared{}` struct.
  """

  @enforce_keys [:name, :questions, :prepared]
  defstruct [:name, :questions, :prepared]

  @type t :: %__MODULE__{
          name: atom(),
          questions: [SystemOneDSL.Question.t()],
          prepared: SystemOneSDK.Prepared.t()
        }
end

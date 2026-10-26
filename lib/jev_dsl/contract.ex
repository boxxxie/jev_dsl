defmodule JevDSL.Question do
  @moduledoc """
  Typed representation of a single compiled question (`:noul`, `:choice`, or `:score`)
  within a `JevDSL.Contract`.
  """

  @enforce_keys [:name, :type, :instructions, :criteria]
  defstruct [:name, :type, :instructions, :criteria, :keys]

  @type question_key :: atom() | String.t()
  @type question_type :: :noul | :choice | :score
  @type keys_mode :: :atoms | :strings | nil
  @type criteria_key :: atom() | String.t() | boolean()
  @type criteria_type ::
          %{optional(criteria_key()) => term()}
          | [{criteria_key(), term()}]

  @type t :: %__MODULE__{
          name: question_key(),
          type: question_type(),
          instructions: term(),
          criteria: criteria_type(),
          keys: keys_mode()
        }
end

defmodule JevDSL.Contract do
  @moduledoc """
  Typed representation of a compiled TypeSafe Jev (`SystemOneSDK`) contract,
  wrapping the question definitions and the build-time validated `%SystemOneSDK.Prepared{}` struct.
  """

  @enforce_keys [:name, :questions, :prepared]
  defstruct [:name, :questions, :prepared]

  @type t :: %__MODULE__{
          name: atom(),
          questions: [JevDSL.Question.t()],
          prepared: SystemOneSDK.Prepared.t()
        }
end

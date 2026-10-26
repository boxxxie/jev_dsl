defmodule JevDSL.Question do
  @moduledoc """
  Typed representation of a single compiled question (`:noul`, `:choice`, or `:score`)
  within a `JevDSL.Contract`.
  """

  @enforce_keys [:name, :type, :instructions, :criteria]
  defstruct [:name, :type, :instructions, :criteria]

  @type question_type :: :noul | :choice | :score
  @type criteria_type :: %{optional(atom()) => String.t()} | [{atom(), String.t()}]

  @type t :: %__MODULE__{
          name: atom(),
          type: question_type(),
          instructions: String.t(),
          criteria: criteria_type()
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

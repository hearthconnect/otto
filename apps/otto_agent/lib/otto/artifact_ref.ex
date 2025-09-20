defmodule Otto.ArtifactRef do
  @moduledoc """
  Reference to a persisted artifact.

  Contains metadata about artifacts saved by the Checkpointer,
  including path, type, size, checksum, and timestamps.
  """

  @type t :: %__MODULE__{
          path: String.t(),
          type: atom(),
          size: non_neg_integer(),
          checksum: String.t() | nil,
          created_at: DateTime.t() | nil,
          session_id: String.t()
        }

  defstruct [
    :path,
    :type,
    :size,
    :checksum,
    :created_at,
    :session_id
  ]

  @doc """
  Creates a new ArtifactRef.
  """
  def new(attrs) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Validates that an ArtifactRef has all required fields.
  """
  def valid?(%__MODULE__{} = ref) do
    not is_nil(ref.path) and
      not is_nil(ref.type) and
      not is_nil(ref.size) and
      not is_nil(ref.session_id)
  end

  def valid?(_), do: false

  @doc """
  Returns the filename component of the artifact path.
  """
  def filename(%__MODULE__{path: path}) do
    Path.basename(path)
  end

  @doc """
  Returns the directory containing the artifact.
  """
  def dirname(%__MODULE__{path: path}) do
    Path.dirname(path)
  end
end
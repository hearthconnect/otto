defmodule Otto.ToolContext do
  @moduledoc """
  Context provided to tools during execution.

  Contains agent configuration, sandboxing information, and budget controls
  to enable secure and controlled tool execution.
  """

  @type t :: %__MODULE__{
          agent_config: map(),
          working_dir: String.t(),
          budget_guard: map(),
          session_id: String.t() | nil,
          metadata: map()
        }

  defstruct [
    :agent_config,
    :working_dir,
    :budget_guard,
    :session_id,
    metadata: %{}
  ]

  @doc """
  Creates a new ToolContext with required fields.
  """
  def new(agent_config, working_dir, budget_guard, opts \\ []) do
    %__MODULE__{
      agent_config: agent_config,
      working_dir: working_dir,
      budget_guard: budget_guard,
      session_id: Keyword.get(opts, :session_id),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Validates that a context has all required fields.
  """
  def valid?(%__MODULE__{} = context) do
    not is_nil(context.agent_config) and
      is_binary(context.working_dir) and
      not is_nil(context.budget_guard)
  end

  def valid?(_), do: false
end
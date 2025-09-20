defmodule Otto.Tool do
  @moduledoc """
  Behaviour defining the interface for Otto tools.

  All tools must implement this behaviour to be registered and used within the Otto system.
  Tools are sandboxed and executed with proper permission checking.
  """

  @typedoc "Tool arguments as a map with string keys"
  @type args :: %{String.t() => any()}

  @typedoc "Tool execution result"
  @type result :: {:ok, any()} | {:error, String.t()}

  @typedoc "Sandbox configuration for tool isolation"
  @type sandbox_config :: %{
    required(:timeout) => non_neg_integer(),
    required(:memory_limit) => non_neg_integer(),
    required(:filesystem_access) => :none | :read_only | :read_write,
    optional(:network_access) => boolean(),
    optional(:environment_variables) => [String.t()]
  }

  @doc """
  Executes the tool with the given arguments.

  This is the main entry point for tool execution. The tool should validate
  arguments and return a result or error.

  ## Parameters
  - `args`: Map of arguments with string keys
  - `context`: Execution context containing agent_id, session_id, etc.

  ## Returns
  - `{:ok, result}` on successful execution
  - `{:error, reason}` on failure
  """
  @callback execute(args(), map()) :: result()

  @doc """
  Validates tool arguments before execution.

  This callback allows tools to validate their arguments early and provide
  meaningful error messages before attempting execution.

  ## Parameters
  - `args`: Map of arguments with string keys

  ## Returns
  - `:ok` if arguments are valid
  - `{:error, reason}` if validation fails
  """
  @callback validate_args(args()) :: :ok | {:error, String.t()}

  @doc """
  Returns the sandbox configuration for this tool.

  This defines the security boundaries and resource limits for tool execution.
  More restrictive settings provide better security but may limit functionality.

  ## Returns
  - Map containing sandbox configuration options
  """
  @callback sandbox_config() :: sandbox_config()

  @doc """
  Returns the tool's metadata including name, description, and schema.

  This information is used for tool discovery, documentation, and UI generation.
  """
  @callback metadata() :: %{
    required(:name) => String.t(),
    required(:description) => String.t(),
    required(:parameters) => map(),
    optional(:examples) => [map()],
    optional(:version) => String.t()
  }

  @optional_callbacks [metadata: 0]

  defmacro __using__(_opts) do
    quote do
      @behaviour Otto.Tool

      def metadata do
        %{
          name: to_string(__MODULE__),
          description: "Tool implementation",
          parameters: %{}
        }
      end

      defoverridable metadata: 0
    end
  end
end